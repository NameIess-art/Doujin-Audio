package com.doujin.audio.common.network

import java.io.DataInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.Proxy
import javax.net.SocketFactory

/** Android's SOCKS implementation does not consistently invoke java.net.Authenticator. */
internal class Socks5SocketFactory(
    private val proxyHost: String,
    private val proxyPort: Int,
    private val username: String? = null,
    private val password: String? = null,
) : SocketFactory() {
    override fun createSocket(): Socket = object : Socket(Proxy.NO_PROXY) {
        override fun connect(endpoint: SocketAddress, timeout: Int) {
            val destination = endpoint as? InetSocketAddress ?: throw IOException("Invalid SOCKS destination")
            try {
                super.connect(InetSocketAddress(proxyHost, proxyPort), timeout)
                val previousTimeout = soTimeout
                soTimeout = timeout.takeIf { it > 0 } ?: 15_000
                val input = DataInputStream(getInputStream())
                val output = getOutputStream()
                val authenticated = username != null
                output.write(if (authenticated) byteArrayOf(5, 1, 2) else byteArrayOf(5, 1, 0))
                if (input.readUnsignedByte() != 5) throw IOException("Invalid SOCKS version")
                val method = input.readUnsignedByte()
                if (method != (if (authenticated) 2 else 0)) throw IOException("SOCKS authentication rejected")
                if (authenticated) {
                    val user = username!!.toByteArray(Charsets.UTF_8)
                    val secret = password.orEmpty().toByteArray(Charsets.UTF_8)
                    if (user.size !in 1..255 || secret.size !in 1..255) throw IOException("Invalid SOCKS credentials length")
                    output.write(byteArrayOf(1, user.size.toByte()) + user + byteArrayOf(secret.size.toByte()) + secret)
                    if (input.readUnsignedByte() != 1 || input.readUnsignedByte() != 0) throw IOException("SOCKS credentials rejected")
                }
                val target = destination.hostString
                val address = if (target.contains(':') || target.matches(Regex("[0-9.]+"))) {
                    InetAddress.getByName(target).address.let {
                        byteArrayOf(if (it.size == 4) 1 else 4) + it
                    }
                } else {
                    val name = java.net.IDN.toASCII(target).toByteArray(Charsets.US_ASCII)
                    if (name.size !in 1..255) throw IOException("Invalid SOCKS hostname")
                    byteArrayOf(3, name.size.toByte()) + name
                }
                // Retain destination hostnames so the proxy owns destination DNS.
                output.write(byteArrayOf(5, 1, 0) + address +
                    byteArrayOf((destination.port shr 8).toByte(), destination.port.toByte()))
                if (input.readUnsignedByte() != 5 || input.readUnsignedByte() != 0 || input.readUnsignedByte() != 0) {
                    throw IOException("SOCKS connection rejected")
                }
                val boundLength = when (input.readUnsignedByte()) {
                    1 -> 4
                    3 -> input.readUnsignedByte()
                    4 -> 16
                    else -> throw IOException("Invalid SOCKS address type")
                }
                input.readFully(ByteArray(boundLength + 2))
                soTimeout = previousTimeout
            } catch (error: Exception) {
                close()
                throw error
            }
        }
        override fun connect(endpoint: SocketAddress) = connect(endpoint, 0)
    }

    override fun createSocket(host: String, port: Int): Socket = createSocket().also {
        it.connect(InetSocketAddress.createUnresolved(host, port))
    }
    override fun createSocket(host: InetAddress, port: Int): Socket = createSocket(host.hostName, port)
    override fun createSocket(host: String, port: Int, localHost: InetAddress, localPort: Int): Socket =
        createSocket().also {
            it.bind(InetSocketAddress(localHost, localPort))
            it.connect(InetSocketAddress.createUnresolved(host, port))
        }
    override fun createSocket(host: InetAddress, port: Int, localHost: InetAddress, localPort: Int): Socket =
        createSocket(host.hostName, port, localHost, localPort)
}
