#include <jni.h>
#include <string>
#include <vector>
#include <android/log.h>
#include "ncnn/net.h"
#include "ncnn/mat.h"

#define LOG_TAG "NarratorNCNN"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

struct Detection {
    int   classId;
    float confidence;
    float x1, y1, x2, y2;   // normalised [0,1]
};

// ── Full COCO-80 class names ──────────────────────────────────────────────────
// YOLOv8n was trained on COCO which has exactly 80 classes.
// These are ALL the classes the model can detect — no retraining needed.
// We use ALL 80 here so the UI shows real names, not "cls2".
static const char* COCO_NAMES[80] = {
    "person",        "bicycle",       "car",           "motorcycle",    "airplane",
    "bus",           "train",         "truck",         "boat",          "traffic light",
    "fire hydrant",  "stop sign",     "parking meter", "bench",         "bird",
    "cat",           "dog",           "horse",         "sheep",         "cow",
    "elephant",      "bear",          "zebra",         "giraffe",       "backpack",
    "umbrella",      "handbag",       "tie",           "suitcase",      "frisbee",
    "skis",          "snowboard",     "sports ball",   "kite",          "baseball bat",
    "baseball glove","skateboard",    "surfboard",     "tennis racket", "bottle",
    "wine glass",    "cup",           "fork",          "knife",         "spoon",
    "bowl",          "banana",        "apple",         "sandwich",      "orange",
    "broccoli",      "carrot",        "hot dog",       "pizza",         "donut",
    "cake",          "chair",         "couch",         "potted plant",  "bed",
    "dining table",  "toilet",        "tv",            "laptop",        "mouse",
    "remote",        "keyboard",      "cell phone",    "microwave",     "oven",
    "toaster",       "sink",          "refrigerator",  "book",          "clock",
    "vase",          "scissors",      "teddy bear",    "hair drier",    "toothbrush"
};

// ── Obstacle classes for Pipeline 1 (navigation safety) ──────────────────────
// These are the classes that MATTER for a visually impaired person walking.
// Expanded from original list — includes ALL things a person could walk into.
static const bool IS_OBSTACLE[80] = {
    true,  // 0  person
    true,  // 1  bicycle
    true,  // 2  car
    true,  // 3  motorcycle
    false, // 4  airplane
    true,  // 5  bus
    false, // 6  train
    true,  // 7  truck
    false, // 8  boat
    true,  // 9  traffic light
    true,  // 10 fire hydrant
    true,  // 11 stop sign
    false, // 12 parking meter
    true,  // 13 bench
    false, // 14 bird
    false, // 15 cat
    true,  // 16 dog
    false, // 17 horse
    false, // 18 sheep
    false, // 19 cow
    false, // 20 elephant
    false, // 21 bear
    false, // 22 zebra
    false, // 23 giraffe
    true,  // 24 backpack
    false, // 25 umbrella
    false, // 26 handbag
    false, // 27 tie
    true,  // 28 suitcase
    false, // 29 frisbee
    false, // 30 skis
    false, // 31 snowboard
    false, // 32 sports ball
    false, // 33 kite
    false, // 34 baseball bat
    false, // 35 baseball glove
    true,  // 36 skateboard
    false, // 37 surfboard
    false, // 38 tennis racket
    true,  // 39 bottle
    false, // 40 wine glass
    true,  // 41 cup
    false, // 42 fork
    false, // 43 knife
    false, // 44 spoon
    false, // 45 bowl
    false, // 46 banana
    false, // 47 apple
    false, // 48 sandwich
    false, // 49 orange
    false, // 50 broccoli
    false, // 51 carrot
    false, // 52 hot dog
    false, // 53 pizza
    false, // 54 donut
    false, // 55 cake
    true,  // 56 chair
    true,  // 57 couch
    true,  // 58 potted plant
    true,  // 59 bed
    true,  // 60 dining table
    true,  // 61 toilet
    true,  // 62 tv
    true,  // 63 laptop
    false, // 64 mouse
    false, // 65 remote
    false, // 66 keyboard
    false, // 67 cell phone
    false, // 68 microwave
    false, // 69 oven
    false, // 70 toaster
    true,  // 71 sink
    true,  // 72 refrigerator
    false, // 73 book
    false, // 74 clock
    false, // 75 vase
    false, // 76 scissors
    false, // 77 teddy bear
    false, // 78 hair drier
    false, // 79 toothbrush
};

