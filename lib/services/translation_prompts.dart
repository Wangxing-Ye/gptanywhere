import '../domain/app_error.dart';
import '../domain/translation_language.dart';

String translationSystemPrompt(String target) {
  final language = TranslationLanguage.byCode(target);
  if (language == null) {
    throw AppFailure(AppErrorType.languageUnsupported, detail: target);
  }
  return 'Translate the user text into ${language.promptName}. '
      'Output only the translation.';
}

/// Picks the output language for a pair shown in the menus.
///
/// A clear majority of one writing system translates into the other language.
/// The same writing system, an overlap, a near tie, or text with no letters
/// keeps the menu direction.
String translationTargetCode(String source, String target, String text) {
  final sourceLanguage = TranslationLanguage.byCode(source);
  final targetLanguage = TranslationLanguage.byCode(target);
  if (sourceLanguage == null || targetLanguage == null) return target;
  final sourceScripts = _writingSystem(sourceLanguage);
  final targetScripts = _writingSystem(targetLanguage);
  if (sourceScripts.intersection(targetScripts).isNotEmpty) return target;
  final sourceLetters = _letters(text, sourceScripts);
  final targetLetters = _letters(text, targetScripts);
  final total = sourceLetters + targetLetters;
  if (total == 0) return target;
  if (sourceLetters * 3 >= total * 2) return target;
  if (targetLetters * 3 >= total * 2) return source;
  return target;
}

enum _Script { latin, han, kana, hangul, devanagari, arabic, thai, cyrillic }

Set<_Script> _writingSystem(TranslationLanguage language) {
  return switch (language) {
    TranslationLanguage.english ||
    TranslationLanguage.dutch ||
    TranslationLanguage.french ||
    TranslationLanguage.german ||
    TranslationLanguage.indonesian ||
    TranslationLanguage.italian ||
    TranslationLanguage.polish ||
    TranslationLanguage.portuguese ||
    TranslationLanguage.spanish ||
    TranslationLanguage.turkish ||
    TranslationLanguage.vietnamese => const {_Script.latin},
    TranslationLanguage.zhHans ||
    TranslationLanguage.zhHant => const {_Script.han},
    TranslationLanguage.japanese => const {_Script.han, _Script.kana},
    TranslationLanguage.korean => const {_Script.hangul},
    TranslationLanguage.hindi => const {_Script.devanagari},
    TranslationLanguage.arabic => const {_Script.arabic},
    TranslationLanguage.thai => const {_Script.thai},
    TranslationLanguage.russian ||
    TranslationLanguage.ukrainian => const {_Script.cyrillic},
  };
}

int _letters(String text, Set<_Script> scripts) {
  var count = 0;
  for (final script in scripts) {
    count += switch (script) {
      _Script.latin => _latin.allMatches(text).length,
      _Script.han => _han.allMatches(text).length,
      _Script.kana => _kana.allMatches(text).length,
      _Script.hangul => _hangul.allMatches(text).length,
      _Script.devanagari => _devanagari.allMatches(text).length,
      _Script.arabic => _arabic.allMatches(text).length,
      _Script.thai => _thai.allMatches(text).length,
      _Script.cyrillic => _cyrillic.allMatches(text).length,
    };
  }
  return count;
}

final _latin = RegExp(r'\p{Script=Latin}', unicode: true);
final _han = RegExp(r'\p{Script=Han}', unicode: true);
final _kana = RegExp(r'\p{Script=Hiragana}|\p{Script=Katakana}', unicode: true);
final _hangul = RegExp(r'\p{Script=Hangul}', unicode: true);
final _devanagari = RegExp(r'\p{Script=Devanagari}', unicode: true);
final _arabic = RegExp(r'\p{Script=Arabic}', unicode: true);
final _thai = RegExp(r'\p{Script=Thai}', unicode: true);
final _cyrillic = RegExp(r'\p{Script=Cyrillic}', unicode: true);
