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
  // The YOLO assets now point to the assistive-navigation fine-tuned weights
  // (7-class: obstacle / stairs / door / hazard / pole / person / vehicle).
  // Export from Roboflow as "YOLOv8 NCNN" → rename to these two files and
  // drop them into assets/models/ before building.
  static const String yolov8nParamAsset = 'assets/models/yolov8n_nav.ncnn.param';
  static const String yolov8nBinAsset   = 'assets/models/yolov8n_nav.ncnn.bin';
  static const String sileroVadAsset     = 'assets/models/silero_vad.onnx';

  // Remote URLs for large optional models (require internet on first use)
  // Whisper-tiny ONNX encoder — onnx-community (31MB)
  static const String whisperTinyOnnxUrl =
      'https://hf-mirror.com/onnx-community/whisper-tiny/resolve/main/onnx/encoder_model.onnx';

  // SmolVLM GGUF — ggml-org public repo (no auth required)
  static const String smolvlmModelUrl =
      'https://hf-mirror.com/ggml-org/SmolVLM-256M-Instruct-GGUF/resolve/main/SmolVLM-256M-Instruct-Q8_0.gguf';
  static const String smolvlmMmprojUrl =
      'https://hf-mirror.com/ggml-org/SmolVLM-256M-Instruct-GGUF/resolve/main/mmproj-SmolVLM-256M-Instruct-f16.gguf';

  // IndicTrans2 — large model, placeholder stub
  static const String indicTrans2OnnxUrl = '';

  // Legacy URL fields kept for ModelManager compatibility (nav model is bundled)
  static const String yolov8nParamUrl = '';
  static const String yolov8nBinUrl   = '';
  static const String sileroVadOnnxUrl = '';

  // ── Model File Names ────────────────────────────────────
  // Nav-specific YOLOv8n weights (7 classes, NCNN format).
  // Replace the old yolov8n.ncnn.* files with these in assets/models/.
  static const String yolov8nParamFile = 'yolov8n_nav.ncnn.param';
  static const String yolov8nBinFile   = 'yolov8n_nav.ncnn.bin';

  static const String smolvlmModelFile = 'SmolVLM-256M-Instruct-Q8_0.gguf';
  static const String smolvlmMmprojFile = 'mmproj-SmolVLM-256M-Instruct-f16.gguf';
  static const String indicTrans2File = 'indictrans2_int8.onnx';
  static const String whisperTinyFile = 'whisper_tiny_multilingual.onnx';
  static const String sileroVadFile = 'silero_vad.onnx';
  static const String qwen3VlFile = 'qwen3_vl_2b_q4.gguf';

  // SHA-256 hashes for integrity verification
  static const Map<String, String> modelHashes = {
    'silero_vad.onnx': 'placeholder_sha256_silero',
    'whisper_tiny_multilingual.onnx': 'placeholder_sha256_whisper',
    'indictrans2_int8.onnx': 'placeholder_sha256_indictrans2',
    'SmolVLM-256M-Instruct-Q8_0.gguf': 'placeholder_sha256_smolvlm_model',
    'mmproj-SmolVLM-256M-Instruct-f16.gguf': 'placeholder_sha256_smolvlm_mmproj',
    // Update these hashes after downloading the nav model from Roboflow
    'yolov8n_nav.ncnn.param': 'placeholder_sha256_nav_param',
    'yolov8n_nav.ncnn.bin':   'placeholder_sha256_nav_bin',
  };

  // ── Pipeline 1 Tuning ───────────────────────────────────
  static const int targetFps = 30;

  // Obstacle must occupy ≥5% of frame (typical walking distance)
  static const double obstacleAreaThreshold = 0.05;

  // Obstacle centre must be within the central 70% of frame (0.15 - 0.85).
  static const double obstacleMinCenterX = 0.15;
  static const double obstacleMaxCenterX = 0.85;

  // Obstacle must be in the lower 80% of the frame (centerY > 0.20).
  // This allows for phone tilt without filtering out real obstacles.
  static const double obstacleMinCenterY = 0.20;

  // Cooldown raised to 5 s so a sustained detection doesn't spam TTS/haptic
  // and block Pipeline 2 (VLM) from being used.
  static const int obstacleCooldownMs = 5000;

  // P2 busy guard: if Pipeline 2 is actively speaking/thinking, suppress P1
  // alerts entirely so the user can hear the VLM response.
  // Pattern: [silence, vibrate, silence, vibrate, silence]
  static const List<int> obstaclePulsePattern = [0, 100, 80, 100, 0];

  // ── Pipeline 2 Tuning ───────────────────────────────────
  static const int frameBufferSize = 10;
  static const double vadSpeechThreshold = 0.5;
  static const int vadSilenceMs = 700; // silence after speech = end of query
  static const int maxRecordingSeconds = 30;

  // ── Online STT ──────────────────────────────────────────
  static const String groqApiBaseUrl = 'https://api.groq.com/openai/v1';
  static const String groqWhisperModel = 'whisper-large-v3-turbo';
  // API key stored in secure storage / env — never hardcoded
  static const String groqApiKeyPrefKey = 'groq_api_key';

  // ── Languages ───────────────────────────────────────────
  static const List<Map<String, String>> supportedLanguages = [
    {'code': 'hi', 'name': 'हिन्दी', 'nameEn': 'Hindi', 'locale': 'hi-IN'},
    {'code': 'en', 'name': 'English', 'nameEn': 'English', 'locale': 'en-IN'},
    {'code': 'ta', 'name': 'தமிழ்', 'nameEn': 'Tamil', 'locale': 'ta-IN'},
    {'code': 'te', 'name': 'తెలుగు', 'nameEn': 'Telugu', 'locale': 'te-IN'},
    {'code': 'bn', 'name': 'বাংলা', 'nameEn': 'Bengali', 'locale': 'bn-IN'},
    {'code': 'mr', 'name': 'मराठी', 'nameEn': 'Marathi', 'locale': 'mr-IN'},
    {'code': 'kn', 'name': 'ಕನ್ನಡ', 'nameEn': 'Kannada', 'locale': 'kn-IN'},
  ];

  // ── Obstacle Alert Messages ─────────────────────────────
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
  static const int qwen3MinRamMb = 5500; // 6GB minus OS overhead
}