static ncnn::Net yoloNet;
static bool      modelLoaded    = false;
static const int INPUT_SIZE     = 320;

// ── Tuned thresholds ──────────────────────────────────────────────────────────
// CONF_THRESHOLD 0.50: per-anchor minimum score. Keeping at 0.50 because the
//   real fix is correct box normalisation (÷INPUT_SIZE) and output-layout
//   detection, not just raising the score bar.
// NMS_THRESHOLD 0.30: aggressive same-class merge — kills duplicate boxes.
// CROSS_CLASS_NMS_IOU 0.50: if two boxes of DIFFERENT classes overlap >50%
//   keep only the higher-confidence one. Eliminates truck/bicycle on same region.
// MAX_DETECTIONS 6: hard cap so the UI never floods even in edge cases.
static const float CONF_THRESHOLD       = 0.50f;  // minimum per-anchor class score
static const float NMS_THRESHOLD        = 0.30f;  // same-class IoU merge threshold
static const float CROSS_CLASS_NMS_IOU  = 0.50f;  // cross-class suppression IoU
static const int   MAX_DETECTIONS       = 6;      // hard cap on final output boxes

// ── JNI: nativeLoadModel ─────────────────────────────────────────────────────
extern "C" JNIEXPORT jboolean JNICALL
Java_com_narrator_NarratorPlugin_nativeLoadModel(
    JNIEnv *env, jobject /*thiz*/,
    jstring paramPath, jstring binPath) {

    const char *param = env->GetStringUTFChars(paramPath, nullptr);
    const char *bin   = env->GetStringUTFChars(binPath,   nullptr);
    LOGI("Loading model param=%s", param);

    yoloNet.opt.use_vulkan_compute = false;
    yoloNet.opt.num_threads        = 4;
    yoloNet.opt.use_bf16_storage   = false;

    int ret = yoloNet.load_param(param);
    if (ret != 0) {
        LOGE("load_param failed ret=%d", ret);
        env->ReleaseStringUTFChars(paramPath, param);
        env->ReleaseStringUTFChars(binPath,   bin);
        return JNI_FALSE;
    }
    ret = yoloNet.load_model(bin);
    if (ret != 0) {
        LOGE("load_model failed ret=%d", ret);
        env->ReleaseStringUTFChars(paramPath, param);
        env->ReleaseStringUTFChars(binPath,   bin);
        return JNI_FALSE;
    }

    env->ReleaseStringUTFChars(paramPath, param);
    env->ReleaseStringUTFChars(binPath,   bin);
    modelLoaded = true;
    LOGI("YOLOv8-nano loaded OK");
    return JNI_TRUE;
}

// ── IoU helper ───────────────────────────────────────────────────────────────
static float iou(const Detection &a, const Detection &b) {
    float ix1  = std::max(a.x1, b.x1), iy1 = std::max(a.y1, b.y1);
    float ix2  = std::min(a.x2, b.x2), iy2 = std::min(a.y2, b.y2);
    float inter = std::max(0.f, ix2-ix1) * std::max(0.f, iy2-iy1);
    float ua    = (a.x2-a.x1)*(a.y2-a.y1) + (b.x2-b.x1)*(b.y2-b.y1) - inter;
    return inter / (ua + 1e-6f);
}

