import 'package:flutter_test/flutter_test.dart';
import 'package:narrator/core/constants.dart';

void main() {
  group('Constants', () {

    group('SupportedLanguages', () {
      test('has exactly 7 languages', () {
        expect(SupportedLanguages.all, hasLength(7));
      });

      test('every language has non-empty code, name, native', () {
        for (final lang in SupportedLanguages.all) {
          expect(lang['code'],   isNotEmpty);
          expect(lang['name'],   isNotEmpty);
          expect(lang['native'], isNotEmpty);
        }
      });

      test('defaultCode is en', () {
        expect(SupportedLanguages.defaultCode, equals('en'));
      });

      test('all listed codes are marked as supported', () {
        for (final lang in SupportedLanguages.all) {
          expect(SupportedLanguages.isSupported(lang['code']!), isTrue,
              reason: '${lang['code']} should be supported');
        }
      });

      test('unsupported code returns false', () {
        expect(SupportedLanguages.isSupported('zz'), isFalse);
        expect(SupportedLanguages.isSupported(''),   isFalse);
      });
    });

    group('DetectionConfig', () {
      test('confidence threshold is within (0,1)', () {
        expect(DetectionConfig.confidenceThreshold, greaterThan(0.0));
        expect(DetectionConfig.confidenceThreshold, lessThan(1.0));
      });

      test('NMS IoU threshold is within (0,1)', () {
        expect(DetectionConfig.nmsIouThreshold, greaterThan(0.0));
        expect(DetectionConfig.nmsIouThreshold, lessThan(1.0));
      });

      test('close obstacle fraction is within (0,1)', () {
        expect(DetectionConfig.closeObstacleFraction, greaterThan(0.0));
        expect(DetectionConfig.closeObstacleFraction, lessThan(1.0));
      });

      test('alert cooldown is positive', () {
        expect(DetectionConfig.alertCooldownMs, greaterThan(0));
      });

      test('YOLO input size is 640', () {
        expect(DetectionConfig.yoloInputSize, equals(640));
      });
    });

    group('VadConfig', () {
      test('sample rate is 16000', () {
        expect(VadConfig.sampleRate, equals(16000));
      });

      test('speech threshold > silence threshold', () {
        expect(VadConfig.speechThreshold, greaterThan(VadConfig.silenceThreshold));
      });

      test('silence timeout is positive', () {
        expect(VadConfig.silenceTimeoutMs, greaterThan(0));
      });
    });

    group('RamThresholds', () {
      test('enhanced VLM threshold is 6000 MB', () {
        expect(RamThresholds.enhancedVlmMinRamMb, equals(6000));
      });
    });

    group('PrivacyConfig', () {
      test('grievance email contains @', () {
        expect(PrivacyConfig.grievanceEmail, contains('@'));
      });

      test('audit log max entries is positive', () {
        expect(PrivacyConfig.auditLogMaxEntries, greaterThan(0));
      });

      test('consent version is non-empty', () {
        expect(PrivacyConfig.consentVersion, isNotEmpty);
      });
    });

    group('ModelUrls', () {
      test('all URLs start with https', () {
        expect(ModelUrls.yoloParam(),     startsWith('https'));
        expect(ModelUrls.yoloBin(),       startsWith('https'));
        expect(ModelUrls.sileroVad(),     startsWith('https'));
        expect(ModelUrls.whisperTiny(),   startsWith('https'));
        expect(ModelUrls.indicTrans2(),   startsWith('https'));
        expect(ModelUrls.smolvlm(),       startsWith('https'));
        expect(ModelUrls.smolvlmMmproj(), startsWith('https'));
      });

      test('URLs contain correct file names', () {
        expect(ModelUrls.yoloParam(),   contains(ModelFiles.yoloParam));
        expect(ModelUrls.sileroVad(),   contains(ModelFiles.sileroVad));
        expect(ModelUrls.whisperTiny(), contains(ModelFiles.whisperTiny));
      });
    });
  });
}
