package com.narrator

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.StorageService
import java.io.File

class WakeWordManager(
    private val context: Context,
    private val onDetected: (String) -> Unit
) {
    private var model: Model? = null
    private var recognizer: Recognizer? = null
    private var audioThread: Thread? = null
    @Volatile private var isRunning = false

    companion object {
        private const val TAG = "WakeWordManager"
        private const val SAMPLE_RATE = 16000
        private const val GRAMMAR = """["suno","sono", "soono", "su no", "narrator", "[unk]"]"""
    }

    
    fun start() {
    Log.i(TAG, "start() called — loading Vosk model")
    Thread({
        try {
            // Unpack model from assets to internal storage manually
            val destDir = File(context.filesDir, "vosk-model")
            if (!destDir.exists()) {
                Log.i(TAG, "Unpacking model to ${destDir.absolutePath}")
                unpackAssets(context, "wake_words/vosk-model-small-en-us-0.15", destDir)
            } else {
                Log.i(TAG, "Model already unpacked at ${destDir.absolutePath}")
            }
            model = Model(destDir.absolutePath)
            recognizer = Recognizer(model, SAMPLE_RATE.toFloat(), GRAMMAR)
            Log.i(TAG, "Vosk model loaded — starting capture")
            isRunning = true
            audioThread = Thread({ captureLoop() }, "vosk-capture")
            audioThread?.start()
        } catch (e: Exception) {
            Log.e(TAG, "Vosk init failed: ${e.message}")
        }
    }, "vosk-init").start()
}
private fun unpackAssets(context: Context, assetPath: String, destDir: File) {
    val assets = context.assets.list(assetPath) ?: emptyArray()
    if (assets.isEmpty()) {
        // It's a file — copy it
        destDir.parentFile?.mkdirs()
        context.assets.open(assetPath).use { input ->
            destDir.outputStream().use { output -> input.copyTo(output) }
        }
    } else {
        // It's a folder — recurse
        destDir.mkdirs()
        for (asset in assets) {
            unpackAssets(context, "$assetPath/$asset", File(destDir, asset))
        }
    }
}

    private fun captureLoop() {
        Log.i(TAG, "captureLoop() started")
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufferSize = maxOf(minBuf, 8192)

        val recorder = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize
        )

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialize — check RECORD_AUDIO permission")
            return
        }

        recorder.startRecording()
        Log.i(TAG, "AudioRecord started — listening for wake word")

        val buffer = ShortArray(bufferSize / 2)
        var frameCount = 0

        while (isRunning) {
            val read = recorder.read(buffer, 0, buffer.size)
            if (read <= 0) continue

            frameCount++
            if (frameCount % 50 == 0) {
                Log.d(TAG, "Vosk processing frame $frameCount (read=$read samples)")
            }

            // Convert ShortArray → ByteArray (little-endian PCM16)
            val bytes = ByteArray(read * 2)
            for (i in 0 until read) {
                bytes[i * 2]     = (buffer[i].toInt() and 0xFF).toByte()
                bytes[i * 2 + 1] = (buffer[i].toInt() shr 8).toByte()
            }

            val rec = recognizer ?: break
            if (rec.acceptWaveForm(bytes, bytes.size)) {
                val json = rec.result
                val text = JSONObject(json).optString("text", "").trim()
                if (text.isNotEmpty()) {
                    Log.i(TAG, "Vosk final result: '$text'")
                    if (text.contains("suno", ignoreCase = true) ||
                        text.contains("narrator", ignoreCase = true)) {
                        Log.i(TAG, "✅ Wake word detected: $text")
                        onDetected("suno")
                    }
                }
            } else {
                // Partial result — log occasionally to confirm audio is flowing
                if (frameCount % 100 == 0) {
                    val partial = JSONObject(rec.partialResult).optString("partial", "")
                    if (partial.isNotEmpty()) {
                        Log.d(TAG, "Vosk partial: '$partial'")
                    }
                }
            }
        }

        recorder.stop()
        recorder.release()
        Log.i(TAG, "captureLoop() ended")
    }

    fun stop() {
        Log.i(TAG, "stop() called")
        isRunning = false
        audioThread?.join(2000)
        audioThread = null
        recognizer?.close()
        recognizer = null
        model?.close()
        model = null
    }
}