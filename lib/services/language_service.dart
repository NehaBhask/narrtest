import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants.dart';

/// Manages the active UI language and provides locale utilities.
class LanguageService {
  static const _prefKey = 'narrator_language_code';

  final SharedPreferences _prefs;

  LanguageService(this._prefs);

  /// Currently selected language code (defaults to 'en').
  String get currentCode =>
      _prefs.getString(_prefKey) ?? SupportedLanguages.defaultCode;

  /// Set the active language. Throws if [code] is not supported.
  Future<void> setLanguage(String code) async {
    if (!SupportedLanguages.isSupported(code)) {
      throw UnsupportedLanguageException(code);
    }
    await _prefs.setString(_prefKey, code);
  }

  /// Returns the native display name for the current language.
  String get currentNativeName => SupportedLanguages.nativeName(currentCode);

  /// All supported languages.
  List<Map<String, String>> get supportedLanguages => SupportedLanguages.all;

  /// True if the current language is a non-English Indian language.
  bool get needsTranslation => currentCode != 'en';

  /// Returns BCP-47 locale string (e.g. 'hi-IN', 'ta-IN').
  String get bcp47Locale {
    if (currentCode == 'en') return 'en-IN';
    return '$currentCode-IN';
  }

  /// Returns the IndicTrans2 language tag for the current language.
  String get indicTrans2Tag {
    const map = {
      'hi': 'hin_Deva',
      'ta': 'tam_Taml',
      'te': 'tel_Telu',
      'bn': 'ben_Beng',
      'mr': 'mar_Deva',
      'kn': 'kan_Knda',
      'en': 'eng_Latn',
    };
    return map[currentCode] ?? 'eng_Latn';
  }
}

class UnsupportedLanguageException implements Exception {
  final String code;
  const UnsupportedLanguageException(this.code);
  @override
  String toString() => 'UnsupportedLanguageException: "$code" is not supported';
}
