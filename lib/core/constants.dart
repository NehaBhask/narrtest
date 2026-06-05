/// Application-wide constants for Narrator.
library;

class AppConstants {
  AppConstants._();

  // ── App Identity ────────────────────────────────────────
  static const String appName = 'Narrator';
  static const String appVersion = '1.0.0';
  static const String privacyPolicyVersion = '1.0';

  // ── DPDP ────────────────────────────────────────────────
  static const String dpdpConsentKey = 'dpdp_consent_v1';
  static const String dpdpConsentTimestampKey = 'dpdp_consent_timestamp';
  static const String dpdpOnlineSttConsentKey = 'dpdp_online_stt_consent';
  static const String dpdpAnalyticsConsentKey = 'dpdp_analytics_consent';
  static const String privacyPolicyVersionKey = 'privacy_policy_version';

  // ── Model Paths ─────────────────────────────────────────
  static const String modelDirName = 'narrator_models';

  // Asset paths for core models bundled in APK (no download needed).
  // The YOLO assets now point to the standard YOLOv8n COCO 80-class weights
  // converted to NCNN format via: yolo export model=yolov8n.pt format=ncnn
  // Place the exported yolov8n.ncnn.param + yolov8n.ncnn.bin in assets/models/
  static const String yolov8nParamAsset = 'assets/models/yolov8n.ncnn.param';
  static const String yolov8nBinAsset   = 'assets/models/yolov8n.ncnn.bin';
  static const String sileroVadAsset    = 'assets/models/silero_vad.onnx';

  // Remote URLs for large optional models (require internet on first use)
  static const String whisperTinyOnnxUrl =
      'https://hf-mirror.com/onnx-community/whisper-tiny/resolve/main/onnx/encoder_model.onnx';
  static const String smolvlmModelUrl =
      'https://hf-mirror.com/ggml-org/SmolVLM-256M-Instruct-GGUF/resolve/main/SmolVLM-256M-Instruct-Q8_0.gguf';
  static const String smolvlmMmprojUrl =
      'https://hf-mirror.com/ggml-org/SmolVLM-256M-Instruct-GGUF/resolve/main/mmproj-SmolVLM-256M-Instruct-f16.gguf';
  static const String indicTrans2OnnxUrl = '';

  // Legacy URL fields kept for ModelManager compatibility
  static const String yolov8nParamUrl = '';
  static const String yolov8nBinUrl   = '';
  static const String sileroVadOnnxUrl = '';

  // ── Model File Names ────────────────────────────────────
  static const String yolov8nParamFile = 'yolov8n.ncnn.param';
  static const String yolov8nBinFile   = 'yolov8n.ncnn.bin';

  static const String smolvlmModelFile = 'SmolVLM-256M-Instruct-Q8_0.gguf';
  static const String smolvlmMmprojFile = 'mmproj-SmolVLM-256M-Instruct-f16.gguf';
  static const String indicTrans2File = 'indictrans2_int8.onnx';
  static const String whisperTinyFile = 'whisper_tiny_multilingual.onnx';
  static const String whisperEncoderFile = 'encoder_model.onnx';
  static const String whisperDecoderFile = 'decoder_model.onnx';
  static const String whisperDecoderWithPastFile = 'decoder_with_past_model.onnx';
  static const String sileroVadFile = 'silero_vad.onnx';
  static const String qwen3VlFile = 'qwen3_vl_2b_q4.gguf';

  // SHA-256 hashes for integrity verification
  static const Map<String, String> modelHashes = {
    'silero_vad.onnx': 'placeholder_sha256_silero',
    'whisper_tiny_multilingual.onnx': 'placeholder_sha256_whisper',
    'indictrans2_int8.onnx': 'placeholder_sha256_indictrans2',
    'SmolVLM-256M-Instruct-Q8_0.gguf': 'placeholder_sha256_smolvlm_model',
    'mmproj-SmolVLM-256M-Instruct-f16.gguf': 'placeholder_sha256_smolvlm_mmproj',
    'yolov8n.ncnn.param': 'placeholder_sha256_yolo_param',
    'yolov8n.ncnn.bin':   'placeholder_sha256_yolo_bin',
  };