// ── Two-pass NMS ─────────────────────────────────────────────────────────────
// Pass 1: per-class NMS  (same class, IoU > NMS_THRESHOLD)
// Pass 2: cross-class suppression (any class, IoU > CROSS_CLASS_NMS_IOU)
//         keeps only the higher-confidence box — eliminates the situation
//         where a "person" and "car" box are drawn on the same region.
static std::vector<Detection> twoPassNms(std::vector<Detection> &dets) {
    std::sort(dets.begin(), dets.end(),
        [](const Detection &a, const Detection &b){ return a.confidence > b.confidence; });

    std::vector<bool> suppressed(dets.size(), false);

    // Pass 1 — same-class
    for (size_t i = 0; i < dets.size(); i++) {
        if (suppressed[i]) continue;
        for (size_t j = i+1; j < dets.size(); j++) {
            if (!suppressed[j] && dets[i].classId == dets[j].classId
                && iou(dets[i], dets[j]) > NMS_THRESHOLD)
                suppressed[j] = true;
        }
    }
    // Pass 2 — cross-class
    for (size_t i = 0; i < dets.size(); i++) {
        if (suppressed[i]) continue;
        for (size_t j = i+1; j < dets.size(); j++) {
            if (!suppressed[j] && dets[i].classId != dets[j].classId
                && iou(dets[i], dets[j]) > CROSS_CLASS_NMS_IOU)
                suppressed[j] = true;   // i has higher conf (sorted), suppress j
        }
    }

    std::vector<Detection> result;
    for (size_t i = 0; i < dets.size(); i++)
        if (!suppressed[i]) result.push_back(dets[i]);
    return result;
}

// ── Core inference ────────────────────────────────────────────────────────────
static std::vector<Detection> runInference(
        const unsigned char* rgbData, int srcW, int srcH) {

    ncnn::Mat in = ncnn::Mat::from_pixels_resize(
        rgbData, ncnn::Mat::PIXEL_RGB, srcW, srcH, INPUT_SIZE, INPUT_SIZE);
    const float norm[3] = {1.f/255.f, 1.f/255.f, 1.f/255.f};
    in.substract_mean_normalize(nullptr, norm);

    ncnn::Extractor ex = yoloNet.create_extractor();
    ex.set_light_mode(true);
    ex.input("in0", in);

    ncnn::Mat out;
    // YOLOv8n NCNN export: try both common output node names
    int ret = ex.extract("output0", out);
    if (ret != 0 || out.empty()) {
        ret = ex.extract("out0", out);
    }
    if (ret != 0 || out.empty()) {
        LOGE("extract failed — tried output0 and out0. ret=%d w=%d h=%d", ret, out.w, out.h);
        return {};
    }

    // This model's param file (cat_16 axis=0) produces out0 shape [8400, 84]:
    //   rows = 8400 anchors, cols = [cx, cy, bw, bh, 80×class_score]
    // Box coords (cx,cy,bw,bh) are decoded anchor-point coordinates already
    // in INPUT_SIZE pixel space (0–320) via the fold_anchor_points + mul_11
    // path in the param graph. Class scores are already sigmoid'd.
    // The transposed layout (w=8400, h=84) is NOT used by this export.
    const bool transposed  = (out.w == 84 && out.h == 8400) ? false
                           : (out.w == 8400 && out.h == 84);  // guard for both
    const int  num_anchors = transposed ? out.w : out.h;
    const int  num_feats   = transposed ? out.h : out.w;
    const int  num_classes = num_feats - 4;

    LOGI("NCNN out0: w=%d h=%d → anchors=%d feats=%d transposed=%d",
         out.w, out.h, num_anchors, num_feats, (int)transposed);

    if (num_classes != 80) {
        LOGE("Unexpected class count %d — model/param mismatch?", num_classes);
        return {};
    }

    std::vector<Detection> candidates;
    candidates.reserve(64);

    for (int i = 0; i < num_anchors; i++) {
        // Read the 84-element feature vector for anchor i
        float cx, cy, bw, bh;
        float classScores[80];

        if (transposed) {
            // Each row in 'out' is one feature dimension across all anchors
            cx = out.row(0)[i];
            cy = out.row(1)[i];
            bw = out.row(2)[i];
            bh = out.row(3)[i];
            for (int c = 0; c < 80; c++) classScores[c] = out.row(4 + c)[i];
        } else {
            const float* row = out.row(i);
            cx = row[0]; cy = row[1]; bw = row[2]; bh = row[3];
            for (int c = 0; c < 80; c++) classScores[c] = row[4 + c];
        }

        // Find the best class
        float maxConf = -1.f;
        int   bestCls = -1;
        for (int c = 0; c < 80; c++) {
            if (classScores[c] > maxConf) { maxConf = classScores[c]; bestCls = c; }
        }

        if (maxConf < CONF_THRESHOLD)     continue;
        if (bestCls < 0 || bestCls >= 80) continue;
        if (!IS_OBSTACLE[bestCls])        continue;

        // YOLOv8 NCNN exports box coords in INPUT_SIZE pixel space (0–320).
        // Normalise to [0,1] by dividing by INPUT_SIZE.
        const float scale = 1.0f / INPUT_SIZE;
        float x1 = std::max(0.f, std::min(1.f, (cx - bw * 0.5f) * scale));
        float y1 = std::max(0.f, std::min(1.f, (cy - bh * 0.5f) * scale));
        float x2 = std::max(0.f, std::min(1.f, (cx + bw * 0.5f) * scale));
        float y2 = std::max(0.f, std::min(1.f, (cy + bh * 0.5f) * scale));

        // Skip degenerate or near-zero boxes
        if ((x2 - x1) < 0.02f || (y2 - y1) < 0.02f) continue;

        candidates.push_back({bestCls, maxConf, x1, y1, x2, y2});
    }

    auto result = twoPassNms(candidates);

    // Hard cap: keep only the N highest-confidence detections
    if ((int)result.size() > MAX_DETECTIONS)
        result.resize(MAX_DETECTIONS);

    LOGI("Detections: %zu final (from %zu candidates, conf>%.2f)",
         result.size(), candidates.size(), CONF_THRESHOLD);

    for (auto &d : result) {
        const char* name = (d.classId >= 0 && d.classId < 80)
                           ? COCO_NAMES[d.classId] : "unknown";
        LOGI("  -> %s (cls%d) conf=%.2f box=[%.2f,%.2f,%.2f,%.2f]",
             name, d.classId, d.confidence, d.x1, d.y1, d.x2, d.y2);
    }

    return result;
}

