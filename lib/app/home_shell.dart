import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../domain/app_settings.dart';
import '../features/chat/chat_page.dart';
import '../features/chat/chat_session.dart';
import '../features/settings/settings_home_page.dart';
import '../features/translate/photo_entry_page.dart';
import '../features/translate/text_entry_page.dart';
import '../features/translate/voice_entry_page.dart';
import '../l10n/app_text.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _index = 0;
  var _limited = false;
  final _chat = ChatSession();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_limited) return;
    _limited = true;
    _applyMemoryLimit();
  }

  @override
  void dispose() {
    _chat.dispose();
    super.dispose();
  }

  Future<void> _applyMemoryLimit() async {
    final total = await AppScope.of(context).deviceMemory.totalBytes();
    final loaded = await widget.settings.load();
    final text = resolveTextModel(loaded.textModel, total);
    final asr = resolveAsrEngine(loaded.asrEngine, total);
    if (text == loaded.textModel && asr == loaded.asrEngine) return;
    await widget.settings.save(
      loaded.copyWith(textModel: text, asrEngine: asr),
    );
  }

  Future<void> _openSettings() async {
    final total = await AppScope.of(context).deviceMemory.totalBytes();
    await _applyMemoryLimit();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SettingsHomePage(totalMemoryBytes: total),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatPage(session: _chat),
      const TextEntryPage(),
      const PhotoEntryPage(),
      const VoiceEntryPage(),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final text = AppText.of(context);
    final title = AppBar(
      title: Text(text.appTitle),
      actions: [
        IconButton(
          tooltip: text.settings,
          onPressed: _openSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );

    if (wide) {
      return Scaffold(
        appBar: title,
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (index) => setState(() => _index = index),
              labelType: NavigationRailLabelType.all,
              destinations: [
                NavigationRailDestination(
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: Text(text.chatTab),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.notes_outlined),
                  label: Text(text.textTab),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.photo_outlined),
                  label: Text(text.photoTab),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.mic_none_outlined),
                  label: Text(text.voiceTab),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: pages[_index]),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: title,
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            label: text.chatTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.notes_outlined),
            label: text.textTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.photo_outlined),
            label: text.photoTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.mic_none_outlined),
            label: text.voiceTab,
          ),
        ],
      ),
    );
  }
}
