import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import '../core/dpdp_consent.dart';
import '../core/model_manager.dart';

class PrivacyDashboardScreen extends StatefulWidget {
  const PrivacyDashboardScreen({super.key});
  @override State<PrivacyDashboardScreen> createState() => _PrivacyDashboardScreenState();
}

class _PrivacyDashboardScreenState extends State<PrivacyDashboardScreen> {
  @override
  Widget build(BuildContext context) {
    final mgr = DpdpConsentManager.instance;
    final log = mgr.auditLog;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F1A),
        foregroundColor: Colors.white,
        title: const Text('Privacy Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        // ── Consent Summary ─────────────────────────────────────────────────
        _header('Consent Status'),
        const Gap(10),
        _infoCard(children: [
          _row(Icons.check_circle_outline, 'Consent given',
              mgr.hasConsented() ? 'Yes' : 'No',
              mgr.hasConsented() ? const Color(0xFF00D4AA) : const Color(0xFFFF6B6B)),
          const Divider(color: Colors.white10, height: 20),
          _row(Icons.access_time_outlined, 'Consent date', mgr.consentTimestampFormatted, Colors.white54),
          const Divider(color: Colors.white10, height: 20),
          _row(Icons.cloud_outlined, 'Online STT allowed',
              mgr.onlineSttAllowed ? 'Yes (opt-in)' : 'No',
              mgr.onlineSttAllowed ? const Color(0xFF6C63FF) : Colors.white38),
          const Divider(color: Colors.white10, height: 20),
          _row(Icons.analytics_outlined, 'Crash analytics',
              mgr.analyticsAllowed ? 'Yes (opt-in)' : 'No',
              mgr.analyticsAllowed ? const Color(0xFF6C63FF) : Colors.white38),
        ]),

        const Gap(24),

        // ── What we process ─────────────────────────────────────────────────
        _header('What Narrator Processes'),
        const Gap(10),
        _processingItem(Icons.camera_alt_outlined, 'Camera Frames',
            'Processed on-device only by YOLOv8 and SmolVLM.\nNever stored. Never transmitted.', true),
        const Gap(8),
        _processingItem(Icons.mic_none_outlined, 'Microphone Audio',
            'Captured only after wake word. Processed on-device by default.\n${mgr.onlineSttAllowed ? "Online STT: audio sent to Groq API (opt-in)." : "Online STT: disabled."}',
            !mgr.onlineSttAllowed),
        const Gap(8),
        _processingItem(Icons.storage_outlined, 'AI Model Files',
            'Stored in app-private directory (${ModelManager.instance.totalDownloadedMb}MB used).\nNever shared. Deletable from Settings.', true),
        const Gap(8),
        _processingItem(Icons.tune_outlined, 'Preferences',
            'Language, STT mode, sensitivity stored locally in SharedPreferences.\nNo personal identifiers.', true),

        const Gap(24),

        // ── Audit log ───────────────────────────────────────────────────────
        _header('Processing Log (last ${log.length} events)'),
        const Gap(10),
        if (log.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10)),
            child: const Text('No processing events yet. Events appear when you use the app.',
              style: TextStyle(color: Colors.white38, fontSize: 13)))
        else
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10)),
            child: Column(
              children: List.generate(log.length, (i) {
                final e = log[log.length - 1 - i]; // newest first
                return Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(e.stayedOnDevice ? Icons.lock_outline : Icons.cloud_outlined,
                          color: e.stayedOnDevice ? const Color(0xFF00D4AA) : const Color(0xFFFFAA00),
                          size: 16),
                      const Gap(10),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e.dataTypeLabel,
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                        Text(e.description,
                          style: const TextStyle(color: Colors.white54, fontSize: 11)),
                        Text('${e.timestamp.hour}:${e.timestamp.minute.toString().padLeft(2,'0')}:${e.timestamp.second.toString().padLeft(2,'0')} • ${e.stayedOnDevice ? "on-device" : "network"}',
                          style: TextStyle(
                            color: e.stayedOnDevice ? const Color(0xFF00D4AA) : const Color(0xFFFFAA00),
                            fontSize: 10)),
                      ])),
                    ]),
                  ),
                  if (i < log.length - 1) const Divider(color: Colors.white10, height: 1),
                ]);
              }),
            ),
          ),

        const Gap(16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () { mgr.clearAuditLog(); setState(() {}); },
            icon: const Icon(Icons.clear_all, size: 18, color: Colors.white54),
            label: const Text('Clear Log', style: TextStyle(color: Colors.white54)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ),

        const Gap(24),

        // ── DPDP rights ─────────────────────────────────────────────────────
        _header('Your Rights under DPDP Act 2023'),
        const Gap(10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white10)),
          child: Column(children: [
            _rightItem('Right to Access', 'This dashboard shows all data processing.'),
            _rightItem('Right to Correction', 'Update preferences in Settings at any time.'),
            _rightItem('Right to Erasure', 'Use "Revoke Consent" in Settings to delete all data.'),
            _rightItem('Right to Grievance', 'Contact: privacy@narrator-app.in'),
          ]),
        ),
        const Gap(40),
      ]),
    );
  }

  Widget _header(String t) => Text(t,
    style: const TextStyle(color: Colors.white54, fontSize: 12,
      fontWeight: FontWeight.w600, letterSpacing: 0.8));

  Widget _infoCard({required List<Widget> children}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF1A1A2E),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white10)),
    child: Column(children: children));

  Widget _row(IconData icon, String label, String value, Color valueColor) =>
    Row(children: [
      Icon(icon, color: Colors.white38, size: 16), const Gap(10),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      const Spacer(),
      Text(value, style: TextStyle(color: valueColor, fontSize: 13, fontWeight: FontWeight.w600)),
    ]);

  Widget _processingItem(IconData icon, String title, String body, bool onDevice) =>
    Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: onDevice
            ? const Color(0xFF00D4AA).withOpacity(0.06)
            : const Color(0xFFFFAA00).withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: onDevice
            ? const Color(0xFF00D4AA).withOpacity(0.2)
            : const Color(0xFFFFAA00).withOpacity(0.2))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: onDevice ? const Color(0xFF00D4AA) : const Color(0xFFFFAA00), size: 20),
        const Gap(12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: onDevice
                    ? const Color(0xFF00D4AA).withOpacity(0.15)
                    : const Color(0xFFFFAA00).withOpacity(0.15),
                borderRadius: BorderRadius.circular(6)),
              child: Text(onDevice ? 'On-Device' : 'Network',
                style: TextStyle(
                  color: onDevice ? const Color(0xFF00D4AA) : const Color(0xFFFFAA00),
                  fontSize: 10, fontWeight: FontWeight.bold))),
          ]),
          const Gap(4),
          Text(body, style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.5)),
        ])),
      ]),
    );

  Widget _rightItem(String right, String detail) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.check_circle_outline, color: Color(0xFF6C63FF), size: 16),
      const Gap(10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(right, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        Text(detail, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ])),
    ]));
}
