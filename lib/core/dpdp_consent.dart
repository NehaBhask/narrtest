import 'package:shared_preferences/shared_preferences.dart';
import 'constants.dart';

/// Manages DPDP (Digital Personal Data Protection Act 2023) consent state.
/// All consent decisions are stored locally only — never transmitted.
class DpdpConsentManager {
  DpdpConsentManager._();
  static final DpdpConsentManager instance = DpdpConsentManager._();

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ── Core Consent ──────────────────────────────────────────────────────────

  /// Returns true if the user has given valid, current consent.
  bool hasConsented() {
    final storedVersion = _prefs?.getString(AppConstants.privacyPolicyVersionKey);
    final hasFlag = _prefs?.getBool(AppConstants.dpdpConsentKey) ?? false;
    return hasFlag && storedVersion == AppConstants.privacyPolicyVersion;
  }

  /// Records the user's explicit consent with timestamp.
  Future<void> recordConsent({
    required bool onlineSttAllowed,
    required bool analyticsAllowed,
  }) async {
    final now = DateTime.now().toIso8601String();
    await _prefs?.setBool(AppConstants.dpdpConsentKey, true);
    await _prefs?.setString(AppConstants.dpdpConsentTimestampKey, now);
    await _prefs?.setString(
        AppConstants.privacyPolicyVersionKey, AppConstants.privacyPolicyVersion);
    await _prefs?.setBool(AppConstants.dpdpOnlineSttConsentKey, onlineSttAllowed);
    await _prefs?.setBool(AppConstants.dpdpAnalyticsConsentKey, analyticsAllowed);
  }

  /// Revokes all consent and clears all local data.
  Future<void> revokeConsent() async {
    await _prefs?.clear();
  }

  // ── Granular Permissions ──────────────────────────────────────────────────

  bool get onlineSttAllowed =>
      _prefs?.getBool(AppConstants.dpdpOnlineSttConsentKey) ?? false;

  bool get analyticsAllowed =>
      _prefs?.getBool(AppConstants.dpdpAnalyticsConsentKey) ?? false;

  Future<void> setOnlineSttConsent(bool value) async {
    await _prefs?.setBool(AppConstants.dpdpOnlineSttConsentKey, value);
  }

  Future<void> setAnalyticsConsent(bool value) async {
    await _prefs?.setBool(AppConstants.dpdpAnalyticsConsentKey, value);
  }

  // ── Audit Log (in-memory ring buffer, never persisted) ────────────────────

  final List<DpdpAuditEvent> _auditLog = [];
  static const int _maxAuditEvents = 50;

  void logEvent(DpdpAuditEvent event) {
    if (_auditLog.length >= _maxAuditEvents) {
      _auditLog.removeAt(0);
    }
    _auditLog.add(event);
  }

  List<DpdpAuditEvent> get auditLog => List.unmodifiable(_auditLog);

  void clearAuditLog() => _auditLog.clear();

  // ── Consent Metadata ─────────────────────────────────────────────────────

  String? get consentTimestamp =>
      _prefs?.getString(AppConstants.dpdpConsentTimestampKey);

  String get consentTimestampFormatted {
    final ts = consentTimestamp;
    if (ts == null) return 'Not consented';
    final dt = DateTime.tryParse(ts);
    if (dt == null) return ts;
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

enum DpdpDataType {
  cameraFrame,
  audioCapture,
  networkRequest,
  modelInference,
  userPreference,
}

class DpdpAuditEvent {
  final DpdpDataType dataType;
  final String description;
  final bool stayedOnDevice;
  final DateTime timestamp;

  const DpdpAuditEvent({
    required this.dataType,
    required this.description,
    required this.stayedOnDevice,
    required this.timestamp,
  });

  String get dataTypeLabel {
    switch (dataType) {
      case DpdpDataType.cameraFrame:
        return 'Camera Frame';
      case DpdpDataType.audioCapture:
        return 'Audio Capture';
      case DpdpDataType.networkRequest:
        return 'Network Request';
      case DpdpDataType.modelInference:
        return 'Model Inference';
      case DpdpDataType.userPreference:
        return 'Preference';
    }
  }
}
