package com.doujin.audio.player.effects

import android.content.res.AssetManager
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.WeakHashMap
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.math.sin

private const val RESAMPLE_LOBES = 12

internal class StereoSpatialResponses(
    val sampleRate: Int,
    val front: Array<FloatArray>,
    val back: Array<FloatArray>
) {
    init {
        require(listOf(front, back).all { channels ->
            channels[0].contentEquals(channels[3]) && channels[1].contentEquals(channels[2])
        }) { "Spatial responses must mirror the left and right sources" }
    }

    companion object {
        fun load(assets: AssetManager): StereoSpatialResponses {
            val (frontRate, front) = readResponses(assets, "front")
            val (backRate, back) = readResponses(assets, "back")
            require(frontRate == backRate) { "Spatial response sample rates must match" }
            return StereoSpatialResponses(frontRate, front, back)
        }

        private fun readResponses(assets: AssetManager, direction: String): Pair<Int, Array<FloatArray>> {
            val path = "flutter_assets/assets/audio/spatial_$direction.wav"
            val bytes = assets.open(path).use { it.readBytes() }
            val wav = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            fun tag(offset: Int) = String(bytes, offset, 4, Charsets.US_ASCII)

            require(bytes.size >= 12 && tag(0) == "RIFF" && tag(8) == "WAVE") { "Invalid WAV: $path" }
            var sampleRate = 0
            var offset = 12
            while (offset <= bytes.size - 8) {
                val size = wav.getInt(offset + 4)
                val start = offset + 8
                require(size in 0..(bytes.size - start)) { "Truncated WAV: $path" }
                when (tag(offset)) {
                    "fmt " -> {
                        require(size >= 16 && wav.getShort(start).toInt() == 1 &&
                            wav.getShort(start + 2).toInt() == 4 && wav.getShort(start + 14).toInt() == 16
                        ) { "Expected four PCM16 response channels: $path" }
                        sampleRate = wav.getInt(start + 4)
                    }
                    "data" -> {
                        require(sampleRate > 0 && size > 0 && size % 8 == 0) { "Invalid WAV data: $path" }
                        return sampleRate to Array(4) { channel ->
                            FloatArray(size / 8) { frame -> wav.getShort(start + frame * 8 + channel * 2) / 32768f }
                        }
                    }
                }
                offset = start + size + (size and 1)
            }
            error("WAV has no spatial responses: $path")
        }
    }
}

