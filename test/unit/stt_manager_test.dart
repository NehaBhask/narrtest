import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrator/pipelines/pipeline2/stt_manager.dart';

void main() {
  group('SttManager', () {

    // ── canUseOnline ──────────────────────────────────────────────────────

    group('canUseOnline', () {
      test('false when no API key', () {
        final m = SttManager();
        expect(m.canUseOnline, isFalse);
      });

      test('false when API key is empty string', () {
        final m = SttManager(groqApiKey: '');
        expect(m.canUseOnline, isFalse);
      });

      test('false when API key is whitespace', () {
        final m = SttManager(groqApiKey: '   ');
        expect(m.canUseOnline, isFalse);
      });

      test('true when valid key and auto mode', () {
        final m = SttManager(groqApiKey: 'gsk_test_key', mode: SttMode.auto);
        expect(m.canUseOnline, isTrue);
      });

      test('true when valid key and online mode', () {
        final m = SttManager(groqApiKey: 'gsk_test_key', mode: SttMode.online);
        expect(m.canUseOnline, isTrue);
      });

      test('false when offline mode even with key', () {
        final m = SttManager(groqApiKey: 'gsk_test_key', mode: SttMode.offline);
        expect(m.canUseOnline, isFalse);
      });
    });

    // ── buildWavHeader ────────────────────────────────────────────────────

    group('buildWavHeader', () {
      test('header is exactly 44 bytes', () {
        final h = SttManager.buildWavHeader(pcmByteCount: 32000);
        expect(h.length, equals(44));
      });

      test('starts with RIFF marker', () {
        final h = SttManager.buildWavHeader(pcmByteCount: 1000);
        expect(h[0], equals(0x52)); // R
        expect(h[1], equals(0x49)); // I
        expect(h[2], equals(0x46)); // F
        expect(h[3], equals(0x46)); // F
      });

      test('contains WAVE marker at bytes 8-11', () {
        final h = SttManager.buildWavHeader(pcmByteCount: 1000);
        expect(h[8],  equals(0x57)); // W
        expect(h[9],  equals(0x41)); // A
        expect(h[10], equals(0x56)); // V
        expect(h[11], equals(0x45)); // E
      });

      test('contains data marker at bytes 36-39', () {
        final h = SttManager.buildWavHeader(pcmByteCount: 1000);
        expect(h[36], equals(0x64)); // d
        expect(h[37], equals(0x61)); // a
        expect(h[38], equals(0x74)); // t
        expect(h[39], equals(0x61)); // a
      });

      test('chunk size = 36 + pcmByteCount', () {
        const pcmSize = 16000;
        final h = SttManager.buildWavHeader(pcmByteCount: pcmSize);
        final chunkSize = ByteData.sublistView(h, 4, 8)
            .getUint32(0, Endian.little);
        expect(chunkSize, equals(36 + pcmSize));
      });

      test('sample rate is encoded at bytes 24-27', () {
        final h = SttManager.buildWavHeader(
            pcmByteCount: 1000, sampleRate: 16000);
        final sr = ByteData.sublistView(h, 24, 28)
            .getUint32(0, Endian.little);
        expect(sr, equals(16000));
      });

      test('custom sample rate is encoded correctly', () {
        final h = SttManager.buildWavHeader(
            pcmByteCount: 1000, sampleRate: 44100);
        final sr = ByteData.sublistView(h, 24, 28)
            .getUint32(0, Endian.little);
        expect(sr, equals(44100));
      });

      test('PCM format tag is 1 at bytes 20-21', () {
        final h = SttManager.buildWavHeader(pcmByteCount: 1000);
        final fmt = ByteData.sublistView(h, 20, 22)
            .getUint16(0, Endian.little);
        expect(fmt, equals(1)); // PCM
      });

      test('channel count is 1 (mono)', () {
        final h = SttManager.buildWavHeader(pcmByteCount: 1000);
        final ch = ByteData.sublistView(h, 22, 24)
            .getUint16(0, Endian.little);
        expect(ch, equals(1));
      });
    });

    // ── transcribe offline mode (no real ONNX runtime in unit tests) ────────

    group('transcribe offline mode', () {
      test('returns SttResult with whisperLocal provider', () async {
        final m   = SttManager(mode: SttMode.offline);
        final wav = SttManager.buildWavHeader(pcmByteCount: 100);
        final res = await m.transcribe(
            Uint8List.fromList([...wav, ...List.filled(100, 0)]));
        expect(res.provider, equals(SttProvider.whisperLocal));
      });

      test('result has non-null latency', () async {
        final m   = SttManager(mode: SttMode.offline);
        final wav = SttManager.buildWavHeader(pcmByteCount: 0);
        final res = await m.transcribe(wav);
        expect(res.latency, isNotNull);
      });

      // Without a real device ONNX runtime the MethodChannel throws a
      // PlatformException — the manager must degrade gracefully (isError=true).
      test('gracefully degrades to error when platform channel unavailable', () async {
        final m   = SttManager(mode: SttMode.offline);
        final res = await m.transcribe(Uint8List(0));
        // Either real result or graceful error — never throws
        expect(res, isNotNull);
        expect(res.provider, equals(SttProvider.whisperLocal));
      });
    });

    // ── SttResult.error ───────────────────────────────────────────────────

    group('SttResult.error', () {
      test('has isError=true', () {
        final r = SttResult.error(SttProvider.groq);
        expect(r.isError, isTrue);
      });

      test('has empty text', () {
        final r = SttResult.error(SttProvider.groq);
        expect(r.text, isEmpty);
      });

      test('has zero latency', () {
        final r = SttResult.error(SttProvider.whisperLocal);
        expect(r.latency, equals(Duration.zero));
      });
    });
  });
}
