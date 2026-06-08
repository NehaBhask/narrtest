import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:narrator/core/dpdp_consent.dart';
import 'package:narrator/core/constants.dart';

void main() {
  group('DpdpConsentManager', () {
    late DpdpConsentManager manager;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      manager = DpdpConsentManager(prefs);
    });

    // ── Initial state ────────────────────────────────────────────────────────

    group('initial state', () {
      test('no consent given on fresh install', () {
        expect(manager.isConsentValid, isFalse);
      });

      test('getConsent returns default ConsentState', () {
        final c = manager.getConsent();
        expect(c.baseConsentGiven,   isFalse);
        expect(c.onlineSttConsented, isFalse);
        expect(c.analyticsConsented, isFalse);
        expect(c.isAdult,            isFalse);
        expect(c.consentTimestamp,   isNull);
      });

      test('audit log is empty on fresh install', () {
        expect(manager.getAuditLog(), isEmpty);
      });
    });

    // ── grantConsent ─────────────────────────────────────────────────────────

    group('grantConsent', () {
      test('consent is valid after granting with adult=true', () async {
        await manager.grantConsent(
          onlineStt: true, analytics: false, isAdult: true);
        expect(manager.isConsentValid, isTrue);
      });

      test('consent is NOT valid when isAdult=false', () async {
        await manager.grantConsent(
          onlineStt: false, analytics: false, isAdult: false);
        expect(manager.isConsentValid, isFalse);
      });

      test('online STT consent is persisted correctly', () async {
        await manager.grantConsent(
          onlineStt: true, analytics: false, isAdult: true);
        expect(manager.getConsent().onlineSttConsented, isTrue);
      });

      test('analytics consent is persisted correctly', () async {
        await manager.grantConsent(
          onlineStt: false, analytics: true, isAdult: true);
        expect(manager.getConsent().analyticsConsented, isTrue);
      });

      test('consentTimestamp is set after granting', () async {
        final before = DateTime.now();
        await manager.grantConsent(
          onlineStt: false, analytics: false, isAdult: true);
        final ts = manager.getConsent().consentTimestamp;
        expect(ts, isNotNull);
        expect(ts!.isAfter(before.subtract(const Duration(seconds: 1))),
            isTrue);
      });

      test('consentVersion matches current version', () async {
        await manager.grantConsent(
          onlineStt: false, analytics: false, isAdult: true);
        expect(manager.getConsent().consentVersion,
            equals(PrivacyConfig.consentVersion));
      });
    });

    // ── revokeConsent ────────────────────────────────────────────────────────

    group('revokeConsent', () {
      test('consent is invalid after revocation', () async {
        await manager.grantConsent(
          onlineStt: true, analytics: true, isAdult: true);
        expect(manager.isConsentValid, isTrue);

        await manager.revokeConsent();
        expect(manager.isConsentValid, isFalse);
      });

      test('audit log is cleared after revocation', () async {
        await manager.grantConsent(
          onlineStt: false, analytics: false, isAdult: true);
        await manager.logEvent(ProcessingEvent.cameraVlmInference, 'test');
        expect(manager.getAuditLog(), isNotEmpty);

        await manager.revokeConsent();
        expect(manager.getAuditLog(), isEmpty);
      });

      test('revoke on fresh install does not throw', () async {
        expect(() async => manager.revokeConsent(), returnsNormally);
      });
    });

    // ── audit log ────────────────────────────────────────────────────────────

    group('audit log', () {
      test('logEvent adds an entry', () async {
        await manager.logEvent(
            ProcessingEvent.cameraObstacleDetection, 'frame_123');
        expect(manager.getAuditLog(), hasLength(1));
      });

      test('log entry has correct event type', () async {
        await manager.logEvent(ProcessingEvent.audioStt, 'query_1');
        final entry = manager.getAuditLog().first;
        expect(entry.event, equals(ProcessingEvent.audioStt));
      });

      test('log entry detail is persisted', () async {
        await manager.logEvent(ProcessingEvent.ttsOutput, 'hello world');
        expect(manager.getAuditLog().first.detail, equals('hello world'));
      });

      test('multiple events are logged in order', () async {
        await manager.logEvent(ProcessingEvent.audioWakeWord,  'suno');
        await manager.logEvent(ProcessingEvent.audioStt,       'transcript');
        await manager.logEvent(ProcessingEvent.ttsOutput,      'response');
        final log = manager.getAuditLog();
        expect(log, hasLength(3));
        expect(log[0].event, equals(ProcessingEvent.audioWakeWord));
        expect(log[2].event, equals(ProcessingEvent.ttsOutput));
      });

      test('audit log is capped at maxEntries', () async {
        for (var i = 0; i < PrivacyConfig.auditLogMaxEntries + 10; i++) {
          await manager.logEvent(ProcessingEvent.cameraObstacleDetection, 'f$i');
        }
        expect(manager.getAuditLog().length,
            equals(PrivacyConfig.auditLogMaxEntries));
      });

      test('oldest entries are dropped when cap exceeded', () async {
        for (var i = 0; i < PrivacyConfig.auditLogMaxEntries + 5; i++) {
          await manager.logEvent(
              ProcessingEvent.cameraObstacleDetection, 'frame_$i');
        }
        final log = manager.getAuditLog();
        // First entry should be frame_5, not frame_0
        expect(log.first.detail, equals('frame_5'));
      });

      test('getProcessingEventTypes returns unique event types', () async {
        await manager.logEvent(ProcessingEvent.audioWakeWord, '1');
        await manager.logEvent(ProcessingEvent.audioWakeWord, '2');
        await manager.logEvent(ProcessingEvent.ttsOutput,     '3');
        final types = manager.getProcessingEventTypes();
        expect(types, hasLength(2));
        expect(types, contains(ProcessingEvent.audioWakeWord));
        expect(types, contains(ProcessingEvent.ttsOutput));
      });
    });

    // ── ConsentState ─────────────────────────────────────────────────────────

    group('ConsentState', () {
      test('isValid requires baseConsent + isAdult + timestamp', () {
        const c = ConsentState(
          baseConsentGiven: true,
          isAdult:          true,
          consentTimestamp: null, // missing
        );
        expect(c.isValid, isFalse);
      });

      test('copyWith preserves unchanged fields', () {
        const original = ConsentState(
          baseConsentGiven:   true,
          onlineSttConsented: true,
          isAdult:            true,
        );
        final copy = original.copyWith(analyticsConsented: true);
        expect(copy.baseConsentGiven,   isTrue);
        expect(copy.onlineSttConsented, isTrue);
        expect(copy.analyticsConsented, isTrue);
      });

      test('JSON round-trip preserves all fields', () {
        final ts = DateTime(2026, 6, 7, 12, 0, 0);
        final state = ConsentState(
          baseConsentGiven:   true,
          onlineSttConsented: true,
          analyticsConsented: false,
          isAdult:            true,
          consentTimestamp:   ts,
          consentVersion:     '1.0',
        );
        final restored = ConsentState.fromJson(state.toJson());
        expect(restored.baseConsentGiven,   equals(state.baseConsentGiven));
        expect(restored.onlineSttConsented, equals(state.onlineSttConsented));
        expect(restored.analyticsConsented, equals(state.analyticsConsented));
        expect(restored.isAdult,            equals(state.isAdult));
        expect(restored.consentVersion,     equals(state.consentVersion));
        expect(restored.consentTimestamp?.toIso8601String(),
            equals(ts.toIso8601String()));
      });
    });

    // ── AuditEntry ───────────────────────────────────────────────────────────

    group('AuditEntry', () {
      test('JSON round-trip preserves all fields', () {
        final ts    = DateTime(2026, 6, 7);
        final entry = AuditEntry(
          timestamp: ts,
          event:     ProcessingEvent.translationOnDevice,
          detail:    'hi→en',
        );
        final restored = AuditEntry.fromJson(entry.toJson());
        expect(restored.event,  equals(entry.event));
        expect(restored.detail, equals(entry.detail));
        expect(restored.timestamp.toIso8601String(),
            equals(ts.toIso8601String()));
      });
    });
  });
}
