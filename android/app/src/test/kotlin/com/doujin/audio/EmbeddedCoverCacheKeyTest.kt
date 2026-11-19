package com.doujin.audio

import com.doujin.audio.metadata.embeddedCoverCacheFileName
import com.doujin.audio.metadata.parseId3TagPicture

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EmbeddedCoverCacheKeyTest {
    @Test
    fun `same cover bytes share one cache file name`() {
        val cover = byteArrayOf(0x01, 0x23, 0x45, 0x67)

        assertEquals(
            embeddedCoverCacheFileName(cover),
            embeddedCoverCacheFileName(cover.copyOf())
        )
    }

    @Test
    fun `different cover bytes keep separate cache file names`() {
        assertNotEquals(
            embeddedCoverCacheFileName(byteArrayOf(0x01, 0x23)),
            embeddedCoverCacheFileName(byteArrayOf(0x01, 0x24))
        )
    }

    @Test
    fun `id3v2 3 extended header advances past header size field to parse APIC`() {
        val image = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47)
        val apicPayload = byteArrayOf(0x00) + // encoding: ISO-8859-1
            "image/png".toByteArray(Charsets.US_ASCII) + byteArrayOf(0x00) +
            byteArrayOf(0x03) + // picture type: cover front
            byteArrayOf(0x00) + // empty description
            image
        val tagData = byteArrayOf(0x00, 0x00, 0x00, 0x06) + // extSize = 6 (excluding 4-byte size field)
            ByteArray(6) +
            "APIC".toByteArray(Charsets.US_ASCII) +
            byteArrayOf(0x00, 0x00, 0x00, apicPayload.size.toByte()) +
            byteArrayOf(0x00, 0x00) +
            apicPayload

        assertArrayEquals(image, parseId3TagPicture(tagData, majorVersion = 3, extHeader = true))
    }

    @Test
    fun `negative or overflowing frame sizes terminate instead of looping`() {
        val negativeSizeFrame = "TIT2".toByteArray(Charsets.US_ASCII) +
            byteArrayOf(0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xF6.toByte()) + // -10
            byteArrayOf(0x00, 0x00)
        assertNull(parseId3TagPicture(negativeSizeFrame, majorVersion = 3, extHeader = false))

        val truncatedApic = "APIC".toByteArray(Charsets.US_ASCII) +
            byteArrayOf(0x00, 0x00, 0x00, 0x03) +
            byteArrayOf(0x00, 0x00) +
            byteArrayOf(0x00, 0x61, 0x62) // no null terminator after MIME
        assertNull(parseId3TagPicture(truncatedApic, majorVersion = 3, extHeader = false))
    }
}
