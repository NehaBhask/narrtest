import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:narrator/services/language_service.dart';
import 'package:narrator/core/constants.dart';

void main() {
  group('LanguageService', () {
    late LanguageService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      service = LanguageService(prefs);
    });

    // ── defaults ─────────────────────────────────────────────────────────

    group('defaults', () {
      test('default language is English', () {
        expect(service.currentCode, equals('en'));
      });

      test('default does not need translation', () {
        expect(service.needsTranslation, isFalse);
      });

      test('default BCP-47 locale is en-IN', () {
        expect(service.bcp47Locale, equals('en-IN'));
      });

      test('default IndicTrans2 tag is eng_Latn', () {
        expect(service.indicTrans2Tag, equals('eng_Latn'));
      });
    });

    // ── setLanguage ───────────────────────────────────────────────────────

    group('setLanguage', () {
      test('sets Hindi successfully', () async {
        await service.setLanguage('hi');
        expect(service.currentCode, equals('hi'));
      });

      test('sets Tamil successfully', () async {
        await service.setLanguage('ta');
        expect(service.currentCode, equals('ta'));
      });

      test('throws UnsupportedLanguageException for unknown code', () async {
        expect(
          () async => service.setLanguage('xx'),
          throwsA(isA<UnsupportedLanguageException>()),
        );
      });

      test('language persists across service reload', () async {
        await service.setLanguage('te');
        final prefs  = await SharedPreferences.getInstance();
        final reload = LanguageService(prefs);
        expect(reload.currentCode, equals('te'));
      });
    });

    // ── currentNativeName ─────────────────────────────────────────────────

    group('currentNativeName', () {
      test('English native name is English', () {
        expect(service.currentNativeName, equals('English'));
      });

      test('Hindi native name is हिन्दी', () async {
        await service.setLanguage('hi');
        expect(service.currentNativeName, equals('हिन्दी'));
      });

      test('Tamil native name is தமிழ்', () async {
        await service.setLanguage('ta');
        expect(service.currentNativeName, equals('தமிழ்'));
      });

      test('Kannada native name is ಕನ್ನಡ', () async {
        await service.setLanguage('kn');
        expect(service.currentNativeName, equals('ಕನ್ನಡ'));
      });
    });

    // ── needsTranslation ─────────────────────────────────────────────────

    group('needsTranslation', () {
      test('English does not need translation', () async {
        await service.setLanguage('en');
        expect(service.needsTranslation, isFalse);
      });

      test('Hindi needs translation', () async {
        await service.setLanguage('hi');
        expect(service.needsTranslation, isTrue);
      });

      test('Bengali needs translation', () async {
        await service.setLanguage('bn');
        expect(service.needsTranslation, isTrue);
      });
    });

    // ── bcp47Locale ───────────────────────────────────────────────────────

    group('bcp47Locale', () {
      test('Hindi locale is hi-IN', () async {
        await service.setLanguage('hi');
        expect(service.bcp47Locale, equals('hi-IN'));
      });

      test('Telugu locale is te-IN', () async {
        await service.setLanguage('te');
        expect(service.bcp47Locale, equals('te-IN'));
      });
    });

    // ── indicTrans2Tag ────────────────────────────────────────────────────

    group('indicTrans2Tag', () {
      test('Hindi tag is hin_Deva', () async {
        await service.setLanguage('hi');
        expect(service.indicTrans2Tag, equals('hin_Deva'));
      });

      test('Tamil tag is tam_Taml', () async {
        await service.setLanguage('ta');
        expect(service.indicTrans2Tag, equals('tam_Taml'));
      });

      test('Kannada tag is kan_Knda', () async {
        await service.setLanguage('kn');
        expect(service.indicTrans2Tag, equals('kan_Knda'));
      });

      test('Bengali tag is ben_Beng', () async {
        await service.setLanguage('bn');
        expect(service.indicTrans2Tag, equals('ben_Beng'));
      });
    });

    // ── supportedLanguages ────────────────────────────────────────────────

    group('supportedLanguages', () {
      test('returns 7 languages', () {
        expect(service.supportedLanguages, hasLength(7));
      });

      test('all entries have code and native keys', () {
        for (final lang in service.supportedLanguages) {
          expect(lang.containsKey('code'),   isTrue);
          expect(lang.containsKey('native'), isTrue);
        }
      });
    });

    // ── SupportedLanguages static ─────────────────────────────────────────

    group('SupportedLanguages constants', () {
      test('isSupported returns true for en', () {
        expect(SupportedLanguages.isSupported('en'), isTrue);
      });

      test('isSupported returns false for unsupported code', () {
        expect(SupportedLanguages.isSupported('fr'), isFalse);
      });

      test('nativeName returns correct value', () {
        expect(SupportedLanguages.nativeName('hi'), equals('हिन्दी'));
      });

      test('nativeName falls back to code for unknown', () {
        expect(SupportedLanguages.nativeName('zz'), equals('zz'));
      });
    });
  });
}
