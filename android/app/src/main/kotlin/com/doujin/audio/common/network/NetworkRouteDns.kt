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
import java.net.Proxy
import java.net.Socket
import java.net.UnknownHostException
import java.security.SecureRandom
import java.util.Locale
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Plain DNS is scoped to this app. Numeric server addresses avoid DNS bootstrap recursion. */
internal class NetworkRouteDns(
    private val server: String,
    private val port: Int = 53,
    private val clockMs: () -> Long = { System.nanoTime() / 1_000_000L },
    private val aaaaGraceTimeoutMs: Long = AAAA_GRACE_TIMEOUT_MS
) : Dns {
    private data class CachedEntry(
        val addresses: List<InetAddress>,
        val expiresAtMs: Long
    )

    private data class DnsLookupResult(
        val addresses: List<InetAddress>,
        val minTtlSeconds: Long?
    )

    private val endpoint by lazy { InetSocketAddress(InetAddress.getByName(server), port) }
    private val cache = object : LinkedHashMap<String, CachedEntry>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedEntry>?): Boolean =
            size > MAX_CACHE_ENTRIES
    }

    fun clearCache() {
        synchronized(cache) {
            cache.clear()
        }
    }

    override fun lookup(hostname: String): List<InetAddress> {
        if (hostname.contains(':') || ipv4LiteralRegex.matches(hostname)) {
            return listOf(InetAddress.getByName(hostname))
        }
        val cacheKey = hostname.trimEnd('.').lowercase(Locale.ROOT)
        val nowMs = clockMs()
        synchronized(cache) {
            val cached = cache[cacheKey]
            if (cached != null) {
                if (nowMs < cached.expiresAtMs) return cached.addresses
                cache.remove(cacheKey)
            }
        }

        val aaaaFuture = queryExecutor.submit<Result<DnsLookupResult>> {
            runCatching { lookup(hostname, 28, 0) }
        }
        val aResult = runCatching { lookup(hostname, 1, 0) }

        val addresses = mutableListOf<InetAddress>()
        var minTtlSeconds: Long? = null
        var failure: Throwable? = null

        aResult.fold(
            onSuccess = {
                addresses += it.addresses
                minTtlSeconds = minNullable(minTtlSeconds, it.minTtlSeconds)
            },
            onFailure = { failure = it }
        )

        val aaaaResult = try {
            val waitMs = if (addresses.isNotEmpty()) aaaaGraceTimeoutMs else FULL_QUERY_TIMEOUT_MS
            aaaaFuture.get(waitMs, TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            aaaaFuture.cancel(true)
            null
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            aaaaFuture.cancel(true)
            null
        } catch (error: ExecutionException) {
            Result.failure(error.cause ?: error)
        }

        aaaaResult?.fold(
            onSuccess = {
                addresses += it.addresses
                minTtlSeconds = minNullable(minTtlSeconds, it.minTtlSeconds)
            },
            onFailure = { if (failure == null) failure = it }
        )

        if (addresses.isEmpty()) {
            throw UnknownHostException("DNS resolution failed for $hostname").also {
                if (failure != null) it.initCause(failure)
            }
        }
        val distinct = addresses.distinct()
        val ttlSeconds = (minTtlSeconds ?: MIN_TTL_SECONDS).coerceIn(MIN_TTL_SECONDS, MAX_TTL_SECONDS)
        val expiresAtMs = clockMs() + ttlSeconds * 1_000L
        synchronized(cache) {
            cache[cacheKey] = CachedEntry(distinct, expiresAtMs)
        }
        return distinct
    }

    private fun lookup(hostname: String, type: Int, depth: Int): DnsLookupResult {
        if (depth > 8) throw IOException("DNS CNAME chain too long")
        val id = random.nextInt(65536)
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
        var response = DatagramSocket().use { socket ->
            socket.soTimeout = SOCKET_TIMEOUT_MS
            socket.connect(endpoint)
            socket.send(DatagramPacket(query, query.size))
            val packet = DatagramPacket(ByteArray(UDP_BUFFER_SIZE), UDP_BUFFER_SIZE)
            socket.receive(packet)
            packet.data.copyOf(packet.length)
        }
        if (response.size < 12 || unsignedShort(response, 0) != id) throw IOException("Invalid DNS response")
        if (unsignedShort(response, 2) and 0x0200 != 0) {
            response = Socket(Proxy.NO_PROXY).use { socket ->
                socket.connect(endpoint, SOCKET_TIMEOUT_MS); socket.soTimeout = SOCKET_TIMEOUT_MS
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
        val records = mutableListOf<DnsAddressRecord>()
        val aliases = mutableMapOf<String, Pair<String, Long>>()
        repeat(unsignedShort(response, 6)) {
            val (owner, afterName) = readName(response, cursor)
            val recordType = unsignedShort(response, afterName)
            val recordClass = unsignedShort(response, afterName + 2)
            val ttl = unsignedInt(response, afterName + 4)
            val length = unsignedShort(response, afterName + 8)
            val start = afterName + 10
            if (start + length > response.size) throw IOException("Truncated DNS record")
            if (recordClass == 1) {
                val loweredOwner = owner.lowercase(Locale.ROOT)
                if (recordType == 5) {
                    aliases[loweredOwner] = readName(response, start).first.lowercase(Locale.ROOT) to ttl
                }
                if ((recordType == 1 && length == 4) || (recordType == 28 && length == 16)) {
                    records += DnsAddressRecord(
                        owner = loweredOwner,
                        type = recordType,
                        ttlSeconds = ttl,
                        bytes = response.copyOfRange(start, start + length)
                    )
                }
            }
            cursor = start + length
        }
        var canonical = hostname.trimEnd('.').lowercase(Locale.ROOT)
        val owners = mutableSetOf(canonical)
        var minTtl: Long? = null
        repeat(8) {
            val alias = aliases[canonical] ?: return@repeat
            if (!owners.add(alias.first)) throw IOException("DNS CNAME cycle")
            minTtl = minNullable(minTtl, alias.second)
            canonical = alias.first
        }
        val matched = records.filter { it.owner in owners && it.type == type }
        val addresses = matched.map { record ->
            minTtl = minNullable(minTtl, record.ttlSeconds)
            InetAddress.getByAddress(hostname, record.bytes)
        }
        return if (addresses.isEmpty() && canonical != hostname.trimEnd('.').lowercase(Locale.ROOT)) {
            val followed = lookup(canonical, type, depth + 1)
            DnsLookupResult(
                addresses = followed.addresses,
                minTtlSeconds = minNullable(minTtl, followed.minTtlSeconds)
            )
        } else {
            DnsLookupResult(addresses = addresses, minTtlSeconds = minTtl)
        }
    }

    private data class DnsAddressRecord(
        val owner: String,
        val type: Int,
        val ttlSeconds: Long,
        val bytes: ByteArray
    )

    private fun unsignedShort(bytes: ByteArray, index: Int): Int {
        if (index < 0 || index + 2 > bytes.size) throw IOException("Truncated DNS response")
        return ((bytes[index].toInt() and 255) shl 8) or (bytes[index + 1].toInt() and 255)
    }

    private fun unsignedInt(bytes: ByteArray, index: Int): Long {
        if (index < 0 || index + 4 > bytes.size) throw IOException("Truncated DNS response")
        return ((bytes[index].toLong() and 0xFFL) shl 24) or
            ((bytes[index + 1].toLong() and 0xFFL) shl 16) or
            ((bytes[index + 2].toLong() and 0xFFL) shl 8) or
            (bytes[index + 3].toLong() and 0xFFL)
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

    private fun minNullable(first: Long?, second: Long?): Long? = when {
        first == null -> second
        second == null -> first
        else -> minOf(first, second)
    }

    private companion object {
        const val UDP_BUFFER_SIZE = 4096
        const val SOCKET_TIMEOUT_MS = 4_000
        const val FULL_QUERY_TIMEOUT_MS = 4_500L
        const val AAAA_GRACE_TIMEOUT_MS = 400L
        const val MAX_CACHE_ENTRIES = 128
        const val MIN_TTL_SECONDS = 30L
        const val MAX_TTL_SECONDS = 300L

        val ipv4LiteralRegex = Regex("[0-9.]+")
        val random = SecureRandom()
        val queryExecutor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "NetworkRouteDns").apply { isDaemon = true }
        }
    }
}
