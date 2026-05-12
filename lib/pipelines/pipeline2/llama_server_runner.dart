import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

class LlamaServerRunner {
  LlamaServerRunner._();
  static final LlamaServerRunner instance = LlamaServerRunner._();

  final _log = Logger();
  Process? _serverProcess;
  bool _isRunning = false;
  bool _isReady = false;

  static const _channel = MethodChannel('com.narrator/vlm_plugin');
  static const _serverPort = 8080;

  bool get isRunning => _isRunning;
  bool get isReady => _isReady;

  Future<void> startServer(String modelPath, String mmprojPath) async {
    if (_isRunning) return;
    _isReady = false;

    // ── Step 1: Validate model files ─────────────────────────
    _log.i('[LlamaServer] Validating model files...');
    if (!File(modelPath).existsSync()) {
      _log.e('[LlamaServer] Model NOT found: $modelPath');
      throw Exception('Model file not found: $modelPath');
    }
    _log.i('[LlamaServer] Model OK (${File(modelPath).lengthSync()} bytes): $modelPath');

    if (!File(mmprojPath).existsSync()) {
      _log.e('[LlamaServer] Mmproj NOT found: $mmprojPath');
      throw Exception('Mmproj file not found: $mmprojPath');
    }
    _log.i('[LlamaServer] Mmproj OK (${File(mmprojPath).lengthSync()} bytes): $mmprojPath');

    // ── Step 2: Locate the server binary ─────────────────────
    _log.i('[LlamaServer] Getting nativeLibraryDir...');
    final nativeLibDir = await _channel.invokeMethod<String>('getNativeLibraryDir');
    if (nativeLibDir == null) throw Exception('Could not get nativeLibraryDir');
    _log.i('[LlamaServer] nativeLibDir: $nativeLibDir');

    final srcBinary = '$nativeLibDir/libllama-server.so';
    if (!File(srcBinary).existsSync()) {
      _log.e('[LlamaServer] Binary NOT found: $srcBinary');
      // List what IS in nativeLibDir for diagnostics
      try {
        final dir = Directory(nativeLibDir);
        final files = dir.listSync().map((f) => f.path.split('/').last).join(', ');
        _log.e('[LlamaServer] Files in nativeLibDir: $files');
      } catch (e) { /* ignore */ }
      throw Exception('Server binary not found at $srcBinary');
    }
    _log.i('[LlamaServer] Binary found: $srcBinary');

    // ── Step 3: Copy to filesDir (Android W^X policy) ────────
    final filesDir = (await getApplicationDocumentsDirectory()).path;
    final destBinary = '$filesDir/llama-server';

    final src = File(srcBinary);
    final dst = File(destBinary);
    if (!dst.existsSync() || dst.lengthSync() != src.lengthSync()) {
      _log.i('[LlamaServer] Copying binary to filesDir...');
      await src.copy(destBinary);
      _log.i('[LlamaServer] Copy done.');
    } else {
      _log.i('[LlamaServer] Binary already in filesDir, skipping copy.');
    }

    // ── Step 4: chmod +x ─────────────────────────────────────
    final chmodResult = await Process.run('chmod', ['+x', destBinary]);
    _log.i('[LlamaServer] chmod result: ${chmodResult.exitCode} ${chmodResult.stderr}');

    // ── Step 5: Launch the server ─────────────────────────────
    _log.i('[LlamaServer] Launching server...');
    try {
      _serverProcess = await Process.start(
        destBinary,
        [
          '-m', modelPath,
          '--mmproj', mmprojPath,
          '-c', '512',
          '--port', '$_serverPort',
          '-t', '4',
        ],
        mode: ProcessStartMode.normal,
        environment: {'LD_LIBRARY_PATH': nativeLibDir},
      );
    } catch (e) {
      _log.e('[LlamaServer] Process.start failed: $e');
      rethrow;
    }

    _isRunning = true;
    _log.i('[LlamaServer] Process started (PID ${_serverProcess!.pid})');

    // Log all output
    _serverProcess!.stdout.transform(utf8.decoder).listen((d) => _log.d('[llama-server OUT] $d'));
    _serverProcess!.stderr.transform(utf8.decoder).listen((d) => _log.d('[llama-server ERR] $d'));
    _serverProcess!.exitCode.then((code) {
      _log.w('[LlamaServer] Process exited with code $code');
      _isRunning = false;
      _isReady = false;
      _serverProcess = null;
    });

    // ── Step 6: Poll /health until ready (up to 90s) ─────────
    _log.i('[LlamaServer] Waiting for server to be ready...');
    _isReady = await _waitUntilReady(const Duration(seconds: 90));
    if (_isReady) {
      _log.i('[LlamaServer] ✅ Server is ready on port $_serverPort!');
    } else {
      _log.e('[LlamaServer] ❌ Server did not become ready within 90s');
      stopServer();
    }
  }

  Future<bool> _waitUntilReady(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    int attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final resp = await http
            .get(Uri.parse('http://127.0.0.1:$_serverPort/health'))
            .timeout(const Duration(seconds: 2));
        if (resp.statusCode == 200) return true;
        _log.d('[LlamaServer] /health returned ${resp.statusCode}');
      } catch (_) {
        if (attempt % 5 == 0) _log.d('[LlamaServer] Waiting for server (attempt $attempt)...');
      }
      attempt++;
      await Future.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  void stopServer() {
    _serverProcess?.kill();
    _serverProcess = null;
    _isRunning = false;
    _isReady = false;
    _log.i('[LlamaServer] Stopped.');
  }
}
