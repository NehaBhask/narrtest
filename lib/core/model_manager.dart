import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'constants.dart';

enum ModelStatus { notDownloaded, downloading, ready, corrupt }

class ModelInfo {
  final String fileName;
  final String downloadUrl;
  final ModelStatus status;
  final double progress; // 0.0 – 1.0

  const ModelInfo({
    required this.fileName,
    required this.downloadUrl,
    this.status   = ModelStatus.notDownloaded,
    this.progress = 0.0,
  });

  ModelInfo copyWith({ModelStatus? status, double? progress}) => ModelInfo(
    fileName:    fileName,
    downloadUrl: downloadUrl,
    status:      status   ?? this.status,
    progress:    progress ?? this.progress,
  );

  bool get isReady => status == ModelStatus.ready;
}

/// Manages on-device AI model downloads, integrity checks, and lifecycle.
class ModelManager {
  static const _modelsDir = 'narrator_models';

  final http.Client _httpClient;

  ModelManager({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  Future<Directory> get modelsDirectory async {
    final docs = await getApplicationDocumentsDirectory();
    final dir  = Directory(p.join(docs.path, _modelsDir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<String> modelPath(String fileName) async {
    final dir = await modelsDirectory;
    return p.join(dir.path, fileName);
  }

  Future<bool> modelExists(String fileName) async {
    final path = await modelPath(fileName);
    return File(path).existsSync();
  }

  /// Verify SHA-256 checksum of a downloaded model.
  /// Returns true if no checksum is registered (unknown model).
  Future<bool> verifyIntegrity(String fileName) async {
    final expected = ModelChecksums.sha256[fileName];
    if (expected == null) return true; // no checksum registered

    final path = await modelPath(fileName);
    final file = File(path);
    if (!file.existsSync()) return false;

    final bytes  = await file.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    return digest == expected;
  }

  /// Download a model with progress callback.
  /// Throws [ModelDownloadException] on failure.
  Future<void> downloadModel(
    String fileName,
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    final path   = await modelPath(fileName);
    final file   = File(path);
    final request = http.Request('GET', Uri.parse(url));
    final response = await _httpClient.send(request);

    if (response.statusCode != 200) {
      throw ModelDownloadException(
          'HTTP ${response.statusCode} downloading $fileName');
    }

    final total = response.contentLength ?? 0;
    int received = 0;
    final sink = file.openWrite();

    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();
  }

  /// Returns list of model infos with current status.
  Future<List<ModelInfo>> getModelStatuses() async {
    final models = [
      ModelInfo(fileName: ModelFiles.yoloParam,   downloadUrl: ModelUrls.yoloParam()),
      ModelInfo(fileName: ModelFiles.yoloBin,     downloadUrl: ModelUrls.yoloBin()),
      ModelInfo(fileName: ModelFiles.sileroVad,   downloadUrl: ModelUrls.sileroVad()),
      ModelInfo(fileName: ModelFiles.whisperTiny, downloadUrl: ModelUrls.whisperTiny()),
      ModelInfo(fileName: ModelFiles.indicTrans2, downloadUrl: ModelUrls.indicTrans2()),
      ModelInfo(fileName: ModelFiles.smolvlm,     downloadUrl: ModelUrls.smolvlm()),
      ModelInfo(fileName: ModelFiles.smolvlmMmproj, downloadUrl: ModelUrls.smolvlmMmproj()),
    ];

    final result = <ModelInfo>[];
    for (final m in models) {
      final exists = await modelExists(m.fileName);
      if (!exists) {
        result.add(m.copyWith(status: ModelStatus.notDownloaded));
      } else {
        final valid = await verifyIntegrity(m.fileName);
        result.add(m.copyWith(
          status: valid ? ModelStatus.ready : ModelStatus.corrupt,
        ));
      }
    }
    return result;
  }

  /// True when all mandatory models are ready.
  Future<bool> get allModelsReady async {
    final statuses = await getModelStatuses();
    return statuses.every((m) => m.isReady);
  }
}

class ModelDownloadException implements Exception {
  final String message;
  const ModelDownloadException(this.message);
  @override
  String toString() => 'ModelDownloadException: $message';
}
