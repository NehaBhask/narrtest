/**
 * narrator_vlm_jni.cpp — JNI bridge for on-device VLM (llama.cpp + mtmd)
 * Exposed Java class: com.narrator.VlmBridge
 */

#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include <atomic>
#include <cstring>

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#define LOG_TAG "NarratorVLM"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static llama_model*   g_model = nullptr;
static llama_context* g_ctx   = nullptr;
static mtmd_context*  g_mctx  = nullptr;
static std::atomic<bool> g_cancel{false};

static void ggml_log_cb(ggml_log_level level, const char* text, void*) {
    if (level == GGML_LOG_LEVEL_ERROR) LOGE("%s", text);
    // suppress INFO/WARN to reduce logcat noise
}

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_narrator_VlmBridge_nativeLoad(
        JNIEnv* env, jclass,
        jstring j_model_path, jstring j_mmproj_path) {

    llama_log_set(ggml_log_cb, nullptr);

    const char* model_path  = env->GetStringUTFChars(j_model_path,  nullptr);
    const char* mmproj_path = env->GetStringUTFChars(j_mmproj_path, nullptr);
    LOGI("nativeLoad: model=%s", model_path);

    llama_model_params mparams = llama_model_default_params();
    mparams.use_mmap    = false;
    mparams.n_gpu_layers = 0;

    g_model = llama_model_load_from_file(model_path, mparams);
    if (!g_model) {
        LOGE("Failed to load model");
        env->ReleaseStringUTFChars(j_model_path,  model_path);
        env->ReleaseStringUTFChars(j_mmproj_path, mmproj_path);
        return JNI_FALSE;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx     = 1024; // smaller ctx = faster first token
    cparams.n_threads = 4;
    cparams.n_batch   = 512;

    g_ctx = llama_init_from_model(g_model, cparams);
    if (!g_ctx) {
        LOGE("Failed to create context");
        llama_model_free(g_model); g_model = nullptr;
        env->ReleaseStringUTFChars(j_model_path,  model_path);
        env->ReleaseStringUTFChars(j_mmproj_path, mmproj_path);
        return JNI_FALSE;
    }

    mtmd_context_params mctx_params = mtmd_context_params_default();
    mctx_params.use_gpu      = false;
    mctx_params.n_threads    = 4;
    mctx_params.print_timings = false;
    mctx_params.warmup       = false;

    g_mctx = mtmd_init_from_file(mmproj_path, g_model, mctx_params);
    if (!g_mctx) {
        LOGE("Failed to load mmproj");
        llama_free(g_ctx);        g_ctx   = nullptr;
        llama_model_free(g_model); g_model = nullptr;
        env->ReleaseStringUTFChars(j_model_path,  model_path);
        env->ReleaseStringUTFChars(j_mmproj_path, mmproj_path);
        return JNI_FALSE;
    }

    LOGI("VLM loaded OK — vision: %s", mtmd_support_vision(g_mctx) ? "YES" : "NO");
    env->ReleaseStringUTFChars(j_model_path,  model_path);
    env->ReleaseStringUTFChars(j_mmproj_path, mmproj_path);
    return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_com_narrator_VlmBridge_nativeInfer(
        JNIEnv* env, jclass,
        jbyteArray j_image_bytes, jstring j_query) {

    if (!g_model || !g_ctx || !g_mctx)
        return env->NewStringUTF("Error: model not loaded");

    g_cancel.store(false);

    // ── 1. Decode image ───────────────────────────────────────────────────
    jsize  img_len  = env->GetArrayLength(j_image_bytes);
    jbyte* img_data = env->GetByteArrayElements(j_image_bytes, nullptr);
    mtmd_bitmap* bitmap = mtmd_helper_bitmap_init_from_buf(
        g_mctx,
        reinterpret_cast<const unsigned char*>(img_data),
        static_cast<size_t>(img_len));
    env->ReleaseByteArrayElements(j_image_bytes, img_data, JNI_ABORT);

    if (!bitmap) return env->NewStringUTF("Error: could not decode image");
    LOGI("Image: %ux%u", mtmd_bitmap_get_nx(bitmap), mtmd_bitmap_get_ny(bitmap));

    // ── 2. Build tight prompt ─────────────────────────────────────────────
    // Concise system instruction + user query + image marker.
    // The system prompt forces the model to stop after 1-3 sentences.
    const char* query = env->GetStringUTFChars(j_query, nullptr);
    std::string marker = mtmd_default_marker();
    std::string prompt =
        "Answer in 2-3 sentences maximum. Be brief and direct.\n"
        "Image: " + marker + "\n"
        "Question: " + std::string(query) + "\n"
        "Answer:";
    env->ReleaseStringUTFChars(j_query, query);
    LOGI("Prompt built (%zu chars)", prompt.size());

    // ── 3. Tokenize ───────────────────────────────────────────────────────
    const mtmd_bitmap* bitmaps[1] = { bitmap };
    mtmd_input_text input_text = { prompt.c_str(), true, true };
    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    int32_t tok_result = mtmd_tokenize(g_mctx, chunks, &input_text, bitmaps, 1);
    mtmd_bitmap_free(bitmap);

    if (tok_result != 0) {
        mtmd_input_chunks_free(chunks);
        LOGE("Tokenize failed: %d", tok_result);
        return env->NewStringUTF("Error: tokenization failed");
    }

    // ── 4. Prefill ────────────────────────────────────────────────────────
    llama_memory_clear(llama_get_memory(g_ctx), false);
    llama_pos n_past = 0;
    int32_t eval_result = mtmd_helper_eval_chunks(
        g_mctx, g_ctx, chunks, n_past, 0, 512, true, &n_past);
    mtmd_input_chunks_free(chunks);

    if (eval_result != 0) {
        LOGE("Prefill failed: %d", eval_result);
        return env->NewStringUTF("Error: prefill failed");
    }
    LOGI("Prefill done, n_past=%d", n_past);

    // ── 5. Generate — max 80 tokens, stop on EOS or sentence end ─────────
    const llama_vocab* vocab = llama_model_get_vocab(g_model);
    std::string output;
    output.reserve(256);
    const int MAX_TOKENS = 80; // ~2 sentences, fast on mobile CPU
    int sentence_count = 0;

    jclass  bridgeClass   = env->FindClass("com/narrator/VlmBridge");
    jmethodID onTokenMeth = bridgeClass
        ? env->GetStaticMethodID(bridgeClass, "onNativeToken", "(Ljava/lang/String;)V")
        : nullptr;

    for (int i = 0; i < MAX_TOKENS; i++) {
        if (g_cancel.load()) { LOGI("Cancelled at token %d", i); break; }

        // Greedy sampling
        float* logits = llama_get_logits(g_ctx);
        int n_vocab   = llama_vocab_n_tokens(vocab);
        llama_token best = 0;
        float best_val   = logits[0];
        for (int t = 1; t < n_vocab; t++) {
            if (logits[t] > best_val) { best_val = logits[t]; best = t; }
        }

        // Stop conditions
        if (llama_vocab_is_eog(vocab, best)) {
            LOGI("EOS at token %d", i);
            break;
        }

        char piece[256] = {};
        llama_token_to_piece(vocab, best, piece, sizeof(piece), 0, true);
        output += piece;

        // Count sentence endings — stop after 2 sentences
        for (char c : std::string(piece)) {
            if (c == '.' || c == '!' || c == '?') sentence_count++;
        }

        // Stream token to Flutter
        if (onTokenMeth && strlen(piece) > 0) {
            jstring jp = env->NewStringUTF(piece);
            env->CallStaticVoidMethod(bridgeClass, onTokenMeth, jp);
            env->DeleteLocalRef(jp);
        }

        // Hard stop after 2 complete sentences
        if (sentence_count >= 2) {
            LOGI("2-sentence limit reached at token %d", i);
            break;
        }

        llama_batch batch = llama_batch_get_one(&best, 1);
        if (llama_decode(g_ctx, batch) != 0) {
            LOGE("Decode failed at token %d", i);
            break;
        }
        n_past++;
    }

    if (bridgeClass) env->DeleteLocalRef(bridgeClass);

    // Trim trailing whitespace
    while (!output.empty() && (output.back() == ' ' || output.back() == '\n'))
        output.pop_back();

    LOGI("Generated: \"%s\" (%zu chars)", output.c_str(), output.size());
    return env->NewStringUTF(output.c_str());
}

JNIEXPORT void JNICALL
Java_com_narrator_VlmBridge_nativeRelease(JNIEnv*, jclass) {
    if (g_mctx)  { mtmd_free(g_mctx);         g_mctx  = nullptr; }
    if (g_ctx)   { llama_free(g_ctx);          g_ctx   = nullptr; }
    if (g_model) { llama_model_free(g_model);  g_model = nullptr; }
    LOGI("VLM released");
}

JNIEXPORT void JNICALL
Java_com_narrator_VlmBridge_nativeCancel(JNIEnv*, jclass) {
    g_cancel.store(true);
    LOGI("Cancel requested");
}

} // extern "C"
