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
import '../services/haptic_service.dart';
import '../services/tts_service.dart';

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
      await TtsService.instance.speakImmediate('Camera permission is required. Please grant it in Settings.');
      return;
    }

    await LanguageService.instance.init();

    // ── Initialize haptic BEFORE anything else that might vibrate ──────
    // NOTE: HapticService.init() is already called in main.dart before runApp.
    // This second call is intentionally kept as a no-op safety net in case
    // the HomeScreen is ever launched without going through main().
    // Vibration package is idempotent — double-init is safe.
    await HapticService.instance.init();

    setState(() => _statusMsg = 'Opening camera...');
    if (cameras.isEmpty) {
      setState(() => _statusMsg = 'No cameras found!');
      await TtsService.instance.speakImmediate('No camera found on this device.');
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
      SafetyCoordinator.instance.attachController(_controller!);
    } catch (e) {
      setState(() => _statusMsg = 'Camera error: $e');
      await TtsService.instance.speakImmediate('Camera failed to open. Please restart the app.');
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

    // ── STT: API key must come from Settings, never hardcoded ──────────
    // Do NOT hardcode any API key here. The user sets it in Settings screen.
    // SttManager will use offline Whisper if no key is present.
    try {
      await SttManager.instance.init();
    } catch (e) { debugPrint('STT: $e'); }

    try {
      ConversationCoordinator.instance.attachFrameSelector(FrameSelector.instance);
      await ConversationCoordinator.instance.start();
    } catch (e) { debugPrint('P2: $e'); }

    // ── App-ready audio + haptic cue ───────────────────────────────────
    // This is the blind user's confirmation that the app is fully started.
    await HapticService.instance.readyPulse();
    await TtsService.instance.speakImmediate(
      _readyMessage(LanguageService.instance.currentCode),
    );

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

  String _readyMessage(String lang) {
    switch (lang) {
      case 'hi': return 'Narrator तैयार है। कुछ पूछने के लिए Narrator कहें।';
      case 'ta': return 'Narrator தயார். கேட்க Narrator சொல்லுங்கள்.';
      case 'te': return 'Narrator సిద్ధంగా ఉంది. అడగడానికి Narrator చెప్పండి.';
      case 'bn': return 'Narrator প্রস্তুত। জিজ্ঞেস করতে Narrator বলুন।';
      case 'mr': return 'Narrator तयार आहे। विचारण्यासाठी Narrator म्हणा.';
      case 'kn': return 'Narrator ಸಿದ್ಧವಾಗಿದೆ. ಕೇಳಲು Narrator ಹೇಳಿ.';
      default:   return 'Narrator is ready. Say Narrator to ask a question.';
    }
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
              ExcludeSemantics(
                child: Container(width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.white24,
                        borderRadius: BorderRadius.circular(2))),
              ),
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
                  return Semantics(
                    label: '${l['nameEn']} language${sel ? ", selected" : ""}',
                    button: true,
                    child: GestureDetector(
                      onTap: () async {
                        await LanguageService.instance.setLanguage(l['code']!);
                        setBS(() {});
                        setState(() {});
                        Navigator.pop(ctx);
                        // Announce language change via TTS for blind users
                        await TtsService.instance.speakImmediate(
                            'Language changed to ${l['nameEn']}');
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
                        ])),
                    ),
                  );
                }).toList()),
            ]))));
  }

  /// Speaks the current app state when the mic button is long-pressed.
  /// Critical for blind users who cannot read the screen.
  void _announceState() {
    final p2State = ConversationCoordinator.instance.state;
    final lang = LanguageService.instance.currentCode;
    String msg;
    switch (p2State) {
      case Pipeline2State.recording:
        msg = lang == 'hi' ? 'रिकॉर्ड हो रहा है' : 'Recording your question';
        break;
      case Pipeline2State.transcribing:
        msg = lang == 'hi' ? 'आपकी बात समझ रहा हूँ' : 'Transcribing your speech';
        break;
      case Pipeline2State.thinking:
        msg = lang == 'hi' ? 'जवाब सोच रहा हूँ' : 'Thinking of an answer';
        break;
      case Pipeline2State.speaking:
        msg = lang == 'hi' ? 'जवाब बता रहा हूँ' : 'Speaking the answer';
        break;
      case Pipeline2State.awaitingWakeWord:
        msg = lang == 'hi'
            ? 'तैयार हूँ। Narrator कहें।'
            : 'Ready. Say Narrator to ask.';
        break;
      default:
        msg = 'Narrator ready';
    }
    TtsService.instance.speakImmediate(msg);
  }

  @override
  Widget build(BuildContext context) {
    final p2State = ConversationCoordinator.instance.state;
    final isRecording = p2State == Pipeline2State.recording;
    final isSpeaking  = p2State == Pipeline2State.speaking;
    final isBusy      = isSpeaking || p2State == Pipeline2State.thinking ||
        p2State == Pipeline2State.transcribing;
    final currentLang = LanguageService.instance.currentCode.toUpperCase();

    // Mic button semantic label changes with state — screen readers announce this
    final micSemanticLabel = isRecording
        ? 'Stop recording'
        : isBusy
            ? 'Cancel response'
            : 'Tap to speak. Long press to hear app status.';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [

        // ── Camera preview + bounding boxes ────────────────────
        if (_cameraReady && _controller != null)
          ExcludeSemantics(
            // Camera preview is purely visual — exclude from accessibility tree
            child: Center(
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
            ),
          )
        else
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black,
              child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(color: Color(0xFF6C63FF)),
                const Gap(16),
                Semantics(
                  liveRegion: true,
                  child: Text(_statusMsg,
                      style: const TextStyle(color: Colors.white, fontSize: 15)),
                ),
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
                ExcludeSemantics(
                  child: Container(
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
                ),
                const Spacer(),
                Semantics(
                  label: 'Change language. Current: $currentLang',
                  button: true,
                  child: GestureDetector(
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
                ),
                const Gap(8),
                Semantics(
                  label: 'Settings',
                  button: true,
                  child: GestureDetector(
                    onTap: () => Navigator.pushNamed(context, '/settings'),
                    child: Container(
                      width: 38, height: 38,
                      decoration: const BoxDecoration(
                          color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.settings_outlined,
                          color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),

        // ── Pipeline status badge (visual only — excluded from a11y) ────
        // Positioned MUST be a direct Stack child — ExcludeSemantics wraps
        // the inner Container, not the Positioned itself.
        if (_cameraReady)
          Positioned(
            top: 80, left: 16,
            child: ExcludeSemantics(
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
          ),

        // ── Transcript + response ────────────────────────────────
        if (_transcript.isNotEmpty || _response.isNotEmpty)
          Positioned(
            bottom: 145, left: 16, right: 16,
            child: Semantics(
              liveRegion: true, // screen reader announces when content changes
              label: [
                if (_transcript.isNotEmpty) 'You said: $_transcript',
                if (_response.isNotEmpty) 'Answer: $_response',
              ].join('. '),
              child: Container(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.35),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: Colors.black87, borderRadius: BorderRadius.circular(14)),
                child: SingleChildScrollView(
                  reverse: true,
                  // ExcludeSemantics: the parent Semantics node already provides
                  // the full text via its label. Merging Expanded descendants
                  // into the accessibility tree causes ParentDataWidget assertions.
                  child: ExcludeSemantics(
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
            ),
          ),

        // ── Mic button ───────────────────────────────────────────
        Positioned(
          bottom: 40, left: 0, right: 0,
          child: Center(
            child: Column(children: [
              Semantics(
                label: micSemanticLabel,
                button: true,
                child: GestureDetector(
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
                  // Long-press: speak current state for blind users
                  onLongPress: _announceState,
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
                              : const Color(0xFF6C63FF)).withValues(alpha: 0.5),
                          blurRadius: 24, spreadRadius: 4)]),
                    child: Icon(
                      isRecording ? Icons.stop_rounded
                          : isBusy ? Icons.cancel_rounded
                          : Icons.mic_rounded,
                      color: Colors.white, size: 34),
                  ),
                ),
              ),
              const Gap(8),
              ExcludeSemantics(
                child: Text(
                  isRecording ? 'Tap to stop'
                      : p2State == Pipeline2State.transcribing ? 'Transcribing...'
                      : p2State == Pipeline2State.thinking ? 'Thinking...'
                      : p2State == Pipeline2State.speaking ? 'Speaking...'
                      : 'Tap or say Narrator',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ]),
          ),
        ),

      ]),
    );
  }
}

// ── Bounding box painter ──────────────────────────────────────────────────────
class _BboxPainter extends CustomPainter {
  final List<YoloDetection> detections;
  _BboxPainter(this.detections);

  static const double _minArea = 0.06; // matches obstacleAreaThreshold
  static const int _maxBoxes = 4;

  static const _colors = [
    Color(0xFFFF5252), Color(0xFF00E676), Color(0xFF40C4FF),
    Color(0xFFFFD740), Color(0xFFE040FB), Color(0xFF00BCD4),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5;
    final bgPaint  = Paint()..style = PaintingStyle.fill;

    final drawable = detections
        .where((d) => d.area >= _minArea)
        .take(_maxBoxes)
        .toList();

    for (final det in drawable) {
      final isClose = det.area >= AppConstants.obstacleAreaThreshold &&
          det.centerX >= AppConstants.obstacleMinCenterX &&
          det.centerX <= AppConstants.obstacleMaxCenterX &&
          det.centerY >= AppConstants.obstacleMinCenterY &&
          AppConstants.navigationRelevantClassIds.contains(det.classId);

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

      final prefix = isClose ? '⚠ ' : '';
      final label  = '$prefix${det.className} ${(det.confidence * 100).toInt()}%';

      final tp = TextPainter(
        text: TextSpan(
          text: ' $label ',
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();

      bgPaint.color = color.withValues(alpha: 0.80);
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
