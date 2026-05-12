package com.narrator

import android.util.Log

/**
 * JNI bridge for on-device VLM inference via llama.cpp + mtmd.
 *
 * All methods are static — call them directly from NarratorPlugin.
 */
object VlmBridge {

    private const val TAG = "NarratorVLM"
    private var loaded = false

    init {
        try {
            System.loadLibrary("narrator_vlm")
            Log.i(TAG, "narrator_vlm JNI library loaded")
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "Failed to load narrator_vlm: ${e.message}")
        }
    }

    // Used to send tokens back to Flutter
    var tokenCallback: ((String) -> Unit)? = null

    /**
     * Called by C++ for each generated token.
     */
    @JvmStatic
    fun onNativeToken(token: String) {
        tokenCallback?.invoke(token)
    }

    /**
     * Load the language model and mmproj.
     * This is blocking and may take 10-30 seconds — call from a background thread.
     * @return true on success
     */
    fun load(modelPath: String, mmprojPath: String): Boolean {
        Log.i(TAG, "VlmBridge.load: model=$modelPath mmproj=$mmprojPath")
        loaded = nativeLoad(modelPath, mmprojPath)
        Log.i(TAG, "VlmBridge.load result: $loaded")
        return loaded
    }

    /**
     * Run multimodal inference.
     * @param imageJpegBytes  JPEG-compressed camera frame
     * @param query           User's question in English
     * @return generated text response
     */
    fun infer(imageJpegBytes: ByteArray, query: String): String {
        if (!loaded) return "Error: model not loaded"
        return nativeInfer(imageJpegBytes, query)
    }

    /** Release all native resources. */
    fun release() {
        nativeRelease()
        loaded = false
    }

    /** Cancel ongoing inference */
    fun cancel() {
        nativeCancel()
    }

    // ── native declarations ───────────────────────────────────────────────
    @JvmStatic private external fun nativeLoad(modelPath: String, mmprojPath: String): Boolean
    @JvmStatic private external fun nativeInfer(imageJpegBytes: ByteArray, query: String): String
    @JvmStatic private external fun nativeRelease()
    @JvmStatic private external fun nativeCancel()
}
