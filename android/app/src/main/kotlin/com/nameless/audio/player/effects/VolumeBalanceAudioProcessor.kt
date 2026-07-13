package com.nameless.audio.player.effects

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import kotlin.math.abs

internal fun shouldProcessVolumeBalance(panning: Float): Boolean = abs(panning) >= 0.001f

internal class VolumeBalanceAudioProcessor : BaseAudioProcessor() {
    @Volatile
    var panning: Float = 0f

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (!isPanningActive()) return AudioProcessor.AudioFormat.NOT_SET
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT &&
            inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT
        ) {
            return AudioProcessor.AudioFormat.NOT_SET
        }
        if (inputAudioFormat.channelCount != 2) {
            return AudioProcessor.AudioFormat.NOT_SET
        }
        return inputAudioFormat
    }

    override fun isActive(): Boolean {
        return isPanningActive() && inputAudioFormat != AudioProcessor.AudioFormat.NOT_SET
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val position = inputBuffer.position()
        val limit = inputBuffer.limit()
        val remaining = limit - position
        val p = panning.coerceIn(-1f, 1f)
        val outputBuffer = replaceOutputBuffer(remaining)
        outputBuffer.order(inputBuffer.order())

        if (abs(p) < 0.001f) {
            outputBuffer.put(inputBuffer)
            inputBuffer.position(limit)
            outputBuffer.flip()
            return
        }

        val leftMultiplier = if (p > 0f) 1f - p else 1f
        val rightMultiplier = if (p < 0f) 1f + p else 1f

        if (inputAudioFormat.encoding == C.ENCODING_PCM_16BIT) {
            var i = position
            while (i + 3 < limit) {
                val left = inputBuffer.getShort(i)
                val right = inputBuffer.getShort(i + 2)
                outputBuffer.putShort(scalePcm16(left, leftMultiplier))
                outputBuffer.putShort(scalePcm16(right, rightMultiplier))
                i += 4
            }
        } else if (inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT) {
            var i = position
            while (i + 7 < limit) {
                outputBuffer.putFloat(inputBuffer.getFloat(i) * leftMultiplier)
                outputBuffer.putFloat(inputBuffer.getFloat(i + 4) * rightMultiplier)
                i += 8
            }
        }

        inputBuffer.position(limit)
        outputBuffer.flip()
    }

    private fun isPanningActive(): Boolean = shouldProcessVolumeBalance(panning)

    private fun scalePcm16(value: Short, multiplier: Float): Short {
        return (value * multiplier)
            .toInt()
            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            .toShort()
    }
}
