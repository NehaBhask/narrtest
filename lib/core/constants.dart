/// App-wide constants for Narrator.
library narrator.constants;

// ── Model file names ────────────────────────────────────────────────────────
class ModelFiles {
  static const String yoloParam    = 'yolov8n.ncnn.param';
  static const String yoloBin      = 'yolov8n.ncnn.bin';
  static const String sileroVad    = 'silero_vad.onnx';
  static const String whisperTiny  = 'whisper_tiny_multilingual.onnx';
  static const String indicTrans2  = 'indictrans2_int8.onnx';
  static const String smolvlm      = 'smolvlm_256m_q4.gguf';
  static const String qwen3vl      = 'qwen3_vl_2b_q4.gguf';
  static const String qwen3mmproj  = 'qwen3_vl_2b_mmproj.gguf';
  static const String smolvlmMmproj = 'smolvlm_256m_mmproj.gguf';
}

// ── Model download URLs ─────────────────────────────────────────────────────
class ModelUrls {
  static const String base =
      'https://huggingface.co/narrator-app/narrator-models/resolve/main';
  static String yoloParam()   => '$base/${ModelFiles.yoloParam}';
  static String yoloBin()     => '$base/${ModelFiles.yoloBin}';
  static String sileroVad()   => '$base/${ModelFiles.sileroVad}';
  static String whisperTiny() => '$base/${ModelFiles.whisperTiny}';
  static String indicTrans2() => '$base/${ModelFiles.indicTrans2}';
  static String smolvlm()     => '$base/${ModelFiles.smolvlm}';
  static String smolvlmMmproj() => '$base/${ModelFiles.smolvlmMmproj}';
  static String qwen3vl()     => '$base/${ModelFiles.qwen3vl}';
  static String qwen3mmproj() => '$base/${ModelFiles.qwen3mmproj}';
}

// ── Model SHA-256 checksums (for integrity verification) ────────────────────
class ModelChecksums {
  static const Map<String, String> sha256 = {
    'yolov8n.ncnn.param': 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2',
    'yolov8n.ncnn.bin':   'b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3',
    'silero_vad.onnx':    'c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4',
  };
}

// ── Detection / pipeline tuning ─────────────────────────────────────────────
class DetectionConfig {
  /// Minimum confidence to report an obstacle.
  static const double confidenceThreshold = 0.45;

  /// IoU threshold for non-maximum suppression.
  static const double nmsIouThreshold = 0.45;

  /// Fraction of frame width/height that counts as "close" obstacle.
  static const double closeObstacleFraction = 0.35;

  /// Minimum ms between repeated alerts for the same obstacle class.
  static const int alertCooldownMs = 2000;

  /// YOLO input resolution.
  static const int yoloInputSize = 640;
}

// ── VAD config ───────────────────────────────────────────────────────────────
class VadConfig {
  static const double speechThreshold    = 0.5;
  static const double silenceThreshold   = 0.35;
  static const int    sampleRate         = 16000;
  static const int    windowSizeSamples  = 512;
  static const int    silenceTimeoutMs   = 700;
}

// ── Supported languages ──────────────────────────────────────────────────────
class SupportedLanguages {
  static const List<Map<String, String>> all = [
    {'code': 'en', 'name': 'English',    'native': 'English'},
    {'code': 'hi', 'name': 'Hindi',      'native': 'हिन्दी'},
    {'code': 'ta', 'name': 'Tamil',      'native': 'தமிழ்'},
    {'code': 'te', 'name': 'Telugu',     'native': 'తెలుగు'},
    {'code': 'bn', 'name': 'Bengali',    'native': 'বাংলা'},
    {'code': 'mr', 'name': 'Marathi',    'native': 'मराठी'},
    {'code': 'kn', 'name': 'Kannada',    'native': 'ಕನ್ನಡ'},
  ];

  static const String defaultCode = 'en';

  static bool isSupported(String code) =>
      all.any((l) => l['code'] == code);

  static String nativeName(String code) =>
      all.firstWhere((l) => l['code'] == code,
          orElse: () => {'native': code})['native']!;
}

// ── RAM thresholds ───────────────────────────────────────────────────────────
class RamThresholds {
  /// Devices with >= this RAM (MB) get Qwen3-VL-2B; others get SmolVLM-256M.
  static const int enhancedVlmMinRamMb = 6000;
}

// ── DPDP / privacy ──────────────────────────────────────────────────────────
class PrivacyConfig {
  static const String grievanceEmail = 'privacy@narrator-app.in';
  static const int    auditLogMaxEntries = 500;
  static const String consentVersion = '1.0';
}
