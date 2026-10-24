package com.doujin.audio.common.network

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import okhttp3.Call
import okhttp3.Credentials
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class NetworkRoute(
    val mode: String = "system",
    val host: String = "",
    val port: Int = 0,
    val authentication: Boolean = false,
    val username: String = "",
    val password: String? = null,
    val dns: String = "",
) {
    fun requireCredentialsForRequest() {
        if (mode != "system" && authentication && (username.isBlank() || password.isNullOrEmpty())) {
            throw IOException("Proxy credentials are missing. Update the network service settings.")
        }
    }
}

/** Read-only native mirror: Dart settings are the only writer of committed routes. */
internal class NetworkRouteRuntime private constructor(context: Context) : Call.Factory {
    // Keystore keys do not migrate through Android backup, so neither may this encrypted mirror.
    private val mirror = AtomicFile(File(context.noBackupFilesDir, "native_network_route"))
    private var route: NetworkRoute? = null
    private var client: OkHttpClient? = null

    @Synchronized
    fun apply(value: NetworkRoute) {
        val json = JSONObject().apply {
            put("mode", value.mode); put("host", value.host); put("port", value.port)
            put("authentication", value.authentication); put("username", value.username)
            put("password", value.password); put("dns", value.dns)
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val encrypted = cipher.iv + cipher.doFinal(json.toString().toByteArray(Charsets.UTF_8))
        val stream = mirror.startWrite()
        try {
            stream.write(encrypted)
            mirror.finishWrite(stream)
        } catch (error: Exception) {
            mirror.failWrite(stream)
            throw error
        }
        route = value
        // Eviction closes only idle connections. Existing playback requests keep their client.
        client?.connectionPool?.evictAll()
        client = null
    }

    @Synchronized
    override fun newCall(request: Request): Call {
        val current = route ?: load().also { route = it }
        current.requireCredentialsForRequest()
        val active = client ?: current.createClient().also { client = it }
        return active.newCall(request)
    }

    private fun load(): NetworkRoute {
        if (!mirror.baseFile.exists()) return NetworkRoute()
        val encrypted = mirror.openRead().use { it.readBytes() }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, encrypted.copyOfRange(0, 12)))
        }
        val json = JSONObject(String(cipher.doFinal(encrypted.copyOfRange(12, encrypted.size)), Charsets.UTF_8))
        return NetworkRoute(json.getString("mode"), json.getString("host"), json.getInt("port"),
            json.getBoolean("authentication"), json.getString("username"),
            if (json.isNull("password")) null else json.getString("password"), json.getString("dns"))
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    companion object {
        private const val KEY_ALIAS = "doujin_audio_network_route"
        @Volatile private var instance: NetworkRouteRuntime? = null
        fun get(context: Context): NetworkRouteRuntime = instance ?: synchronized(this) {
            instance ?: NetworkRouteRuntime(context.applicationContext).also { instance = it }
        }

        fun systemProxy(url: String): String {
            val uri = URI(url)
            require(uri.scheme in listOf("http", "https") && !uri.host.isNullOrEmpty()) { "Invalid network URL" }
            return ProxySelector.getDefault()?.select(uri).orEmpty().joinToString("; ") { proxy ->
                if (proxy.type() == Proxy.Type.DIRECT) "DIRECT" else {
                    val address = proxy.address() as InetSocketAddress
                    val host = if (address.hostString.contains(':')) "[${address.hostString}]" else address.hostString
                    "${if (proxy.type() == Proxy.Type.HTTP) "PROXY" else "SOCKS"} $host:${address.port}"
                }
            }.ifEmpty { "DIRECT" }
        }
    }
}

internal fun NetworkRoute.createClient(
    systemProxySelector: ProxySelector? = ProxySelector.getDefault(),
    directDns: Dns = if (dns.isEmpty()) Dns.SYSTEM else NetworkRouteDns(dns),
): OkHttpClient {
    val builder = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS)
        .followRedirects(true).followSslRedirects(true)
    if (mode == "system") {
        if (systemProxySelector == null) return builder.proxy(Proxy.NO_PROXY).dns(directDns).build()
        if (dns.isEmpty()) return builder.proxySelector(systemProxySelector).dns(directDns).build()
        val proxyHosts = ConcurrentHashMap.newKeySet<String>()
        fun hostKey(host: String) = host.removeSurrounding("[", "]").lowercase()
        // Let OkHttp retain PAC fallback and re-evaluate policy after redirects.
        // Its Dns also resolves HTTP proxy endpoints, which must use OS DNS.
        builder.proxySelector(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> = systemProxySelector.select(uri).also { proxies ->
                proxies.filter { it.type() == Proxy.Type.HTTP }.forEach {
                    proxyHosts.add(hostKey((it.address() as InetSocketAddress).hostString))
                }
            }
            override fun connectFailed(uri: URI, address: SocketAddress, error: IOException) =
                systemProxySelector.connectFailed(uri, address, error)
        }).dns(object : Dns {
            override fun lookup(hostname: String): List<InetAddress> =
                (if (hostKey(hostname) in proxyHosts) Dns.SYSTEM else directDns).lookup(hostname)
        })
    } else if (mode == "http") {
        builder.proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(host, port))).dns(Dns.SYSTEM)
        if (authentication) builder.proxyAuthenticator { _, response ->
            if (response.request.header("Proxy-Authorization") != null) null
            else response.request.newBuilder().header(
                "Proxy-Authorization", Credentials.basic(username, password.orEmpty(), Charsets.UTF_8),
            ).build()
        }
    } else {
        builder.proxy(Proxy.NO_PROXY)
            .socketFactory(Socks5SocketFactory(host, port,
                username.takeIf { authentication }, password.takeIf { authentication }))
            // Route construction needs an address; the socket retains the hostname.
            .dns(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> =
                    listOf(InetAddress.getByAddress(hostname, byteArrayOf(0, 0, 0, 0)))
            })
    }
    return builder.build()
}
