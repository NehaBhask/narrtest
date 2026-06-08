import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:narrator/core/dpdp_consent.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DpdpConsentManager', () {
    test('hasConsented returns false before consent is recorded', () async {
      await DpdpConsentManager.instance.init();
      expect(DpdpConsentManager.instance.hasConsented(), isFalse);
    });

    test('recordConsent sets hasConsented to true', () async {
      await DpdpConsentManager.instance.init();
      await DpdpConsentManager.instance.recordConsent(
        onlineSttAllowed: true, analyticsAllowed: false);
      expect(DpdpConsentManager.instance.hasConsented(), isTrue);
    });

    test('recordConsent stores granular permissions', () async {
      await DpdpConsentManager.instance.init();
      await DpdpConsentManager.instance.recordConsent(
        onlineSttAllowed: true, analyticsAllowed: false);
      expect(DpdpConsentManager.instance.onlineSttAllowed, isTrue);
      expect(DpdpConsentManager.instance.analyticsAllowed, isFalse);
    });

    test('revokeConsent clears all preferences', () async {
      await DpdpConsentManager.instance.init();
      await DpdpConsentManager.instance.recordConsent(
        onlineSttAllowed: true, analyticsAllowed: true);
      await DpdpConsentManager.instance.revokeConsent();
      await DpdpConsentManager.instance.init();
      expect(DpdpConsentManager.instance.hasConsented(), isFalse);
    });

    test('audit log adds and retrieves events', () {
      DpdpConsentManager.instance.clearAuditLog();
      DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
        dataType: DpdpDataType.cameraFrame,
        description: 'Test event',
        stayedOnDevice: true,
        timestamp: DateTime.now(),
      ));
      expect(DpdpConsentManager.instance.auditLog.length, equals(1));
      expect(DpdpConsentManager.instance.auditLog[0].stayedOnDevice, isTrue);
    });

    test('audit log caps at 50 events', () {
      DpdpConsentManager.instance.clearAuditLog();
      for (int i = 0; i < 55; i++) {
        DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
          dataType: DpdpDataType.modelInference,
          description: 'Event $i',
          stayedOnDevice: true,
          timestamp: DateTime.now(),
        ));
      }
      expect(DpdpConsentManager.instance.auditLog.length, equals(50));
    });

    test('setOnlineSttConsent updates granular flag', () async {
      await DpdpConsentManager.instance.init();
      await DpdpConsentManager.instance.setOnlineSttConsent(false);
      expect(DpdpConsentManager.instance.onlineSttAllowed, isFalse);
      await DpdpConsentManager.instance.setOnlineSttConsent(true);
      expect(DpdpConsentManager.instance.onlineSttAllowed, isTrue);
    });
  });
}
