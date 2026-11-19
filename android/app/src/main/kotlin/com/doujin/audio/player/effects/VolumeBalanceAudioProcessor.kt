@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.effects

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import kotlin.math.abs

internal fun shouldProcessVolumeBalance(panning: Float): Boolean = abs(panning) >= 0.001f

internal class VolumeBalanceAudioProcessor : BaseAudioProcessor() {
    data class Controls(
        val panning: Float = 0f,
        val channelSwapEnabled: Boolean = false,
        val frontBack: Float = 0f,
        val spatialResponses: StereoSpatialResponses? = null
    ) {
        val isActive: Boolean
            get() = shouldProcessVolumeBalance(panning) || channelSwapEnabled || spatialResponses != null
    }

    @Volatile
    var controls = Controls()
    private var spatialRenderer: StereoSpatialRenderer? = null

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (!controls.isActive) return AudioProcessor.AudioFormat.NOT_SET
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

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
        spatialRenderer?.clear()
    }

    override fun onReset() {
        spatialRenderer = null
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val state = controls
        val outputBuffer = replaceOutputBuffer(inputBuffer.remaining())
        outputBuffer.order(inputBuffer.order())

        if (!state.isActive) {
            outputBuffer.put(inputBuffer)
            outputBuffer.flip()
            return
        }

        val pan = state.panning.coerceIn(-1f, 1f)
        val leftMultiplier = 1f - maxOf(pan, 0f)
        val rightMultiplier = 1f + minOf(pan, 0f)
        val isPcm16 = inputAudioFormat.encoding == C.ENCODING_PCM_16BIT
        val fullScale = if (isPcm16) 32768f else 1f
        val sampleRate = inputAudioFormat.sampleRate
        val renderer = state.spatialResponses?.let { responses ->
            spatialRenderer?.takeIf { it.responses === responses && it.sampleRate == sampleRate }
                ?: StereoSpatialRenderer(responses, sampleRate).also { spatialRenderer = it }
        }

        val bytesPerFrame = inputAudioFormat.bytesPerFrame
        while (inputBuffer.remaining() >= bytesPerFrame) {
            val first = if (isPcm16) inputBuffer.short.toFloat() else inputBuffer.float
            val second = if (isPcm16) inputBuffer.short.toFloat() else inputBuffer.float
            var left = if (state.channelSwapEnabled) second else first
            var right = if (state.channelSwapEnabled) first else second
            if (renderer != null) {
                renderer.process(left, right, state.frontBack, fullScale)
                left = renderer.left
                right = renderer.right
            }
            if (isPcm16) {
                outputBuffer.putShort(toPcm16(left * leftMultiplier))
                outputBuffer.putShort(toPcm16(right * rightMultiplier))
            } else {
                outputBuffer.putFloat(left * leftMultiplier)
                outputBuffer.putFloat(right * rightMultiplier)
            }
        }

        inputBuffer.position(inputBuffer.limit())
        outputBuffer.flip()
    }

    private fun toPcm16(value: Float): Short {
        return value
            .toInt()
            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            .toShort()
    }
}
