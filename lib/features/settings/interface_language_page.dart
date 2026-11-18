import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../domain/app_settings.dart';
import '../../l10n/app_text.dart';

class InterfaceLanguagePage extends StatelessWidget {
  const InterfaceLanguagePage({super.key});

  Future<void> _select(BuildContext context, InterfaceLanguage language) async {
    final store = AppScope.of(context).settings;
    final settings = await store.load();
    await store.save(settings.copyWith(interfaceLanguage: language));
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final selected = InterfaceScope.languageOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.interfaceLanguage)),
      body: RadioGroup<InterfaceLanguage>(
        groupValue: selected,
        onChanged: (language) {
          if (language == null) return;
          _select(context, language);
        },
        child: ListView(
          children: [
            for (final language in InterfaceLanguage.values)
              RadioListTile<InterfaceLanguage>(
                title: Text(language.nativeName),
                value: language,
              ),
          ],
        ),
      ),
    );
  }
}
