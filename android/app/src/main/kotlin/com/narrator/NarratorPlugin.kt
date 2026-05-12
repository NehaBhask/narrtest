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
    
    // Lock to prevent releasing the YOLO model while inference is ongoing (prevents OpenMP crashes)
    private val yoloLock = Any()

    // ── NCNN native declarations ──────────────────────────────────────────────
    private external fun nativeLoadModel(paramPath: String, binPath: String): Boolean
    private external fun nativeDetectObjects(yuvData: ByteArray, width: Int, height: Int): FloatArray
    private external fun nativeDetectFromRgb(rgbData: ByteArray, width: Int, height: Int): FloatArray
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

    // ── Direct Bitmap → RGB extraction (no YUV loss) ─────────────────────────
    private fun bitmapToRgb(bitmap: android.graphics.Bitmap): ByteArray {
        val w = bitmap.width
        val h = bitmap.height
        val argb = IntArray(w * h)
        bitmap.getPixels(argb, 0, w, 0, 0, w, h)
        
        val rgb = ByteArray(w * h * 3)
        var idx = 0
        for (px in argb) {
            rgb[idx++] = ((px shr 16) and 0xff).toByte() // R
            rgb[idx++] = ((px shr 8)  and 0xff).toByte() // G
            rgb[idx++] = ( px         and 0xff).toByte() // B
        }
        return rgb
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
                    val ok = try {
                        synchronized(yoloLock) {
                            nativeLoadModel(paramPath, binPath)
                        }
                    } catch (t: Throwable) {
                        android.util.Log.e("NarratorPlugin", "nativeLoadModel threw: ${t.message}")
                        false
                    }
                    mainHandler.post { result.success(ok) }
                }
            }

            // Accept JPEG bytes, decode to Bitmap, extract RGB, run inference
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
                            val rgb = bitmapToRgb(bmp)
                            synchronized(yoloLock) {
                                if (Companion.nativeLibraryLoaded) {
                                    nativeDetectFromRgb(rgb, bmp.width, bmp.height).toList()
                                } else {
                                    emptyList<Float>()
                                }
                            }
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
                    val dets = try {
                        synchronized(yoloLock) {
                            if (Companion.nativeLibraryLoaded) {
                                nativeDetectObjects(yuv, w, h).toList()
                            } else {
                                emptyList<Float>()
                            }
                        }
                    } catch (t: Throwable) {
                        android.util.Log.e("NarratorPlugin", "detectObjects: ${t.message}")
                        emptyList<Float>()
                    }
                    mainHandler.post { result.success(dets) }
                }
            }

            "releaseYoloModel" -> {
                if (!nativeLibraryLoaded) { result.success(null); return }
                scope.launch {
                    try {
                        synchronized(yoloLock) {
                            nativeReleaseModel()
                        }
                    } catch (_: Throwable) {}
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
