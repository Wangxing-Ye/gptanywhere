import '../domain/app_error.dart';

/// Maps a translation language code to an OCR writing system.
/// A language the text model can translate is not automatically readable in a photo.
String ocrScriptForLanguage(String languageCode) {
  return switch (languageCode) {
    'en' ||
    'nl' ||
    'fr' ||
    'de' ||
    'id' ||
    'it' ||
    'pl' ||
    'pt' ||
    'es' ||
    'tr' ||
    'vi' => 'latin',
    'zh-Hans' || 'zh-Hant' => 'chinese',
    'ja' => 'japanese',
    'ko' => 'korean',
    'hi' => 'devanagari',
    _ => throw AppFailure(
      AppErrorType.languageUnsupported,
      detail: languageCode,
    ),
  };
}
