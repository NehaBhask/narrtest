import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'app.dart';
import 'core/dpdp_consent.dart';
import 'core/model_manager.dart';
import 'services/tts_service.dart';
import 'services/haptic_service.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  // Enumerate cameras
  try {
    cameras = await availableCameras();
  } catch (_) {}

  // Only initialise lightweight singletons here.
  // Heavy services (ConnectivityService, DpdpConsentManager, SttManager,
  // SileroVad, VlmRunner, WakeWordEngine) are initialised in HomeScreen
  // after permissions are granted and the API key is set.
  await DpdpConsentManager.instance.init();
  await ModelManager.instance.init();
  await TtsService.instance.init();
  await HapticService.instance.init();

  runApp(const NarratorApp());
}
