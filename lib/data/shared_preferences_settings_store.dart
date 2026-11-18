import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/app_settings.dart';

class SharedPreferencesSettingsStore implements SettingsStore {
  static const asrEngineKey = 'asr_engine';
  static const textModelKey = 'text_model';
  static const thinkingKey = 'thinking_enabled';
  static const interfaceLanguageKey = 'interface_language';

  final _revisions = ValueNotifier<int>(0);

  @override
  ValueListenable<int> get revisions => _revisions;

  @override
  Future<AppSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    return AppSettings(
      asrEngine: AsrEngineChoice.fromStorage(
        preferences.getString(asrEngineKey),
      ),
      textModel: TextModelChoice.fromStorage(
        preferences.getString(textModelKey),
      ),
      thinkingEnabled: preferences.getBool(thinkingKey) ?? false,
      interfaceLanguage: InterfaceLanguage.fromStorage(
        preferences.getString(interfaceLanguageKey),
      ),
    );
  }

  @override
  Future<void> save(AppSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(asrEngineKey, settings.asrEngine.storageValue);
    await preferences.setString(textModelKey, settings.textModel.id);
    await preferences.setBool(thinkingKey, settings.thinkingEnabled);
    await preferences.setString(
      interfaceLanguageKey,
      settings.interfaceLanguage.storageValue,
    );
    _revisions.value++;
  }
}
