@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.effects

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import kotlin.math.abs

internal fun shouldProcessVolumeBalance(panning: Float): Boolean = abs(panning) >= 0.001f

internal fun shouldProcessFrontBack(frontBack: Float): Boolean = abs(frontBack) >= 0.001f

internal class VolumeBalanceAudioProcessor : BaseAudioProcessor() {
    data class Controls(
        val panning: Float = 0f,
        val channelSwapEnabled: Boolean = false,
        val frontBack: Float = 0f,
        val spatialResponses: StereoSpatialResponses? = null
    ) {
        val isActive: Boolean
            get() = shouldProcessVolumeBalance(panning) ||
                channelSwapEnabled ||
                (shouldProcessFrontBack(frontBack) && spatialResponses != null)
    }

    @Volatile
    var controls = Controls()
    private var spatialRenderer: StereoSpatialRenderer? = null
    private var shortScratch = ShortArray(0)
    private var floatScratch = FloatArray(0)

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
        shortScratch = ShortArray(0)
        floatScratch = FloatArray(0)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val state = controls
        val outputBuffer = replaceOutputBuffer(inputBuffer.remaining())
        outputBuffer.order(inputBuffer.order())

        val targetFrontBack = if (shouldProcessFrontBack(state.frontBack)) state.frontBack else 0f
        val spatialActive = state.spatialResponses != null &&
            (targetFrontBack != 0f || spatialRenderer?.isNeutral == false)
        if (!spatialActive && !shouldProcessVolumeBalance(state.panning) && !state.channelSwapEnabled) {
            outputBuffer.put(inputBuffer)
            outputBuffer.flip()
            return
        }

        val pan = state.panning.coerceIn(-1f, 1f)
        val leftMultiplier = 1f - maxOf(pan, 0f)
        val rightMultiplier = 1f + minOf(pan, 0f)
        val isPcm16 = inputAudioFormat.encoding == C.ENCODING_PCM_16BIT
        val sampleRate = inputAudioFormat.sampleRate
        val renderer = state.spatialResponses?.takeIf { spatialActive }?.let { responses ->
            spatialRenderer?.takeIf { it.responses === responses && it.sampleRate == sampleRate }
                ?: StereoSpatialRenderer(responses, sampleRate).also { spatialRenderer = it }
        }

        val frameCount = inputBuffer.remaining() / inputAudioFormat.bytesPerFrame
        val swap = state.channelSwapEnabled
        if (isPcm16) {
            processPcm16(
                inputBuffer = inputBuffer,
                outputBuffer = outputBuffer,
                frameCount = frameCount,
                swap = swap,
                leftMultiplier = leftMultiplier,
                rightMultiplier = rightMultiplier,
                renderer = renderer,
                targetFrontBack = targetFrontBack
            )
        } else {
            processPcmFloat(
                inputBuffer = inputBuffer,
                outputBuffer = outputBuffer,
                frameCount = frameCount,
                swap = swap,
                leftMultiplier = leftMultiplier,
                rightMultiplier = rightMultiplier,
                renderer = renderer,
                targetFrontBack = targetFrontBack
            )
        }

        inputBuffer.position(inputBuffer.limit())
        // Finish the wet-to-dry ramp before bypassing convolution and history.
        if (targetFrontBack == 0f && renderer?.isNeutral == true) renderer.clear()
        outputBuffer.flip()
    }

    private fun processPcm16(
        inputBuffer: ByteBuffer,
        outputBuffer: ByteBuffer,
        frameCount: Int,
        swap: Boolean,
        leftMultiplier: Float,
        rightMultiplier: Float,
        renderer: StereoSpatialRenderer?,
        targetFrontBack: Float
    ) {
        val sampleCount = frameCount * 2
        if (sampleCount <= 0) return
        if (shortScratch.size < sampleCount) {
            shortScratch = ShortArray(sampleCount)
        }
        val samples = shortScratch
        inputBuffer.asShortBuffer().get(samples, 0, sampleCount)
        var i = 0
        if (renderer != null) {
            if (swap) {
                while (i < sampleCount) {
                    val rightIn = samples[i].toFloat()
                    val leftIn = samples[i + 1].toFloat()
                    renderer.process(leftIn, rightIn, targetFrontBack, 32768f)
                    samples[i] = toPcm16(renderer.left * leftMultiplier)
                    samples[i + 1] = toPcm16(renderer.right * rightMultiplier)
                    i += 2
                }
            } else {
                while (i < sampleCount) {
                    val leftIn = samples[i].toFloat()
                    val rightIn = samples[i + 1].toFloat()
                    renderer.process(leftIn, rightIn, targetFrontBack, 32768f)
                    samples[i] = toPcm16(renderer.left * leftMultiplier)
                    samples[i + 1] = toPcm16(renderer.right * rightMultiplier)
                    i += 2
                }
            }
        } else if (swap) {
            while (i < sampleCount) {
                val rightIn = samples[i].toFloat()
                val leftIn = samples[i + 1].toFloat()
                samples[i] = toPcm16(leftIn * leftMultiplier)
                samples[i + 1] = toPcm16(rightIn * rightMultiplier)
                i += 2
            }
        } else {
            while (i < sampleCount) {
                samples[i] = toPcm16(samples[i].toFloat() * leftMultiplier)
                samples[i + 1] = toPcm16(samples[i + 1].toFloat() * rightMultiplier)
                i += 2
            }
        }
        outputBuffer.asShortBuffer().put(samples, 0, sampleCount)
        outputBuffer.position(sampleCount * 2)
    }

    private fun processPcmFloat(
        inputBuffer: ByteBuffer,
        outputBuffer: ByteBuffer,
        frameCount: Int,
        swap: Boolean,
        leftMultiplier: Float,
        rightMultiplier: Float,
        renderer: StereoSpatialRenderer?,
        targetFrontBack: Float
    ) {
        val sampleCount = frameCount * 2
        if (sampleCount <= 0) return
        if (floatScratch.size < sampleCount) {
            floatScratch = FloatArray(sampleCount)
        }
        val samples = floatScratch
        inputBuffer.asFloatBuffer().get(samples, 0, sampleCount)
        var i = 0
        if (renderer != null) {
            if (swap) {
                while (i < sampleCount) {
                    val rightIn = samples[i]
                    val leftIn = samples[i + 1]
                    renderer.process(leftIn, rightIn, targetFrontBack, 1f)
                    samples[i] = renderer.left * leftMultiplier
                    samples[i + 1] = renderer.right * rightMultiplier
                    i += 2
                }
            } else {
                while (i < sampleCount) {
                    val leftIn = samples[i]
                    val rightIn = samples[i + 1]
                    renderer.process(leftIn, rightIn, targetFrontBack, 1f)
                    samples[i] = renderer.left * leftMultiplier
                    samples[i + 1] = renderer.right * rightMultiplier
                    i += 2
                }
            }
        } else if (swap) {
            while (i < sampleCount) {
                val rightIn = samples[i]
                val leftIn = samples[i + 1]
                samples[i] = leftIn * leftMultiplier
                samples[i + 1] = rightIn * rightMultiplier
                i += 2
            }
        } else {
            while (i < sampleCount) {
                samples[i] = samples[i] * leftMultiplier
                samples[i + 1] = samples[i + 1] * rightMultiplier
                i += 2
            }
        }
        outputBuffer.asFloatBuffer().put(samples, 0, sampleCount)
        outputBuffer.position(sampleCount * 4)
    }

    private fun toPcm16(value: Float): Short {
        return value
            .toInt()
            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            .toShort()
    }
}