// ── Pack result: classId + confidence + box ───────────────────────────────────
static jfloatArray packDetections(JNIEnv *env, const std::vector<Detection> &result) {
    jfloatArray ret = env->NewFloatArray((jsize)(result.size() * 6));
    if (!result.empty()) {
        std::vector<float> buf;
        buf.reserve(result.size() * 6);
        for (auto &d : result) {
            buf.push_back((float)d.classId);
            buf.push_back(d.confidence);
            buf.push_back(d.x1); buf.push_back(d.y1);
            buf.push_back(d.x2); buf.push_back(d.y2);
        }
        env->SetFloatArrayRegion(ret, 0, (jsize)buf.size(), buf.data());
    }
    return ret;
}

// ── JNI: nativeDetectObjects (NV21 from JPEG decode in Kotlin) ────────────────
extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_narrator_NarratorPlugin_nativeDetectObjects(
    JNIEnv *env, jobject /*thiz*/,
    jbyteArray yuvData, jint width, jint height) {

    if (!modelLoaded) { LOGE("Model not loaded"); return env->NewFloatArray(0); }

    jbyte *yuv = env->GetByteArrayElements(yuvData, nullptr);
    std::vector<unsigned char> rgb((size_t)(width * height * 3));
    ncnn::yuv420sp2rgb(reinterpret_cast<const unsigned char*>(yuv), width, height, rgb.data());
    env->ReleaseByteArrayElements(yuvData, yuv, JNI_ABORT);

    auto result = runInference(rgb.data(), width, height);
    return packDetections(env, result);
}

// ── JNI: nativeReleaseModel ──────────────────────────────────────────────────
extern "C" JNIEXPORT void JNICALL
Java_com_narrator_NarratorPlugin_nativeReleaseModel(
    JNIEnv * /*env*/, jobject /*thiz*/) {
    yoloNet.clear();
    modelLoaded = false;
    LOGI("Model released");
}
