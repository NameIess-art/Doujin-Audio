package com.doujin.audio

import com.doujin.audio.common.network.Socks5SocketFactory
import com.doujin.audio.common.network.NetworkRouteDns
import com.doujin.audio.common.network.NetworkRoute
import com.doujin.audio.common.network.createClient
import org.junit.Assert.*
import org.junit.Test
import java.net.ServerSocket
import java.net.DatagramSocket
import java.net.DatagramPacket
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.InetAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI
import java.net.SocketAddress
import java.net.InetSocketAddress
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class NetworkRouteTest {
    @Test
    fun systemProxyFallbackAndRedirectPolicyKeepTargetDnsSeparate() {
        ServerSocket(0).use { server ->
            val deadPort = ServerSocket(0).use { it.localPort }
            val selected = mutableListOf<String>()
            val failed = mutableListOf<SocketAddress>()
            val resolved = mutableListOf<String>()
            val selector = object : ProxySelector() {
                override fun select(uri: URI): List<Proxy> {
                    selected += uri.host
                    return if (uri.host == "first.invalid") listOf(
                        Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("localhost", deadPort)),
                        Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("localhost", server.localPort)),
                    ) else listOf(Proxy.NO_PROXY)
                }
                override fun connectFailed(uri: URI, address: SocketAddress, error: IOException) {
                    failed += address
                }
            }
            val executor = Executors.newSingleThreadExecutor()
            val client = NetworkRoute(authentication = true, username = "saved-user",
                password = "saved-secret", dns = "192.0.2.1").createClient(selector, object : Dns {
                override fun lookup(hostname: String): List<InetAddress> {
                    resolved += hostname
                    return listOf(InetAddress.getByAddress(hostname, byteArrayOf(127, 0, 0, 1)))
                }
            })
            try {
                val exchange = executor.submit {
                    repeat(2) { index ->
                        server.soTimeout = 5_000
                        server.accept().use { peer ->
                            val input = peer.getInputStream().bufferedReader()
                            val line = input.readLine()
                            assertEquals(if (index == 0) "GET http://first.invalid/start HTTP/1.1"
                                else "GET /finish HTTP/1.1", line)
                            val headers = generateSequence { input.readLine()?.takeIf { it.isNotEmpty() } }.toList()
                            assertFalse(headers.any { it.startsWith("Proxy-Authorization:", true) })
                            val response = if (index == 0) "HTTP/1.1 302 Found\r\nLocation: http://direct.invalid:${server.localPort}/finish\r\nContent-Length: 0"
                                else "HTTP/1.1 200 OK\r\nContent-Length: 2"
                            peer.getOutputStream().write("$response\r\nConnection: close\r\n\r\n${if (index == 0) "" else "ok"}".toByteArray())
                        }
                    }
                }
                client.newCall(Request.Builder().url("http://first.invalid/start").build()).execute().use {
                    assertEquals("ok", it.body!!.string())
                }
                exchange.get(5, TimeUnit.SECONDS)
                assertEquals(listOf("first.invalid", "direct.invalid"), selected)
                assertEquals(listOf("direct.invalid"), resolved)
                val failedAddress = InetSocketAddress.createUnresolved("localhost", deadPort)
                client.proxySelector.connectFailed(URI("http://first.invalid/"), failedAddress, IOException("unreachable"))
                assertEquals(failedAddress, failed.last())
            } finally {
                client.connectionPool.evictAll()
                client.dispatcher.executorService.shutdownNow()
                executor.shutdownNow()
            }
        }
    }

    @Test
    fun manualHttpProxyUsesUtf8Credentials() {
        val client = NetworkRoute("http", "localhost", 8080, true, "用户", "密码").createClient()
        val challenge = okhttp3.Response.Builder()
            .request(Request.Builder().url("https://media.example/").build())
            .protocol(okhttp3.Protocol.HTTP_1_1).code(407).message("Proxy Authentication Required").build()
        val authenticated = client.proxyAuthenticator.authenticate(null, challenge)!!
        val encoded = java.util.Base64.getEncoder().encodeToString("用户:密码".toByteArray(Charsets.UTF_8))
        assertEquals("Basic $encoded", authenticated.header("Proxy-Authorization"))
    }

    @Test
    fun restoredAuthenticatedProxyWithoutPasswordRejectsRequests() {
        for (mode in listOf("http", "socks5")) {
            try {
                NetworkRoute(mode, "proxy.example", 1080, true, "alice", null).requireCredentialsForRequest()
                fail("Authenticated proxy must stay blocked when its password was not restored")
            } catch (expected: java.io.IOException) {
                assertTrue(expected.message!!.contains("credentials"))
            }
        }
        NetworkRoute("http", "proxy.example", 1080, true, "alice", "secret").requireCredentialsForRequest()
        NetworkRoute().requireCredentialsForRequest()
    }

    @Test
    fun customDnsFollowsCnameAnswersWithoutUsingSystemDns() {
        DatagramSocket(0).use { server ->
            val executor = Executors.newSingleThreadExecutor()
            try {
                val exchange = executor.submit {
                    repeat(2) {
                        val packet = DatagramPacket(ByteArray(512), 512)
                        server.soTimeout = 3_000
                        server.receive(packet)
                        val query = packet.data.copyOf(packet.length)
                        val ipv6 = query[query.size - 3].toInt() == 28
                        val canonical = byteArrayOf(4) + "edge".toByteArray() + byteArrayOf(7) + "example".toByteArray() + byteArrayOf(0)
                        val response = ByteArrayOutputStream().also { bytes ->
                            DataOutputStream(bytes).apply {
                                write(query.copyOf().also { it[2] = 0x81.toByte(); it[3] = 0x80.toByte(); it[7] = 2 })
                                writeShort(0xC00C); writeShort(5); writeShort(1); writeInt(60)
                                writeShort(canonical.size); write(canonical)
                                write(canonical); writeShort(if (ipv6) 28 else 1); writeShort(1); writeInt(60)
                                val address = if (ipv6) ByteArray(16).also { it[15] = 7 } else byteArrayOf(192.toByte(), 0, 2, 7)
                                writeShort(address.size); write(address)
                            }
                        }.toByteArray()
                        server.send(DatagramPacket(response, response.size, packet.socketAddress))
                    }
                }
                val addresses = NetworkRouteDns("127.0.0.1", server.localPort).lookup("media.example")
                assertEquals(2, addresses.size)
                assertEquals("192.0.2.7", addresses.first().hostAddress)
                exchange.get(3, TimeUnit.SECONDS)
            } finally {
                executor.shutdownNow()
            }
        }
    }

    @Test
    fun customDnsResolvesAAndAAAAWithCompressedNames() {
        DatagramSocket(0).use { server ->
            val executor = Executors.newSingleThreadExecutor()
            try {
                val exchange = executor.submit {
                    repeat(2) {
                        val packet = DatagramPacket(ByteArray(512), 512)
                        server.soTimeout = 3_000
                        server.receive(packet)
                        val query = packet.data.copyOf(packet.length)
                        val ipv6 = query[query.size - 3].toInt() == 28
                        val address = if (ipv6) ByteArray(16).also { it[15] = 1 } else byteArrayOf(127, 0, 0, 2)
                        val response = dnsAnswer(query, address, ipv6)
                        server.send(DatagramPacket(response, response.size, packet.socketAddress))
                    }
                }
                val addresses = NetworkRouteDns("127.0.0.1", server.localPort).lookup("media.example")
                assertEquals(listOf(4, 16), addresses.map { it.address.size })
                assertEquals("127.0.0.2", addresses.first().hostAddress)
                exchange.get(3, TimeUnit.SECONDS)
            } finally {
                executor.shutdownNow()
            }
        }
    }

    @Test
    fun customDnsRetriesTruncatedUdpAnswerOverTcp() {
        ServerSocket(0).use { tcp ->
            DatagramSocket(tcp.localPort).use { udp ->
                val executor = Executors.newFixedThreadPool(2)
                try {
                    val udpExchange = executor.submit {
                        repeat(2) {
                            val packet = DatagramPacket(ByteArray(512), 512)
                            udp.soTimeout = 3_000
                            udp.receive(packet)
                            val query = packet.data.copyOf(packet.length)
                            query[2] = 0x83.toByte()
                            query[3] = 0x80.toByte()
                            udp.send(DatagramPacket(query, query.size, packet.socketAddress))
                        }
                    }
                    val tcpExchange = executor.submit {
                        repeat(2) {
                            tcp.soTimeout = 3_000
                            tcp.accept().use { socket ->
                                val input = java.io.DataInputStream(socket.getInputStream())
                                val query = ByteArray(input.readUnsignedShort()).also(input::readFully)
                                val ipv6 = query[query.size - 3].toInt() == 28
                                val response = dnsAnswer(query, if (ipv6) ByteArray(16) else byteArrayOf(10, 0, 0, 1), ipv6)
                                DataOutputStream(socket.getOutputStream()).apply { writeShort(response.size); write(response); flush() }
                            }
                        }
                    }
                    assertEquals(2, NetworkRouteDns("127.0.0.1", udp.localPort).lookup("media.example").size)
                    udpExchange.get(3, TimeUnit.SECONDS)
                    tcpExchange.get(3, TimeUnit.SECONDS)
                } finally {
                    executor.shutdownNow()
                }
            }
        }
    }

    private fun dnsAnswer(query: ByteArray, address: ByteArray, ipv6: Boolean): ByteArray =
        ByteArrayOutputStream().also { bytes ->
            DataOutputStream(bytes).apply {
                write(query.copyOf().also { it[2] = 0x81.toByte(); it[3] = 0x80.toByte(); it[7] = 1 })
                writeShort(0xC00C); writeShort(if (ipv6) 28 else 1); writeShort(1)
                writeInt(60); writeShort(address.size); write(address)
            }
        }.toByteArray()

    @Test
    fun socksAuthenticationSendsCredentialsAndUnresolvedDestination() {
        ServerSocket(0).use { server ->
            val executor = Executors.newSingleThreadExecutor()
            try {
                val exchange = executor.submit<String> {
                    server.accept().use { peer ->
                        val input = peer.getInputStream()
                        val output = peer.getOutputStream()
                        assertEquals(5, input.read())
                        val methods = ByteArray(input.read()).also { java.io.DataInputStream(input).readFully(it) }
                        assertTrue(methods.contains(2))
                        output.write(byteArrayOf(5, 2))
                        assertEquals(1, input.read())
                        val username = ByteArray(input.read()).also { java.io.DataInputStream(input).readFully(it) }
                        val password = ByteArray(input.read()).also { java.io.DataInputStream(input).readFully(it) }
                        assertEquals("alice", String(username))
                        assertEquals("secret", String(password))
                        output.write(byteArrayOf(1, 0))
                        assertEquals(5, input.read())
                        assertEquals(1, input.read())
                        assertEquals(0, input.read())
                        assertEquals(3, input.read())
                        val destination = ByteArray(input.read()).also { java.io.DataInputStream(input).readFully(it) }
                        assertEquals(443, java.io.DataInputStream(input).readUnsignedShort())
                        output.write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 80))
                        val http = input.bufferedReader()
                        assertEquals("GET /sample HTTP/1.1", http.readLine())
                        while (!http.readLine().isNullOrEmpty()) { }
                        output.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
                        String(destination)
                    }
                }
                val client = OkHttpClient.Builder().proxy(Proxy.NO_PROXY)
                    .socketFactory(Socks5SocketFactory("127.0.0.1", server.localPort, "alice", "secret"))
                    .dns(object : Dns {
                        override fun lookup(hostname: String): List<InetAddress> =
                            listOf(InetAddress.getByAddress(hostname, byteArrayOf(0, 0, 0, 0)))
                    }).build()
                client.newCall(Request.Builder().url("http://media.example:443/sample").build()).execute().use {
                    assertEquals("ok", it.body!!.string())
                }
                assertEquals("media.example", exchange.get(3, TimeUnit.SECONDS))
            } finally {
                executor.shutdownNow()
            }
        }
    }
}
