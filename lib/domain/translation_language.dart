/// Languages the translation prompt can name.
/// [photoSource] only means the photo page can hand that code to OCR.
enum TranslationLanguage {
  english('en', 'English', 'English', photoSource: true),
  arabic('ar', '阿拉伯语', 'Arabic'),
  zhHans('zh-Hans', '简体中文', 'Simplified Chinese', photoSource: true),
  zhHant('zh-Hant', '繁体中文', 'Traditional Chinese', photoSource: true),
  dutch('nl', '荷兰语', 'Dutch', photoSource: true),
  french('fr', '法语', 'French', photoSource: true),
  german('de', '德语', 'German', photoSource: true),
  hindi('hi', '印地语', 'Hindi', photoSource: true),
  indonesian('id', '印尼语', 'Indonesian', photoSource: true),
  italian('it', '意大利语', 'Italian', photoSource: true),
  japanese('ja', '日语', 'Japanese', photoSource: true),
  korean('ko', '韩语', 'Korean', photoSource: true),
  polish('pl', '波兰语', 'Polish', photoSource: true),
  portuguese('pt', '葡萄牙语', 'Portuguese', photoSource: true),
  russian('ru', '俄语', 'Russian'),
  spanish('es', '西班牙语', 'Spanish', photoSource: true),
  thai('th', '泰语', 'Thai'),
  turkish('tr', '土耳其语', 'Turkish', photoSource: true),
  ukrainian('uk', '乌克兰语', 'Ukrainian'),
  vietnamese('vi', '越南语', 'Vietnamese', photoSource: true);

  const TranslationLanguage(
    this.code,
    this.label,
    this.promptName, {
    this.photoSource = false,
  });

  final String code;
  final String label;

  /// Menu name for the interface language. English UI uses [promptName].
  String uiLabel(bool chineseInterface) =>
      chineseInterface ? label : promptName;

  /// Name used in the translation instruction. Not a verified quality claim.
  final String promptName;

  /// Photo may use this as the source language.
  final bool photoSource;

  static List<TranslationLanguage> get photoSources => [
    for (final language in values)
      if (language.photoSource) language,
  ];

  /// Left-side languages when the selected voice model is SenseVoice.
  /// Yue is accepted by that model and is not in this menu.
  static const senseVoiceSources = <TranslationLanguage>[
    zhHans,
    zhHant,
    english,
    japanese,
    korean,
  ];

  static TranslationLanguage? byCode(String code) {
    for (final language in values) {
      if (language.code == code) return language;
    }
    return null;
  }
}
