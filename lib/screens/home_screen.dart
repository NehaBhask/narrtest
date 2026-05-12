import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gap/gap.dart';
import '../main.dart';
import '../core/constants.dart';
import '../pipelines/pipeline2/conversation_coordinator.dart';
import '../pipelines/pipeline2/silero_vad.dart';
import '../pipelines/pipeline2/translation_engine.dart';
import '../pipelines/pipeline2/vlm_runner.dart';
import '../pipelines/pipeline1/safety_coordinator.dart';
import '../pipelines/pipeline1/yolo_ncnn_runner.dart';
import '../pipelines/pipeline2/frame_selector.dart';
import '../pipelines/pipeline2/stt_manager.dart';
import '../services/language_service.dart';
import '../services/connectivity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _cameraReady = false;
  String _statusMsg = 'Starting...';

  StreamSubscription? _p2StateSub;
  StreamSubscription? _transcriptSub;
  StreamSubscription? _responseSub;
  StreamSubscription? _detectionsSub;
  String _transcript = '';
  String _response = '';
  List<YoloDetection> _detections = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) SafetyCoordinator.instance.pause();
    if (state == AppLifecycleState.resumed) SafetyCoordinator.instance.resume();
  }

  Future<void> _init() async {
    setState(() => _statusMsg = 'Requesting permissions...');
    final camStatus = await Permission.camera.request();
    await Permission.microphone.request();
    if (!camStatus.isGranted) {
      setState(() => _statusMsg = 'Camera permission denied!');
      return;
    }

    await LanguageService.instance.init();

    setState(() => _statusMsg = 'Opening camera...');
    if (cameras.isEmpty) {
      setState(() => _statusMsg = 'No cameras found!');
      return;
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _controller = CameraController(back, ResolutionPreset.medium, enableAudio: false);
    try {
      await _controller!.initialize();
      setState(() { _cameraReady = true; _statusMsg = ''; });
      FrameSelector.instance.attachController(_controller!);
      // CRITICAL: give P1 the controller so takePicture() works
      SafetyCoordinator.instance.attachController(_controller!);
    } catch (e) {
      setState(() => _statusMsg = 'Camera error: $e');
      return;
    }

    try { await SafetyCoordinator.instance.start(); } catch (e) { debugPrint('P1: $e'); }
    try { await SileroVad.instance.init(); } catch (e) { debugPrint('VAD: $e'); }
    try {
      await VlmRunner.instance.init();
      await VlmRunner.instance.loadModel();
    } catch (e) { debugPrint('VLM: $e'); }
    try { await TranslationEngine.instance.init(); } catch (e) { debugPrint('Translation: $e'); }
    try { await ConnectivityService.instance.init(); } catch (e) { debugPrint('Connectivity: $e'); }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('groq_api_key', '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');
      await SttManager.instance.init();
    } catch (e) { debugPrint('STT: $e'); }

    try {
      ConversationCoordinator.instance.attachFrameSelector(FrameSelector.instance);
      await ConversationCoordinator.instance.start();
    } catch (e) { debugPrint('P2: $e'); }

    _detectionsSub = SafetyCoordinator.instance.detectionsStream.listen((dets) {
      if (mounted) setState(() => _detections = dets);
    });
    _p2StateSub = ConversationCoordinator.instance.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _transcriptSub = ConversationCoordinator.instance.transcriptStream.listen((t) {
      if (mounted) setState(() { _transcript = t; _response = ''; });
    });
    _responseSub = ConversationCoordinator.instance.responseStream.listen((s) {
      if (mounted) setState(() { if (s.isNotEmpty) _response = s; else _response = ''; });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FrameSelector.instance.dispose();
    _controller?.dispose();
    _detectionsSub?.cancel();
    _p2StateSub?.cancel();
    _transcriptSub?.cancel();
    _responseSub?.cancel();
    SafetyCoordinator.instance.stop();
    ConversationCoordinator.instance.stop();
    super.dispose();
  }

  void _showLanguagePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(
          builder: (ctx, setBS) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.white24,
                      borderRadius: BorderRadius.circular(2))),
              const Gap(16),
              const Text('Select Language', style: TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const Gap(4),
              const Text('Transcript and speech will use this language',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              const Gap(20),
              Wrap(
                spacing: 10, runSpacing: 10,
                children: AppConstants.supportedLanguages.map((l) {
                  final sel = l['code'] == LanguageService.instance.currentCode;
                  return GestureDetector(
                    onTap: () async {
                      await LanguageService.instance.setLanguage(l['code']!);
                      setBS(() {});
                      setState(() {});
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Language → ${l['nameEn']}'),
                          backgroundColor: const Color(0xFF6C63FF),
                          duration: const Duration(seconds: 1)));
                    },
                    child: Container(
                      width: (MediaQuery.of(context).size.width - 60) / 2,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                          color: sel ? const Color(0xFF6C63FF) : Colors.white10,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: sel ? const Color(0xFF6C63FF) : Colors.white24)),
                      child: Column(children: [
                        Text(l['name']!, style: TextStyle(
                            color: sel ? Colors.white : Colors.white70,
                            fontSize: 20,
                            fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
                        const Gap(2),
                        Text(l['nameEn']!, style: TextStyle(
                            color: sel ? Colors.white70 : Colors.white38,
                            fontSize: 12)),
                      ])));
                }).toList()),
            ]))));
  }

  @override
  Widget build(BuildContext context) {
    final p2State = ConversationCoordinator.instance.state;
    final isRecording = p2State == Pipeline2State.recording;
    final isSpeaking  = p2State == Pipeline2State.speaking;
    final isBusy      = isSpeaking || p2State == Pipeline2State.thinking ||
        p2State == Pipeline2State.transcribing;
    final currentLang = LanguageService.instance.currentCode.toUpperCase();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [

        // ── Camera preview + bounding boxes ────────────────────
        if (_cameraReady && _controller != null)
          Center(
            child: AspectRatio(
              aspectRatio: 1 / _controller!.value.aspectRatio,
              child: Stack(children: [
                CameraPreview(_controller!),
                if (_detections.isNotEmpty)
                  Positioned.fill(
                    child: CustomPaint(painter: _BboxPainter(_detections)),
                  ),
              ]),
            ),
          )
        else
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black,
              child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(color: Color(0xFF6C63FF)),
                const Gap(16),
                Text(_statusMsg, style: const TextStyle(color: Colors.white, fontSize: 15)),
              ])),
            ),
          ),

        // ── Top bar ─────────────────────────────────────────────
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: Colors.black54,
                      borderRadius: BorderRadius.circular(20)),
                  child: const Row(children: [
                    Icon(Icons.visibility, color: Color(0xFF6C63FF), size: 18),
                    Gap(6),
                    Text('Narrator', style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  ]),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _showLanguagePicker,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: const Color(0xFF6C63FF),
                        borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.language, color: Colors.white, size: 14),
                      const Gap(5),
                      Text(currentLang, style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                    ]),
                  ),
                ),
                const Gap(8),
                GestureDetector(
                  onTap: () => Navigator.pushNamed(context, '/settings'),
                  child: Container(
                    width: 38, height: 38,
                    decoration: const BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.settings_outlined, color: Colors.white, size: 20),
                  ),
                ),
              ]),
            ),
          ),
        ),

        // ── Pipeline status badge ────────────────────────────────
        if (_cameraReady)
          Positioned(
            top: 80, left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: Colors.black54, borderRadius: BorderRadius.circular(10)),
              child: Text(
                'P1: ${SafetyCoordinator.instance.state.name}  •  P2: ${p2State.name}'
                    '${_detections.isNotEmpty ? "  •  ${_detections.length} obj" : ""}',
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ),
          ),

        // ── Transcript + response ────────────────────────────────
        if (_transcript.isNotEmpty || _response.isNotEmpty)
          Positioned(
            bottom: 145, left: 16, right: 16,
            child: Container(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.35),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: Colors.black87, borderRadius: BorderRadius.circular(14)),
              child: SingleChildScrollView(
                reverse: true,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_transcript.isNotEmpty)
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('You  ', style: TextStyle(
                          color: Color(0xFF6C63FF),
                          fontWeight: FontWeight.bold, fontSize: 12)),
                      Expanded(child: Text(_transcript,
                          style: const TextStyle(color: Colors.white70, fontSize: 13))),
                    ]),
                  if (_response.isNotEmpty) ...[
                    const Gap(8),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('AI   ', style: TextStyle(
                          color: Color(0xFF00D4AA),
                          fontWeight: FontWeight.bold, fontSize: 12)),
                      Expanded(child: Text(_response,
                          style: const TextStyle(color: Colors.white, fontSize: 14))),
                    ]),
                  ],
                ]),
              ),
            ),
          ),

        // ── Mic button ───────────────────────────────────────────
        Positioned(
          bottom: 40, left: 0, right: 0,
          child: Center(
            child: Column(children: [
              GestureDetector(
                onTap: () {
                  if (isRecording) {
                    ConversationCoordinator.instance.stopManually();
                  } else if (isBusy) {
                    ConversationCoordinator.instance.cancelResponse();
                  } else {
                    setState(() { _transcript = ''; _response = ''; });
                    ConversationCoordinator.instance.triggerManually();
                  }
                },
                child: Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isRecording ? Colors.red
                        : isBusy ? Colors.orange
                        : const Color(0xFF6C63FF),
                    boxShadow: [BoxShadow(
                        color: (isRecording ? Colors.red
                            : isBusy ? Colors.orange
                            : const Color(0xFF6C63FF)).withOpacity(0.5),
                        blurRadius: 24, spreadRadius: 4)]),
                  child: Icon(
                    isRecording ? Icons.stop_rounded
                        : isBusy ? Icons.cancel_rounded
                        : Icons.mic_rounded,
                    color: Colors.white, size: 34),
                ),
              ),
              const Gap(8),
              Text(
                isRecording ? 'Tap to stop'
                    : p2State == Pipeline2State.transcribing ? 'Transcribing...'
                    : p2State == Pipeline2State.thinking ? 'Thinking...'
                    : p2State == Pipeline2State.speaking ? 'Speaking...'
                    : 'Tap to speak',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
        ),

      ]),
    );
  }
}

