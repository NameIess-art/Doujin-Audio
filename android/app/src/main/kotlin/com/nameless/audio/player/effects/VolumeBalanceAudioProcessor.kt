@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

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
    @Volatile
    var channelSwapEnabled: Boolean = false

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (!shouldProcessStereo()) return AudioProcessor.AudioFormat.NOT_SET
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

    override fun queueInput(inputBuffer: ByteBuffer) {
        val position = inputBuffer.position()
        val limit = inputBuffer.limit()
        val remaining = limit - position
        val p = panning.coerceIn(-1f, 1f)
        val outputBuffer = replaceOutputBuffer(remaining)
        outputBuffer.order(inputBuffer.order())

        if (abs(p) < 0.001f && !channelSwapEnabled) {
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
                val outputLeft = if (channelSwapEnabled) right else left
                val outputRight = if (channelSwapEnabled) left else right
                outputBuffer.putShort(scalePcm16(outputLeft, leftMultiplier))
                outputBuffer.putShort(scalePcm16(outputRight, rightMultiplier))
                i += 4
            }
        } else if (inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT) {
            var i = position
            while (i + 7 < limit) {
                val left = inputBuffer.getFloat(i)
                val right = inputBuffer.getFloat(i + 4)
                val outputLeft = if (channelSwapEnabled) right else left
                val outputRight = if (channelSwapEnabled) left else right
                outputBuffer.putFloat(outputLeft * leftMultiplier)
                outputBuffer.putFloat(outputRight * rightMultiplier)
                i += 8
            }
        }

        inputBuffer.position(limit)
        outputBuffer.flip()
    }

    private fun isPanningActive(): Boolean = shouldProcessVolumeBalance(panning)

    private fun shouldProcessStereo(): Boolean = isPanningActive() || channelSwapEnabled

    private fun scalePcm16(value: Short, multiplier: Float): Short {
        return (value * multiplier)
            .toInt()
            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            .toShort()
    }
}
