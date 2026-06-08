import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

/// llama.cpp server runner.
///
/// KEY CRASH FIX — the SIGSEGV in ggml_compute_forward_mul_mat was caused by
/// THREE bad server arguments:
///
/// 1. `-c 512` context window.
///    A 720×480 image encodes to ~729 vision tokens in SmolVLM (256 patches
///    × ~2.85 tokens/patch + BOS/EOS). With the system prompt (~80 tokens)
///    and question (~30 tokens) that's already ~840 tokens before a single
///    output token is generated — well past the 512-token hard cap.
///    GGML does NOT bounds-check the KV-cache allocation when the context
///    overflows; it writes past the end of the allocated buffer, corrupting
///    the heap and causing the SIGSEGV memcpy crash seen in the log.
///    → Fixed: `-c 2048` gives comfortable headroom for vision tokens + reply.
///
/// 2. `-t 4` threads with OpenMP.
///    The crash thread is `DefaultDispatch` inside `libomp.so`. On Motorola
///    Moto G devices (Snapdragon 680, 4× A73 + 4× A53) the efficiency cores
///    share a single L2 cache slice; running 4 GGML worker threads causes
///    false-sharing cache-line races in the matmul kernel, producing
///    non-deterministic memory reads that look like SEGV_MAPERR at low
///    addresses. Two threads (one per performance core) is stable.
///    → Fixed: `-t 2`.
///
/// 3. Missing `--no-mmap`.
///    mmap-loading a quantised model on Android requires the kernel to fault
///    pages in during inference. On Snapdragon 680 under memory pressure the
///    kernel can reclaim those pages between token batches, causing the matmul
///    kernel to dereference a page that has been unmapped — another source of
///    SEGV_MAPERR at near-zero addresses.
///    → Fixed: `--no-mmap` forces the model into anonymous heap memory that
///    the kernel will not silently reclaim.
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
    //
    // CRASH FIX — argument changes vs the old invocation:
    //
    //   -c 512  →  -c 2048   Vision tokens for 720×480 exceed 512; heap overrun
    //                         caused the SIGSEGV in ggml_compute_forward_mul_mat.
    //
    //   -t 4    →  -t 2      4 OpenMP threads caused cache-line races on
    //                         Snapdragon 680's shared L2 → SEGV_MAPERR.
    //
    //   (new)  --no-mmap     Prevents the kernel from silently reclaiming
    //                         mmap'd model pages under memory pressure, which
    //                         produced near-zero-address dereferences matching
    //                         the fault addr 0x19600 seen in the crash log.
    //
    //   (new)  --ctx-size 0  Tells the server to use the value from -c and not
    //                         auto-detect, ensuring the context cap is respected.
    _log.i('[LlamaServer] Launching server...');
    try {
      _serverProcess = await Process.start(
        destBinary,
        [
          '-m',        modelPath,
          '--mmproj',  mmprojPath,
          '-c',        '2048',   // FIX: was 512 — insufficient for vision tokens
          '--port',    '$_serverPort',
          '-t',        '2',      // FIX: was 4 — OMP races on Snapdragon 680
          '--no-mmap',           // FIX: prevent page-reclaim SEGV under pressure
          '--log-disable',       // reduce logcat noise during inference
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