// ── Bounding box painter ──────────────────────────────────────────────────────
// Only draws detections that pass a minimum area threshold (5% of frame)
// to suppress tiny ghost boxes, and shows real class names instead of cls0/1/2.
class _BboxPainter extends CustomPainter {
  final List<YoloDetection> detections;
  _BboxPainter(this.detections);

  // Only draw boxes that are at least 10% of frame area.
  // Anything smaller is not visible enough to be useful on screen.
  static const double _minArea = 0.10;

  // Never draw more than this many boxes regardless of detections.
  static const int _maxBoxes = 4;

  // One stable color per COCO class (cycles through 6)
  static const _colors = [
    Color(0xFFFF5252), Color(0xFF00E676), Color(0xFF40C4FF),
    Color(0xFFFFD740), Color(0xFFE040FB), Color(0xFF00BCD4),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5;
    final bgPaint  = Paint()..style = PaintingStyle.fill;

    // detections are already sorted by confidence desc from _parseResult.
    // Filter to drawable boxes first, then cap at _maxBoxes.
    final drawable = detections
        .where((d) => d.area >= _minArea)
        .take(_maxBoxes)
        .toList();

    for (final det in drawable) {
      // Close obstacles glow red — must match ObstacleDetector._isInPath logic
      final isClose = det.area >= AppConstants.obstacleAreaThreshold &&
          det.centerX >= AppConstants.obstacleMinCenterX &&
          det.centerX <= AppConstants.obstacleMaxCenterX &&
          det.centerY >= AppConstants.obstacleMinCenterY;
      final color = isClose
          ? const Color(0xFFFF5252)
          : _colors[det.classId % _colors.length];

      boxPaint
        ..color = color
        ..strokeWidth = isClose ? 3.0 : 2.0;

      final rect = Rect.fromLTRB(
        det.x1 * size.width,  det.y1 * size.height,
        det.x2 * size.width,  det.y2 * size.height,
      );
      canvas.drawRect(rect, boxPaint);

      // Real class name (e.g. "person", "chair") + confidence
      final prefix = isClose ? '⚠ ' : '';
      final label  = '$prefix${det.className} ${(det.confidence * 100).toInt()}%';

      final tp = TextPainter(
        text: TextSpan(
          text: ' $label ',
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();

      bgPaint.color = color.withOpacity(0.80);
      final labelTop = (rect.top - tp.height - 2).clamp(0.0, size.height - tp.height);
      canvas.drawRect(
          Rect.fromLTWH(rect.left, labelTop, tp.width, tp.height + 2),
          bgPaint);
      tp.paint(canvas, Offset(rect.left, labelTop));
    }
  }

  @override
  bool shouldRepaint(_BboxPainter old) => old.detections != detections;
}