  // ── COCO 80-Class Label List ────────────────────────────
  // Standard COCO dataset class names, index 0–79.
  // These MUST match the label order of the NCNN-exported YOLOv8n model.
  // Source: https://github.com/ultralytics/ultralytics/blob/main/ultralytics/cfg/datasets/coco.yaml
  static const List<String> cocoClassNames = [
    'person',        // 0
    'bicycle',       // 1
    'car',           // 2
    'motorcycle',    // 3
    'airplane',      // 4
    'bus',           // 5
    'train',         // 6
    'truck',         // 7
    'boat',          // 8
    'traffic light', // 9
    'fire hydrant',  // 10
    'stop sign',     // 11
    'parking meter', // 12
    'bench',         // 13
    'bird',          // 14
    'cat',           // 15
    'dog',           // 16
    'horse',         // 17
    'sheep',         // 18
    'cow',           // 19
    'elephant',      // 20
    'bear',          // 21
    'zebra',         // 22
    'giraffe',       // 23
    'backpack',      // 24
    'umbrella',      // 25
    'handbag',       // 26
    'tie',           // 27
    'suitcase',      // 28
    'frisbee',       // 29
    'skis',          // 30
    'snowboard',     // 31
    'sports ball',   // 32
    'kite',          // 33
    'baseball bat',  // 34
    'baseball glove',// 35
    'skateboard',    // 36
    'surfboard',     // 37
    'tennis racket', // 38
    'bottle',        // 39
    'wine glass',    // 40
    'cup',           // 41
    'fork',          // 42
    'knife',         // 43
    'spoon',         // 44
    'bowl',          // 45
    'banana',        // 46
    'apple',         // 47
    'sandwich',      // 48
    'orange',        // 49
    'broccoli',      // 50
    'carrot',        // 51
    'hot dog',       // 52
    'pizza',         // 53
    'donut',         // 54
    'cake',          // 55
    'chair',         // 56
    'couch',         // 57
    'potted plant',  // 58
    'bed',           // 59
    'dining table',  // 60
    'toilet',        // 61
    'tv',            // 62
    'laptop',        // 63
    'mouse',         // 64
    'remote',        // 65
    'keyboard',      // 66
    'cell phone',    // 67
    'microwave',     // 68
    'oven',          // 69
    'toaster',       // 70
    'sink',          // 71
    'refrigerator',  // 72
    'book',          // 73
    'clock',         // 74
    'vase',          // 75
    'scissors',      // 76
    'teddy bear',    // 77
    'hair drier',    // 78
    'toothbrush',    // 79
  ];

  // ── Navigation-Relevant COCO Classes ───────────────────
  // Only these class IDs will trigger obstacle alerts.
  // Everything else (e.g., spoon, kite, toothbrush) is ignored.
  static const Set<int> navigationRelevantClassIds = {
    0,  // person
    1,  // bicycle
    2,  // car
    3,  // motorcycle
    5,  // bus
    7,  // truck
    9,  // traffic light
    10, // fire hydrant
    11, // stop sign
    13, // bench
    24, // backpack
    28, // suitcase
    56, // chair
    57, // couch
    59, // bed
    60, // dining table
    63, // laptop
  };

  // ── Pipeline 1 Tuning ───────────────────────────────────
  static const int targetFps = 30;

  /// Minimum YOLO detection confidence (0–1).
  /// Detections below this are silently discarded to suppress ghost boxes.
  static const double minConfidenceThreshold = 0.40;

  /// Minimum IoU overlap to consider two boxes as duplicates (Dart-side NMS).
  static const double nmsIouThreshold = 0.45;

  /// Frame capture interval in milliseconds.
  /// 300ms → ~3.3 effective YOLO fps via takePicture() approach.
  static const int captureIntervalMs = 300;

