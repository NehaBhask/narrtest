import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'constants.dart';

/// Processing event types logged for DPDP audit trail.
enum ProcessingEvent {
  cameraObstacleDetection,
  cameraVlmInference,
  audioWakeWord,
  audioStt,
  audioSttOnline,
  translationOnDevice,
  ttsOutput,
}

/// A single entry in the DPDP audit log.
class AuditEntry {
  final DateTime timestamp;
  final ProcessingEvent event;
  final String detail;

  const AuditEntry({
    required this.timestamp,
    required this.event,
    required this.detail,
  });

  Map<String, dynamic> toJson() => {
    'ts':     timestamp.toIso8601String(),
    'event':  event.name,
    'detail': detail,
  };

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
    timestamp: DateTime.parse(j['ts'] as String),
    event:     ProcessingEvent.values.byName(j['event'] as String),
    detail:    j['detail'] as String,
  );
}

/// Consent state persisted to SharedPreferences.
class ConsentState {
  final bool baseConsentGiven;
  final bool onlineSttConsented;
  final bool analyticsConsented;
  final bool isAdult;
  final DateTime? consentTimestamp;
  final String consentVersion;

  const ConsentState({
    this.baseConsentGiven   = false,
    this.onlineSttConsented = false,
    this.analyticsConsented = false,
    this.isAdult            = false,
    this.consentTimestamp,
    this.consentVersion     = PrivacyConfig.consentVersion,
  });

  bool get isValid =>
      baseConsentGiven && isAdult && consentTimestamp != null;

  ConsentState copyWith({
    bool? baseConsentGiven,
    bool? onlineSttConsented,
    bool? analyticsConsented,
    bool? isAdult,
    DateTime? consentTimestamp,
    String? consentVersion,
  }) => ConsentState(
    baseConsentGiven:   baseConsentGiven   ?? this.baseConsentGiven,
    onlineSttConsented: onlineSttConsented ?? this.onlineSttConsented,
    analyticsConsented: analyticsConsented ?? this.analyticsConsented,
    isAdult:            isAdult            ?? this.isAdult,
    consentTimestamp:   consentTimestamp   ?? this.consentTimestamp,
    consentVersion:     consentVersion     ?? this.consentVersion,
  );

  Map<String, dynamic> toJson() => {
    'baseConsentGiven':   baseConsentGiven,
    'onlineSttConsented': onlineSttConsented,
    'analyticsConsented': analyticsConsented,
    'isAdult':            isAdult,
    'consentTimestamp':   consentTimestamp?.toIso8601String(),
    'consentVersion':     consentVersion,
  };

  factory ConsentState.fromJson(Map<String, dynamic> j) => ConsentState(
    baseConsentGiven:   j['baseConsentGiven']   as bool? ?? false,
    onlineSttConsented: j['onlineSttConsented'] as bool? ?? false,
    analyticsConsented: j['analyticsConsented'] as bool? ?? false,
    isAdult:            j['isAdult']            as bool? ?? false,
    consentTimestamp:   j['consentTimestamp'] != null
        ? DateTime.tryParse(j['consentTimestamp'] as String)
        : null,
    consentVersion: j['consentVersion'] as String? ?? PrivacyConfig.consentVersion,
  );
}

/// Manages DPDP Act 2023 consent and audit logging.
///
/// All data processing must be gated behind [isConsentValid].
class DpdpConsentManager {
  static const _consentKey  = 'narrator_consent_v1';
  static const _auditLogKey = 'narrator_audit_log';

  final SharedPreferences _prefs;

  DpdpConsentManager(this._prefs);

  // ── Consent ─────────────────────────────────────────────────────────────

  ConsentState getConsent() {
    final raw = _prefs.getString(_consentKey);
    if (raw == null) return const ConsentState();
    try {
      return ConsentState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ConsentState();
    }
  }

  Future<void> saveConsent(ConsentState state) async {
    await _prefs.setString(_consentKey, jsonEncode(state.toJson()));
  }

  bool get isConsentValid => getConsent().isValid;

  /// Grant base consent (called from consent screen).
  Future<void> grantConsent({
    required bool onlineStt,
    required bool analytics,
    required bool isAdult,
  }) async {
    await saveConsent(ConsentState(
      baseConsentGiven:   true,
      onlineSttConsented: onlineStt,
      analyticsConsented: analytics,
      isAdult:            isAdult,
      consentTimestamp:   DateTime.now(),
      consentVersion:     PrivacyConfig.consentVersion,
    ));
    await logEvent(ProcessingEvent.cameraObstacleDetection, 'consent_granted');
  }

  /// Revoke all consent and delete all preferences (Right to Erasure).
  Future<void> revokeConsent() async {
    await _prefs.remove(_consentKey);
    await _prefs.remove(_auditLogKey);
  }

  // ── Audit log ────────────────────────────────────────────────────────────

  List<AuditEntry> getAuditLog() {
    final raw = _prefs.getString(_auditLogKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => AuditEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> logEvent(ProcessingEvent event, String detail) async {
    final entries = getAuditLog();
    entries.add(AuditEntry(
      timestamp: DateTime.now(),
      event:     event,
      detail:    detail,
    ));

    // Trim to max entries (FIFO)
    final trimmed = entries.length > PrivacyConfig.auditLogMaxEntries
        ? entries.sublist(entries.length - PrivacyConfig.auditLogMaxEntries)
        : entries;

    await _prefs.setString(
      _auditLogKey,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  /// Returns all unique processing event types seen in the audit log.
  Set<ProcessingEvent> getProcessingEventTypes() =>
      getAuditLog().map((e) => e.event).toSet();
}