internal class StereoSpatialRenderer(
    val responses: StereoSpatialResponses,
    val sampleRate: Int
) {
    private val prepared = getOrPrepare(responses, sampleRate)
    private val tapStride = prepared.tapStride
    private val front = prepared.front
    private val back = prepared.back
    private val frames = prepared.frames
    // Duplicate the ring so each convolution can read contiguous samples across the wrap.
    private val midHistory = FloatArray(frames * 2)
    private val sideHistory = FloatArray(frames * 2)
    private val spatialStep = 100f / sampleRate
    private var cursor = frames - 1
    private var amount = 0f
    val isNeutral: Boolean get() = amount == 0f
    var left = 0f
        private set
    var right = 0f
        private set

    fun clear() {
        midHistory.fill(0f)
        sideHistory.fill(0f)
        cursor = frames - 1
        amount = 0f
    }

    fun process(inputLeft: Float, inputRight: Float, target: Float, fullScale: Float) {
        val mid = (inputLeft + inputRight) * 0.5f
        val side = (inputLeft - inputRight) * 0.5f
        midHistory[cursor] = mid
        midHistory[cursor + frames] = mid
        sideHistory[cursor] = side
        sideHistory[cursor + frames] = side

        val delta = target - amount
        amount = if (abs(delta) <= spatialStep) target else amount + delta.coerceIn(-spatialStep, spatialStep)
        left = inputLeft
        right = inputRight
        if (amount != 0f) {
            val kernels = if (amount > 0f) front else back
            var wetMid = 0f
            var wetSide = 0f
            var frame = cursor
            for (tap in kernels.mid.indices) {
                wetMid += midHistory[frame] * kernels.mid[tap]
                wetSide += sideHistory[frame] * kernels.side[tap]
                frame += tapStride
            }
            val wet = abs(amount)
            left += wet * (wetMid + wetSide - left)
            right += wet * (wetMid - wetSide - right)

            // Preserve binaural level differences when a spatial response exceeds full scale.
            val peak = maxOf(abs(left), abs(right))
            if (peak > fullScale) {
                val gain = fullScale / peak
                left *= gain
                right *= gain
            }
        }
        cursor = if (cursor == 0) frames - 1 else cursor - 1
    }

    internal class Kernels(val mid: FloatArray, val side: FloatArray)

    internal class PreparedResponses(
        val tapStride: Int,
        val front: Kernels,
        val back: Kernels,
        val frames: Int
    )

    companion object {
        private const val MAX_CACHED_RATES_PER_RESPONSE = 8
        private val preparedCache = WeakHashMap<StereoSpatialResponses, LinkedHashMap<Int, PreparedResponses>>()

        internal fun getOrPrepare(
            responses: StereoSpatialResponses,
            sampleRate: Int
        ): PreparedResponses {
            synchronized(preparedCache) {
                preparedCache[responses]?.get(sampleRate)?.let { return it }
            }
            val computed = buildPrepared(responses, sampleRate)
            synchronized(preparedCache) {
                val byRate = preparedCache.getOrPut(responses) { LinkedHashMap() }
                byRate[sampleRate]?.let { return it }
                if (byRate.size >= MAX_CACHED_RATES_PER_RESPONSE) {
                    val oldestKey = byRate.keys.iterator().next()
                    byRate.remove(oldestKey)
                }
                byRate[sampleRate] = computed
            }
            return computed
        }

        private fun buildPrepared(
            responses: StereoSpatialResponses,
            sampleRate: Int
        ): PreparedResponses {
            // Space the taps farther apart for high-rate audio to preserve the response
            // in the audible band without increasing the convolution cost per sample.
            val tapStride = (sampleRate.toDouble() / responses.sampleRate).roundToInt().coerceAtLeast(1)
            val scale = sampleRate.toDouble() / (responses.sampleRate * tapStride)
            val front = prepare(responses.front, scale)
            val back = prepare(responses.back, scale)
            val frames = (maxOf(front.mid.size, back.mid.size) - 1) * tapStride + 1
            return PreparedResponses(tapStride, front, back, frames)
        }

        private fun prepare(channels: Array<FloatArray>, scale: Double): Kernels {
            val direct = resample(channels[0], scale)
            val cross = resample(channels[1], scale)
            // Symmetric HRTFs reduce the four source-to-ear filters to two filters.
            return Kernels(
                FloatArray(direct.size) { direct[it] + cross[it] },
                FloatArray(direct.size) { direct[it] - cross[it] }
            )
        }

        private fun resample(source: FloatArray, scale: Double): FloatArray {
            if (scale == 1.0) return source
            val bandwidth = minOf(scale, 1.0)
            val radius = RESAMPLE_LOBES / bandwidth
            return FloatArray(ceil(source.size * scale).toInt()) { tap ->
                val position = tap / scale
                val first = maxOf(0, ceil(position - radius).toInt())
                val last = minOf(source.lastIndex, floor(position + radius).toInt())
                var coefficient = 0.0
                // Filter the impulse before downsampling to keep inaudible frequencies
                // from folding into the audible part of the new response.
                for (index in first..last) {
                    val angle = PI * (position - index) * bandwidth
                    val sinc = if (angle == 0.0) 1.0 else sin(angle) / angle
                    val window = 0.5 + 0.5 * cos(angle / RESAMPLE_LOBES)
                    coefficient += source[index] * sinc * window
                }
                (coefficient * bandwidth / scale).toFloat()
            }
        }
    }
}
