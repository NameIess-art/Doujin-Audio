package com.nameless.audio

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import kotlin.math.roundToInt

class VolumeBoostAudioProcessor : BaseAudioProcessor() {
    private var gain = 1f

    fun setGain(volume: Float) {
        gain = PlaybackVolumeMapper.boostGain(volume)
    }

    override fun onConfigure(
        inputAudioFormat: AudioProcessor.AudioFormat
    ): AudioProcessor.AudioFormat {
        return when (inputAudioFormat.encoding) {
            C.ENCODING_PCM_16BIT,
            C.ENCODING_PCM_FLOAT -> inputAudioFormat
            // Keep playback alive for formats we do not explicitly boost.
            else -> AudioProcessor.AudioFormat.NOT_SET
        }
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val outputBuffer = replaceOutputBuffer(inputBuffer.remaining())
        outputBuffer.order(inputBuffer.order())

        if (gain <= 1.0001f) {
            outputBuffer.put(inputBuffer)
            outputBuffer.flip()
            return
        }

        when (inputAudioFormat.encoding) {
            C.ENCODING_PCM_16BIT -> processPcm16(inputBuffer, outputBuffer)
            C.ENCODING_PCM_FLOAT -> processPcmFloat(inputBuffer, outputBuffer)
            else -> throw IllegalStateException(
                "Unsupported PCM encoding for volume boost: ${inputAudioFormat.encoding}"
            )
        }
        outputBuffer.flip()
    }

    private fun processPcm16(inputBuffer: ByteBuffer, outputBuffer: ByteBuffer) {
        while (inputBuffer.remaining() >= 2) {
            val sample = inputBuffer.short.toInt()
            val boosted = (sample * gain)
                .roundToInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            outputBuffer.putShort(boosted.toShort())
        }
        if (inputBuffer.hasRemaining()) {
            outputBuffer.put(inputBuffer.get())
        }
    }

    private fun processPcmFloat(inputBuffer: ByteBuffer, outputBuffer: ByteBuffer) {
        while (inputBuffer.remaining() >= 4) {
            val sample = inputBuffer.float
            outputBuffer.putFloat((sample * gain).coerceIn(-1f, 1f))
        }
        while (inputBuffer.hasRemaining()) {
            outputBuffer.put(inputBuffer.get())
        }
    }
}
