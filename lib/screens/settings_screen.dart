import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import '../core/constants.dart';
import '../core/dpdp_consent.dart';
import '../services/language_service.dart';
import '../pipelines/pipeline2/stt_manager.dart';
import '../pipelines/pipeline2/vlm_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Use LanguageService directly — no stale 'hi' default
  String _lang = LanguageService.instance.currentCode;
  SttMode _sttMode = SttMode.auto;
  bool _onlineStt = false;
  final _keyCtrl = TextEditingController();
  double _sensitivity = 0.12;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _lang = LanguageService.instance.currentCode;
      _sttMode = SttManager.instance.mode;
      _onlineStt = DpdpConsentManager.instance.onlineSttAllowed;
      _sensitivity = p.getDouble('obstacle_sensitivity') ?? 0.12;
      _keyCtrl.text = p.getString(AppConstants.groqApiKeyPrefKey) ?? '';
    });
  }

  Future<void> _saveKey() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(AppConstants.groqApiKeyPrefKey, _keyCtrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API key saved'), backgroundColor: Color(0xFF00D4AA)));
    }
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 10),
    child: Text(t, style: const TextStyle(
      color: Colors.white54, fontSize: 12,
      fontWeight: FontWeight.w600, letterSpacing: 0.8)));

  Widget _card({required Widget child}) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF1A1A2E),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white10)),
    child: child);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F1A),
        foregroundColor: Colors.white,
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        actions: [
          TextButton(
            onPressed: () => Navigator.pushNamed(context, '/privacy'),
            child: const Text('Privacy', style: TextStyle(color: Color(0xFF6C63FF)))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(20), children: [

        // ── Language ────────────────────────────────────────
        _section('LANGUAGE  •  भाषा'),
        _card(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Transcript & speech will use: ${AppConstants.supportedLanguages.firstWhere((l) => l['code'] == _lang, orElse: () => AppConstants.supportedLanguages[1])['nameEn']}',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const Gap(12),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: AppConstants.supportedLanguages.map((l) {
                final sel = l['code'] == _lang;
                return GestureDetector(
                  onTap: () async {
                    await LanguageService.instance.setLanguage(l['code']!);
                    setState(() => _lang = l['code']!);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Language set to ${l['nameEn']}'),
                        backgroundColor: const Color(0xFF6C63FF),
                        duration: const Duration(seconds: 1)));
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: sel ? cs.primary : Colors.white10,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: sel ? cs.primary : Colors.white24, width: 1.5)),
                    child: Column(children: [
                      Text(l['name']!, style: TextStyle(
                        color: sel ? Colors.white : Colors.white70,
                        fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                        fontSize: 15)),
                      Text(l['nameEn']!, style: TextStyle(
                        color: sel ? Colors.white70 : Colors.white38,
                        fontSize: 10)),
                    ])));
              }).toList()),
          ])),

        // ── STT Mode ────────────────────────────────────────
        _section('SPEECH RECOGNITION'),
        ...SttMode.values.map((m) {
          final labels = ['Auto (smart switching)', 'Always Online (Groq)', 'Always Offline'];
          final subs = [
            'Uses cloud when connected & consented',
            'Requires Groq API key & internet',
            'Fully private, on-device Whisper',
          ];
          return GestureDetector(
            onTap: () { SttManager.instance.setMode(m); setState(() => _sttMode = m); },
            child: _card(child: Row(children: [
              Radio<SttMode>(
                value: m, groupValue: _sttMode,
                onChanged: (v) {
                  if (v != null) { SttManager.instance.setMode(v); setState(() => _sttMode = v); }
                },
                activeColor: cs.primary),
              const Gap(8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(labels[m.index], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                Text(subs[m.index], style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ])),
            ])));
        }),

        // ── Groq API Key ─────────────────────────────────────
        _section('GROQ API KEY'),
        _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: TextField(
              controller: _keyCtrl, obscureText: !_showKey,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'gsk_...', hintStyle: TextStyle(color: Colors.white24),
                border: InputBorder.none))),
            IconButton(
              icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility,
                color: Colors.white38, size: 18),
              onPressed: () => setState(() => _showKey = !_showKey)),
            TextButton(
              onPressed: _saveKey,
              child: const Text('Save', style: TextStyle(color: Color(0xFF6C63FF)))),
          ]),
          const Text('Free key at console.groq.com — needed for online STT',
            style: TextStyle(color: Colors.white38, fontSize: 11)),
        ])),

        // ── Vision Model ─────────────────────────────────────
        _section('VISION MODEL'),
        _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome, color: Color(0xFF6C63FF), size: 18), const Gap(8),
            Text(
              VlmRunner.instance.currentTier == VlmTier.qwen3vl2b
                  ? 'Qwen3-VL-2B (Enhanced)' : 'SmolVLM-256M (Standard)',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ]),
          const Gap(10),
          Row(children: [
            _tierBtn('SmolVLM-256M', VlmRunner.instance.currentTier == VlmTier.smolvlm256m,
              () { VlmRunner.instance.forceSetTier(VlmTier.smolvlm256m); setState(() {}); }),
            const Gap(8),
            _tierBtn('Qwen3-VL-2B', VlmRunner.instance.currentTier == VlmTier.qwen3vl2b,
              () { VlmRunner.instance.forceSetTier(VlmTier.qwen3vl2b); setState(() {}); }),
          ]),
          const Gap(16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, '/download'),
              icon: const Icon(Icons.download, size: 18, color: Colors.white),
              label: const Text('Manage & Download Models', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ])),

        // ── Sensitivity ──────────────────────────────────────
        _section('OBSTACLE ALERT SENSITIVITY'),
        _card(child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Low', style: TextStyle(color: Colors.white38, fontSize: 12)),
            Text(_sensitivity <= 0.08 ? 'Low' : _sensitivity <= 0.14 ? 'Medium' : 'High',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold)),
            const Text('High', style: TextStyle(color: Colors.white38, fontSize: 12)),
          ]),
          Slider(
            value: _sensitivity, min: 0.06, max: 0.20, divisions: 7,
            activeColor: cs.primary, inactiveColor: Colors.white12,
            onChanged: (v) async {
              final p = await SharedPreferences.getInstance();
              await p.setDouble('obstacle_sensitivity', v);
              setState(() => _sensitivity = v);
            }),
        ])),

        // ── Privacy ──────────────────────────────────────────
        _section('PRIVACY'),
        _card(child: Column(children: [
          _toggle('Online STT', 'Send audio to Groq API', Icons.cloud_outlined, _onlineStt, (v) async {
            await DpdpConsentManager.instance.setOnlineSttConsent(v);
            setState(() => _onlineStt = v);
          }),
          const Divider(color: Colors.white10, height: 20),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.shield_outlined, color: Color(0xFF6C63FF)),
            title: const Text('Privacy Dashboard', style: TextStyle(color: Colors.white)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => Navigator.pushNamed(context, '/privacy'),
          ),
          const Divider(color: Colors.white10, height: 20),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_forever_outlined, color: Color(0xFFFF6B6B)),
            title: const Text('Revoke Consent & Reset', style: TextStyle(color: Color(0xFFFF6B6B))),
            trailing: const Icon(Icons.chevron_right, color: Color(0xFFFF6B6B)),
            onTap: () async {
              final ok = await showDialog<bool>(context: context,
                builder: (c) => AlertDialog(
                  backgroundColor: const Color(0xFF1A1A2E),
                  title: const Text('Revoke Consent?', style: TextStyle(color: Colors.white)),
                  content: const Text('Deletes all preferences. Model files are kept.',
                    style: TextStyle(color: Colors.white70)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(c, true),
                      child: const Text('Revoke', style: TextStyle(color: Color(0xFFFF6B6B)))),
                  ]));
              if (ok == true) {
                await DpdpConsentManager.instance.revokeConsent();
                if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
              }
            }),
        ])),

        const Gap(40),
      ]),
    );
  }

  Widget _tierBtn(String label, bool sel, VoidCallback onTap) =>
    GestureDetector(onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFF6C63FF) : Colors.white10,
          borderRadius: BorderRadius.circular(8)),
        child: Text(label, style: TextStyle(
          color: sel ? Colors.white : Colors.white54, fontSize: 12))));

  Widget _toggle(String title, String sub, IconData icon, bool val, ValueChanged<bool> onChange) =>
    Row(children: [
      Icon(icon, color: val ? const Color(0xFF6C63FF) : Colors.white38, size: 20),
      const Gap(12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        Text(sub, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ])),
      Switch(value: val, onChanged: onChange, activeColor: const Color(0xFF6C63FF)),
    ]);

  @override
  void dispose() { _keyCtrl.dispose(); super.dispose(); }
}
