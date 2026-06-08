import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:logger/logger.dart';
import 'constants.dart';

enum ModelStatus { notDownloaded, downloading, ready, corrupted }

class ModelInfo {
  final String name;
  final String fileName;
  final String url;
  final int estimatedSizeMb;
  final String description;
  ModelStatus status;
  double progress; // 0.0 – 1.0

  ModelInfo({
    required this.name,
    required this.fileName,
    required this.url,
    required this.estimatedSizeMb,
    required this.description,
    this.status = ModelStatus.notDownloaded,
    this.progress = 0.0,
  });
}

/// Manages download, integrity verification, and lifecycle of AI model files.
class ModelManager {
  ModelManager._();
  static final ModelManager instance = ModelManager._();

  final _log = Logger();
  final _dio = Dio();
  late Directory _modelDir;

  // Callbacks for UI updates
  void Function(String fileName, double progress)? onProgress;
  void Function(String fileName, ModelStatus status)? onStatusChanged;

  final List<ModelInfo> models = [
    ModelInfo(
      name: 'YOLOv8-nano (Param)',
      fileName: AppConstants.yolov8nParamFile,
      url: AppConstants.yolov8nParamUrl,
      estimatedSizeMb: 1,
      description: 'Object detection network config',
    ),
    ModelInfo(
      name: 'YOLOv8-nano (Weights)',
      fileName: AppConstants.yolov8nBinFile,
      url: AppConstants.yolov8nBinUrl,
      estimatedSizeMb: 6,
      description: 'Obstacle detection weights',
    ),
    ModelInfo(
      name: 'Silero VAD',
      fileName: AppConstants.sileroVadFile,
      url: AppConstants.sileroVadOnnxUrl,
      estimatedSizeMb: 2,
      description: 'Voice activity detection',
    ),
    ModelInfo(
      name: 'Whisper-tiny Multilingual',
      fileName: AppConstants.whisperTinyFile,
      url: AppConstants.whisperTinyOnnxUrl,
      estimatedSizeMb: 75,
      description: 'Offline speech-to-text (all Indian languages)',
    ),
    ModelInfo(
      name: 'IndicTrans2 INT8',
      fileName: AppConstants.indicTrans2File,
      url: AppConstants.indicTrans2OnnxUrl,
      estimatedSizeMb: 280,
      description: 'Indian language → English translation',
    ),
    ModelInfo(
      name: 'SmolVLM-256M (Language)',
      fileName: AppConstants.smolvlmModelFile,
      url: AppConstants.smolvlmModelUrl,
      estimatedSizeMb: 200,
      description: 'Language model weights for VLM',
    ),
    ModelInfo(
      name: 'SmolVLM-256M (Vision)',
      fileName: AppConstants.smolvlmMmprojFile,
      url: AppConstants.smolvlmMmprojUrl,
      estimatedSizeMb: 148,
      description: 'Vision projector for VLM',
    ),
  ];

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _modelDir = Directory('${appDir.path}/${AppConstants.modelDirName}');
    if (!await _modelDir.exists()) {
      await _modelDir.create(recursive: true);
    }
    await _copyBundledModels();
    await _refreshStatuses();
  }

  /// Copies core models bundled in the APK assets to the writable model dir.
  /// Only copies if the destination file doesn't already exist.
  Future<void> _copyBundledModels() async {
    final bundled = {
      AppConstants.yolov8nParamFile: AppConstants.yolov8nParamAsset,
      AppConstants.yolov8nBinFile:   AppConstants.yolov8nBinAsset,
      AppConstants.sileroVadFile:    AppConstants.sileroVadAsset,
    };
    for (final entry in bundled.entries) {
      final dest = File('${_modelDir.path}/${entry.key}');
      if (!await dest.exists()) {
        try {
          final data = await rootBundle.load(entry.value);
          await dest.writeAsBytes(data.buffer.asUint8List(), flush: true);
          _log.i('Copied bundled model: ${entry.key}');
        } catch (e) {
          _log.w('Could not copy bundled model ${entry.key}: $e');
        }
      }
    }
  }

  Future<void> _refreshStatuses() async {
    for (final model in models) {
      final file = File('${_modelDir.path}/${model.fileName}');
      if (await file.exists()) {
        model.status = ModelStatus.ready;
        model.progress = 1.0;
      } else {
        model.status = ModelStatus.notDownloaded;
        model.progress = 0.0;
      }
    }
  }

  String modelPath(String fileName) => '${_modelDir.path}/$fileName';

  bool isReady(String fileName) {
    return models
        .where((m) => m.fileName == fileName)
        .any((m) => m.status == ModelStatus.ready);
  }

  bool get coreModelsReady =>
      isReady(AppConstants.yolov8nParamFile) &&
      isReady(AppConstants.yolov8nBinFile) &&
      isReady(AppConstants.sileroVadFile);

  bool get pipeline2Ready =>
      coreModelsReady &&
      isReady(AppConstants.whisperTinyFile) &&
      isReady(AppConstants.smolvlmModelFile) &&
      isReady(AppConstants.smolvlmMmprojFile);

  Future<bool> downloadModel(ModelInfo model) async {
    final destFile = File('${_modelDir.path}/${model.fileName}');
    final tempFile = File('${_modelDir.path}/${model.fileName}.tmp');

    model.status = ModelStatus.downloading;
    model.progress = 0.0;
    onStatusChanged?.call(model.fileName, model.status);

    try {
      await _dio.download(
        model.url,
        tempFile.path,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            model.progress = received / total;
            onProgress?.call(model.fileName, model.progress);
          }
        },
        options: Options(receiveTimeout: const Duration(minutes: 30)),
      );

      // Move temp → final
      await tempFile.rename(destFile.path);

      model.status = ModelStatus.ready;
      model.progress = 1.0;
      onStatusChanged?.call(model.fileName, model.status);
      _log.i('Downloaded ${model.fileName}');
      return true;
    } catch (e) {
      _log.e('Failed to download ${model.fileName}: $e');
      if (await tempFile.exists()) await tempFile.delete();
      model.status = ModelStatus.notDownloaded;
      model.progress = 0.0;
      onStatusChanged?.call(model.fileName, model.status);
      return false;
    }
  }

  Future<void> downloadAll() async {
    for (final model in models) {
      if (model.status != ModelStatus.ready) {
        await downloadModel(model);
      }
    }
  }

  Future<bool> verifyIntegrity(String fileName) async {
    final expectedHash = AppConstants.modelHashes[fileName];
    if (expectedHash == null || expectedHash.startsWith('placeholder')) {
      return true; // skip verification for placeholder hashes
    }
    final file = File(modelPath(fileName));
    if (!await file.exists()) return false;
    final bytes = await file.readAsBytes();
    final hash = sha256.convert(bytes).toString();
    return hash == expectedHash;
  }

  Future<void> deleteAll() async {
    for (final file in _modelDir.listSync()) {
      await file.delete();
    }
    await _refreshStatuses();
  }

  int get totalDownloadedMb {
    return models
        .where((m) => m.status == ModelStatus.ready)
        .fold(0, (sum, m) => sum + m.estimatedSizeMb);
  }

  int get totalRequiredMb {
    return models.fold(0, (sum, m) => sum + m.estimatedSizeMb);
  }
}
