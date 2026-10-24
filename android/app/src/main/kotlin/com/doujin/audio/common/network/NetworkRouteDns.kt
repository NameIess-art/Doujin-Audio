package com.doujin.audio.common.network

import okhttp3.Dns
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.Proxy
import java.net.UnknownHostException
import java.security.SecureRandom

/** Plain DNS is scoped to this app. Numeric server addresses avoid DNS bootstrap recursion. */
internal class NetworkRouteDns(private val server: String, private val port: Int = 53) : Dns {
    override fun lookup(hostname: String): List<InetAddress> {
        if (hostname.contains(':') || hostname.matches(Regex("[0-9.]+"))) {
            return listOf(InetAddress.getByName(hostname))
        }
        val addresses = mutableListOf<InetAddress>()
        var failure: IOException? = null
        for (type in listOf(1, 28)) {
            try { addresses += lookup(hostname, type, 0) } catch (error: IOException) { failure = error }
        }
        if (addresses.isEmpty()) throw UnknownHostException("DNS resolution failed for $hostname").also {
            if (failure != null) it.initCause(failure)
        }
        return addresses.distinct()
    }

    private fun lookup(hostname: String, type: Int, depth: Int): List<InetAddress> {
        if (depth > 8) throw IOException("DNS CNAME chain too long")
        val id = SecureRandom().nextInt(65536)
        val query = ByteArrayOutputStream().also { bytes ->
            DataOutputStream(bytes).apply {
                writeShort(id); writeShort(0x0100); writeShort(1)
                repeat(3) { writeShort(0) }
                java.net.IDN.toASCII(hostname).trimEnd('.').split('.').forEach { label ->
                    val encoded = label.toByteArray(Charsets.US_ASCII)
                    if (encoded.size !in 1..63) throw IOException("Invalid DNS label")
                    writeByte(encoded.size); write(encoded)
                }
                writeByte(0); writeShort(type); writeShort(1)
            }
        }.toByteArray()
        val endpoint = InetSocketAddress(InetAddress.getByName(server), port)
        var response = DatagramSocket().use { socket ->
            socket.soTimeout = 4_000
            socket.connect(endpoint)
            socket.send(DatagramPacket(query, query.size))
            val packet = DatagramPacket(ByteArray(65535), 65535)
            socket.receive(packet)
            packet.data.copyOf(packet.length)
        }
        if (response.size < 12 || unsignedShort(response, 0) != id) throw IOException("Invalid DNS response")
        if (unsignedShort(response, 2) and 0x0200 != 0) {
            response = Socket(Proxy.NO_PROXY).use { socket ->
                socket.connect(endpoint, 4_000); socket.soTimeout = 4_000
                DataOutputStream(socket.getOutputStream()).apply { writeShort(query.size); write(query); flush() }
                val input = DataInputStream(socket.getInputStream())
                ByteArray(input.readUnsignedShort()).also(input::readFully)
            }
        }
        if (response.size < 12 || unsignedShort(response, 0) != id ||
            unsignedShort(response, 2) and 0x800F != 0x8000) throw IOException("DNS query rejected")
        var cursor = 12
        repeat(unsignedShort(response, 4)) {
            cursor = readName(response, cursor).second + 4
        }
        val records = mutableListOf<Triple<String, Int, ByteArray>>()
        val aliases = mutableMapOf<String, String>()
        repeat(unsignedShort(response, 6)) {
            val (owner, afterName) = readName(response, cursor)
            val recordType = unsignedShort(response, afterName)
            val recordClass = unsignedShort(response, afterName + 2)
            val length = unsignedShort(response, afterName + 8)
            val start = afterName + 10
            if (start + length > response.size) throw IOException("Truncated DNS record")
            if (recordClass == 1) {
                if (recordType == 5) aliases[owner.lowercase()] = readName(response, start).first.lowercase()
                if ((recordType == 1 && length == 4) || (recordType == 28 && length == 16)) {
                    records += Triple(owner.lowercase(), recordType, response.copyOfRange(start, start + length))
                }
            }
            cursor = start + length
        }
        var canonical = hostname.trimEnd('.').lowercase()
        val owners = mutableSetOf(canonical)
        repeat(8) {
            val alias = aliases[canonical] ?: return@repeat
            if (!owners.add(alias)) throw IOException("DNS CNAME cycle")
            canonical = alias
        }
        val addresses = records.filter { it.first in owners && it.second == type }
            .map { InetAddress.getByAddress(hostname, it.third) }
        return if (addresses.isEmpty() && canonical != hostname.trimEnd('.').lowercase()) {
            lookup(canonical, type, depth + 1)
        } else addresses
    }

    private fun unsignedShort(bytes: ByteArray, index: Int): Int {
        if (index < 0 || index + 2 > bytes.size) throw IOException("Truncated DNS response")
        return ((bytes[index].toInt() and 255) shl 8) or (bytes[index + 1].toInt() and 255)
    }

    private fun readName(bytes: ByteArray, start: Int): Pair<String, Int> {
        var cursor = start
        var end = -1
        val labels = mutableListOf<String>()
        val visited = mutableSetOf<Int>()
        while (true) {
            if (cursor !in bytes.indices || !visited.add(cursor)) throw IOException("Invalid DNS name")
            val size = bytes[cursor].toInt() and 255
            if (size and 0xC0 == 0xC0) {
                val pointer = unsignedShort(bytes, cursor) and 0x3FFF
                if (end < 0) end = cursor + 2
                cursor = pointer
            } else {
                cursor++
                if (size == 0) return labels.joinToString(".") to (if (end < 0) cursor else end)
                if (size > 63 || cursor + size > bytes.size) throw IOException("Invalid DNS label")
                labels += String(bytes, cursor, size, Charsets.US_ASCII)
                cursor += size
            }
        }
    }
}