  /// Frame age accepted by P2 selectSharpestFrame() in milliseconds.
  static const int maxFrameAgeMs = 800;

  // Obstacle must occupy ≥6% of frame to be considered near-field.
  static const double obstacleAreaThreshold = 0.06;

  // Obstacle centre must be within the central 70% of frame (0.15 – 0.85).
  static const double obstacleMinCenterX = 0.15;
  static const double obstacleMaxCenterX = 0.85;

  // Obstacle must be in the lower 80% of the frame (centerY > 0.20).
  static const double obstacleMinCenterY = 0.20;

  /// If obstacle area ≥ this value, it is extremely close → urgent alert.
  static const double obstacleUrgentAreaThreshold = 0.20;

  // Cooldown reduced to 3s for more responsive alerts.
  static const int obstacleCooldownMs = 3000;

  // Haptic pulse pattern for obstacle alert [wait, vibrate, wait, vibrate, wait]
  // 5 entries → intensities must also have 5 entries.
  static const List<int> obstaclePulsePattern = [0, 120, 80, 120, 0];
  static const List<int> obstaclePulseIntensities = [0, 220, 0, 220, 0];

  // ── Pipeline 2 Tuning ───────────────────────────────────
  static const int frameBufferSize = 10;
  static const double vadSpeechThreshold = 0.5;
  static const int vadSilenceMs = 700;
  static const int maxRecordingSeconds = 30;

  /// Hard timeout for VLM generation in seconds.
  static const int maxVlmTimeoutSeconds = 12;

  /// If no VLM token received within this many seconds, speak a wait message.
  static const int vlmFirstTokenTimeoutSeconds = 3;

  // ── TTS Speed ───────────────────────────────────────────
  /// Speech rate for urgent obstacle alerts (faster = more urgency).
  static const double alertSpeechRate = 0.65;

  /// Speech rate for VLM conversational responses (slower = clearer).
  static const double responseSpeechRate = 0.52;

  // ── Online STT ──────────────────────────────────────────
  static const String groqApiBaseUrl = 'https://api.groq.com/openai/v1';
  static const String groqWhisperModel = 'whisper-large-v3-turbo';
  // API key must be set in Settings — never hardcoded in source.
  static const String groqApiKeyPrefKey = 'groq_api_key';

  // ── Languages ───────────────────────────────────────────
  static const List<Map<String, String>> supportedLanguages = [
    {'code': 'hi', 'name': 'हिन्दी',  'nameEn': 'Hindi',   'locale': 'hi-IN'},
    {'code': 'en', 'name': 'English', 'nameEn': 'English', 'locale': 'en-IN'},
    {'code': 'ta', 'name': 'தமிழ்',  'nameEn': 'Tamil',   'locale': 'ta-IN'},
    {'code': 'te', 'name': 'తెలుగు', 'nameEn': 'Telugu',  'locale': 'te-IN'},
    {'code': 'bn', 'name': 'বাংলা',  'nameEn': 'Bengali', 'locale': 'bn-IN'},
    {'code': 'mr', 'name': 'मराठी',  'nameEn': 'Marathi', 'locale': 'mr-IN'},
    {'code': 'kn', 'name': 'ಕನ್ನಡ', 'nameEn': 'Kannada', 'locale': 'kn-IN'},
  ];

  // ── Obstacle Alert Messages ─────────────────────────────
  // These are used as fallback when no class name can be determined.
  static const Map<String, String> obstacleAlertMessages = {
    'hi': 'आगे कुछ है, सावधान',
    'en': 'Obstacle ahead',
    'ta': 'முன்னால் தடை உள்ளது',
    'te': 'ముందు అడ్డంకి ఉంది',
    'bn': 'সামনে বাধা আছে',
    'mr': 'पुढे अडथळा आहे',
    'kn': 'ಮುಂದೆ ಅಡಚಣೆ ಇದೆ',
  };

  // ── Device Tier ─────────────────────────────────────────
  static const int qwen3MinRamMb = 5500;
}
