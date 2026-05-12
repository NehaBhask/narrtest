package com.narrator

import android.app.ActivityManager
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.File

class NarratorPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var ncnnChannel: MethodChannel
    private lateinit var vlmChannel: MethodChannel
    private lateinit var context: Context
    private val scope = CoroutineScope(Dispatchers.IO)
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var inferJob: Job? = null

    // ── NCNN native declarations ──────────────────────────────────────────────
    private external fun nativeLoadModel(paramPath: String, binPath: String): Boolean
    private external fun nativeDetectObjects(yuvData: ByteArray, width: Int, height: Int): FloatArray
    private external fun nativeReleaseModel()

    companion object {
        var nativeLibraryLoaded = false
            private set
        init {
            try {
                System.loadLibrary("narrator_ncnn")
                nativeLibraryLoaded = true
                android.util.Log.i("NarratorPlugin", "narrator_ncnn.so loaded successfully")
            } catch (e: UnsatisfiedLinkError) {
                android.util.Log.e("NarratorPlugin",
                    "narrator_ncnn.so FAILED to load — YOLO will be disabled: ${e.message}")
            }
        }
    }

    // ── JPEG → NV21 conversion (no native dep required) ──────────────────────
    private fun bitmapToNv21(bitmap: android.graphics.Bitmap): ByteArray {
        val w = bitmap.width; val h = bitmap.height
        val argb = IntArray(w * h)
        bitmap.getPixels(argb, 0, w, 0, 0, w, h)
        val nv21 = ByteArray(w * h * 3 / 2)
        var yIdx = 0; var uvIdx = w * h
        for (j in 0 until h) {
            for (i in 0 until w) {
                val px = argb[j * w + i]
                val r = (px shr 16) and 0xff
                val g = (px shr 8)  and 0xff
                val b =  px        and 0xff
                nv21[yIdx++] = ((66*r + 129*g + 25*b + 128).shr(8) + 16)
                    .coerceIn(0, 255).toByte()
                if (j % 2 == 0 && i % 2 == 0) {
                    // NV21 = interleaved VU (Cr first, then Cb)
                    nv21[uvIdx++] = ((112*r - 94*g - 18*b + 128).shr(8) + 128)
                        .coerceIn(0, 255).toByte()  // Cr (V)
                    nv21[uvIdx++] = ((-38*r - 74*g + 112*b + 128).shr(8) + 128)
                        .coerceIn(0, 255).toByte()  // Cb (U)
                }
            }
        }
        return nv21
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        ncnnChannel = MethodChannel(binding.binaryMessenger, "com.narrator/ncnn_plugin")
        ncnnChannel.setMethodCallHandler(this)

        vlmChannel = MethodChannel(binding.binaryMessenger, "com.narrator/vlm_plugin")
        vlmChannel.setMethodCallHandler(this)

        VlmBridge.tokenCallback = { token ->
            mainHandler.post { vlmChannel.invokeMethod("onToken", token) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ncnnChannel.setMethodCallHandler(null)
        vlmChannel.setMethodCallHandler(null)
        VlmBridge.tokenCallback = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {

            // ── Native lib status query (used by Dart to surface load errors) ─
            "isNativeLibLoaded" -> {
                result.success(nativeLibraryLoaded)
            }

            // ── NCNN / YOLOv8 ────────────────────────────────────────────────
            "loadYoloModel" -> {
                if (!nativeLibraryLoaded) {
                    android.util.Log.e("NarratorPlugin", "loadYoloModel called but native lib not loaded")
                    result.success(false)
                    return
                }
                val paramPath = call.argument<String>("paramPath") ?: run {
                    result.error("INVALID_ARGS", "paramPath missing", null); return }
                val binPath = call.argument<String>("binPath") ?: run {
                    result.error("INVALID_ARGS", "binPath missing", null); return }
                scope.launch {
                    val ok = try { nativeLoadModel(paramPath, binPath) }
                             catch (t: Throwable) {
                                 android.util.Log.e("NarratorPlugin", "nativeLoadModel threw: ${t.message}")
                                 false
                             }
                    mainHandler.post { result.success(ok) }
                }
            }

            // Accept JPEG bytes, decode to Bitmap, convert to NV21, run inference
            "detectFromJpeg" -> {
                if (!nativeLibraryLoaded) { result.success(listOf<Float>()); return }
                val jpegData = call.argument<ByteArray>("jpegData") ?: run {
                    result.success(listOf<Float>()); return }
                scope.launch {
                    val dets = try {
                        val bmp = android.graphics.BitmapFactory
                            .decodeByteArray(jpegData, 0, jpegData.size)
                        if (bmp == null) {
                            android.util.Log.e("NarratorPlugin", "detectFromJpeg: BitmapFactory returned null")
                            emptyList<Float>()
                        } else {
                            val nv21 = bitmapToNv21(bmp)
                            nativeDetectObjects(nv21, bmp.width, bmp.height).toList()
                        }
                    } catch (t: Throwable) {
                        android.util.Log.e("NarratorPlugin", "detectFromJpeg: ${t.message}")
                        emptyList<Float>()
                    }
                    mainHandler.post { result.success(dets) }
                }
            }

            // Legacy NV21 path (kept for compatibility)
            "detectObjects" -> {
                if (!nativeLibraryLoaded) { result.success(listOf<Float>()); return }
                val yuv = call.argument<ByteArray>("yuvData") ?: run {
                    result.success(listOf<Float>()); return }
                val w = call.argument<Int>("width") ?: 0
                val h = call.argument<Int>("height") ?: 0
                scope.launch {
                    val dets = try { nativeDetectObjects(yuv, w, h).toList() }
                               catch (t: Throwable) {
                                   android.util.Log.e("NarratorPlugin", "detectObjects: ${t.message}")
                                   emptyList<Float>()
                               }
                    mainHandler.post { result.success(dets) }
                }
            }

            "releaseYoloModel" -> {
                if (!nativeLibraryLoaded) { result.success(null); return }
                scope.launch {
                    try { nativeReleaseModel() } catch (_: Throwable) {}
                    mainHandler.post { result.success(null) }
                }
            }

            // ── VLM ──────────────────────────────────────────────────────────
            "getAvailableRamMb" -> {
                val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val mi = ActivityManager.MemoryInfo()
                am.getMemoryInfo(mi)
                result.success((mi.totalMem / 1024 / 1024).toInt())
            }

            "getNativeLibraryDir" -> {
                result.success(context.applicationInfo.nativeLibraryDir)
            }

            "loadVlmModel" -> {
                val modelPath  = call.argument<String>("modelPath")  ?: run {
                    result.success(false); return }
                val mmprojPath = call.argument<String>("mmprojPath") ?: run {
                    result.success(false); return }
                scope.launch {
                    val ok = try { VlmBridge.load(modelPath, mmprojPath) }
                             catch (t: Throwable) {
                                 android.util.Log.e("NarratorPlugin", "VlmBridge.load: ${t.message}")
                                 false
                             }
                    mainHandler.post { result.success(ok) }
                }
            }

            "generateResponse" -> {
                val imageBytes = call.argument<ByteArray>("imageBytes") ?: run {
                    result.error("INVALID_ARGS", "imageBytes missing", null); return }
                val query = call.argument<String>("query") ?: "What do you see?"
                inferJob?.cancel()
                inferJob = scope.launch {
                    val response = try {
                        val text = VlmBridge.infer(imageBytes, query)
                        mainHandler.post { vlmChannel.invokeMethod("onGenerationDone", null) }
                        text
                    } catch (t: Throwable) {
                        android.util.Log.e("NarratorPlugin", "VlmBridge.infer: ${t.message}")
                        mainHandler.post { vlmChannel.invokeMethod("onGenerationDone", null) }
                        "Sorry, I could not process the image."
                    }
                    mainHandler.post { result.success(response) }
                }
            }

            "cancelVlmModel" -> {
                inferJob?.cancel()
                try { VlmBridge.cancel() } catch (_: Throwable) {}
                result.success(null)
            }

            "releaseVlmModel" -> {
                inferJob?.cancel()
                try { VlmBridge.release() } catch (_: Throwable) {}
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }
}
