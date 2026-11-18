import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../domain/app_error.dart';
import '../../domain/app_settings.dart';
import '../../l10n/app_text.dart';

class TextModelSettingsPage extends StatefulWidget {
  const TextModelSettingsPage({super.key, required this.totalMemoryBytes});

  final int? totalMemoryBytes;

  @override
  State<TextModelSettingsPage> createState() => _TextModelSettingsPageState();
}

class _TextModelSettingsPageState extends State<TextModelSettingsPage> {
  var _choice = TextModelChoice.qwen31_7b;
  var _thinking = false;
  var _loaded = false;
  final _installed = <String, bool>{};
  String? _downloadingId;
  var _shownMb = -1;
  var _received = 0;
  var _total = 0;
  UiLine? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    final scope = AppScope.of(context);
    final settings = await scope.settings.load();
    final installed = <String, bool>{};
    for (final choice in TextModelChoice.values) {
      final package = scope.models.catalog[choice.id];
      if (package == null) {
        installed[choice.id] = false;
        continue;
      }
      try {
        installed[choice.id] = await scope.models.isFullyInstalled(choice.id);
      } on AppFailure {
        installed[choice.id] = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _choice = resolveTextModel(settings.textModel, widget.totalMemoryBytes);
      _thinking = settings.thinkingEnabled;
      _installed
        ..clear()
        ..addAll(installed);
    });
  }

  bool _allowed(TextModelChoice choice) {
    return choice.allowedWith(widget.totalMemoryBytes);
  }

  Future<void> _select(TextModelChoice? choice) async {
    if (choice == null || !_allowed(choice)) return;
    final store = AppScope.of(context).settings;
    final settings = await store.load();
    await store.save(settings.copyWith(textModel: choice));
    if (!mounted) return;
    setState(() => _choice = choice);
  }

  Future<void> _setThinking(bool enabled) async {
    final store = AppScope.of(context).settings;
    final settings = await store.load();
    await store.save(settings.copyWith(thinkingEnabled: enabled));
    if (!mounted) return;
    setState(() => _thinking = enabled);
  }

  Future<void> _download(TextModelChoice choice) async {
    if (_downloadingId != null || !_allowed(choice)) return;
    final models = AppScope.of(context).models;
    final package = models.catalog[choice.id];
    if (package == null) return;
    setState(() {
      _downloadingId = choice.id;
      _shownMb = -1;
      _received = 0;
      _total = package.sizeBytes;
      _error = null;
    });
    try {
      await models.download(
        choice.id,
        onProgress: (received, total) {
          if (!mounted) return;
          final shown = received ~/ 1000000;
          final percent = downloadPercent(received, total);
          if (shown == _shownMb &&
              percent == downloadPercent(_received, _total) &&
              received != total) {
            return;
          }
          _shownMb = shown;
          _received = received;
          _total = total;
          setState(() {});
        },
      );
      if (!mounted) return;
      setState(() => _installed[choice.id] = true);
    } on AppFailure catch (error) {
      if (!mounted) return;
      setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _downloadingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.textModels)),
      body: ListView(
        children: [
          RadioGroup<TextModelChoice>(
            groupValue: _choice,
            onChanged: _select,
            child: Column(
              children: [
                for (final choice in TextModelChoice.values)
                  _tile(choice, text),
              ],
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: Text(text.thinkingMode),
            subtitle: Text(text.thinkingOffByDefault),
            value: _thinking,
            onChanged: _setThinking,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(_error!(text)),
            ),
        ],
      ),
    );
  }

  Widget _tile(TextModelChoice choice, AppText text) {
    final package = AppScope.of(context).models.catalog[choice.id];
    final allowed = _allowed(choice);
    final ready = _installed[choice.id] ?? false;
    final downloading = _downloadingId == choice.id;
    final size = package == null
        ? text.modelNotListed
        : formatModelSize(package.sizeBytes);
    final subtitle = StringBuffer(size);
    if (ready) subtitle.write(text.downloadedSuffix);
    if (!allowed) subtitle.write(text.notEnoughMemorySuffix);
    if (downloading && package != null) {
      subtitle.clear();
      if (_shownMb < 0) {
        subtitle.write(text.downloading);
      } else {
        subtitle.write(
          text.downloadingFraction(
            _shownMb,
            _total ~/ 1000000,
            downloadPercent(_received, _total),
          ),
        );
      }
    }
    return RadioListTile<TextModelChoice>(
      title: Text(choice.label),
      subtitle: Text(subtitle.toString()),
      value: choice,
      enabled: allowed,
      secondary: !allowed || ready || package == null
          ? null
          : TextButton(
              onPressed: _downloadingId == null
                  ? () => _download(choice)
                  : null,
              child: Text(text.download),
            ),
    );
  }
}

UiLine _message(AppFailure error) {
  return uiFailure(
    error,
    fallback: switch (error.type) {
      AppErrorType.modelMissing => (text) => text.modelNotReady,
      AppErrorType.cancelled => (text) => text.downloadPaused,
      _ => (text) => text.downloadDidNotFinish,
    },
  );
}
