package com.doujin.audio.channel

import android.content.Context
import com.doujin.audio.common.network.NetworkRoute
import com.doujin.audio.common.network.NetworkRouteRuntime
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress

internal class NetworkMethodHandler(private val context: Context) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = ChannelEnvelopeResult(result)
        try {
            val args = call.argumentReader()
            when (call.method) {
                "resolveSystemProxy" -> reply.success(NetworkRouteRuntime.systemProxy(args.requiredString("url")))
                "applyNetworkRoute" -> {
                    val mode = args.requiredString("proxyMode")
                    val host = args.requiredString("proxyHost", allowBlank = true)
                    val port = args.requiredInt("proxyPort")
                    val authentication = args.requiredBoolean("proxyAuthenticationEnabled")
                    val username = args.requiredString("proxyUsername", allowBlank = true)
                    val configured = args.requiredBoolean("proxyPasswordConfigured")
                    val password = args.requiredNullableString("proxyPassword")
                    val dns = args.requiredString("customDnsServer", allowBlank = true)
                    require(mode in listOf("system", "http", "socks5")) { "Invalid proxy mode" }
                    if (mode != "system") {
                        require(host.isNotBlank() && !host.any { it.isWhitespace() || it in "/?#@" } && port in 1..65535) {
                            "Invalid proxy host or port"
                        }
                        if (mode == "socks5" && authentication) require(
                            username.toByteArray(Charsets.UTF_8).size <= 255 &&
                                (password?.toByteArray(Charsets.UTF_8)?.size ?: 0) <= 255,
                        ) { "SOCKS credentials must fit 255 UTF-8 bytes" }
                    }
                    if (dns.isNotEmpty()) {
                        require(!dns.contains('%') && (dns.contains(':') || dns.matches(Regex("[0-9.]+")))) { "DNS must be an IP address" }
                        try {
                            InetAddress.getByName(dns)
                        } catch (error: java.net.UnknownHostException) {
                            throw IllegalArgumentException("DNS must be an IP address", error)
                        }
                    }
                    NetworkRouteRuntime.get(context).apply(NetworkRoute(mode, host, port, authentication, username,
                        password.takeIf { configured }, dns))
                    reply.success(null)
                }
                else -> reply.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            reply.error(ChannelErrorCodes.INVALID_ARGUMENT, error.message, null)
        } catch (error: Exception) {
            reply.error(ChannelErrorCodes.PLATFORM_ERROR, "Network configuration failed", null)
        }
    }
}
