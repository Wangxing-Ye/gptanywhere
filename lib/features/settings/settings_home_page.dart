import 'package:flutter/material.dart';

import '../../l10n/app_text.dart';
import 'asr_settings_page.dart';
import 'interface_language_page.dart';
import 'text_model_settings_page.dart';

class SettingsHomePage extends StatelessWidget {
  const SettingsHomePage({super.key, required this.totalMemoryBytes});

  final int? totalMemoryBytes;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final language = InterfaceScope.languageOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.settings)),
      body: ListView(
        children: [
          ListTile(
            title: Text(text.languageSetting),
            subtitle: Text(language.nativeName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const InterfaceLanguagePage(),
                ),
              );
            },
          ),
          ListTile(
            title: Text(text.textModels),
            subtitle: Text(text.textModelsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      TextModelSettingsPage(totalMemoryBytes: totalMemoryBytes),
                ),
              );
            },
          ),
          ListTile(
            title: Text(text.speechModels),
            subtitle: Text(text.speechModelsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      AsrSettingsPage(totalMemoryBytes: totalMemoryBytes),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
