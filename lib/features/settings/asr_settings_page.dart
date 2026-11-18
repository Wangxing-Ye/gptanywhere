import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../domain/app_error.dart';
import '../../domain/app_settings.dart';
import '../../l10n/app_text.dart';

class AsrSettingsPage extends StatefulWidget {
  const AsrSettingsPage({super.key, required this.totalMemoryBytes});

  final int? totalMemoryBytes;

  @override
  State<AsrSettingsPage> createState() => _AsrSettingsPageState();
}

class _AsrSettingsPageState extends State<AsrSettingsPage> {
  var _choice = AsrEngineChoice.senseVoice;
  var _loaded = false;
  final _installed = <AsrEngineChoice, bool>{};
  AsrEngineChoice? _downloading;
  var _shownMb = -1;
  var _received = 0;
  var _progressTotal = 0;
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
    final installed = <AsrEngineChoice, bool>{};
    for (final choice in AsrEngineChoice.values) {
      try {
        installed[choice] = await scope.asr.installed(choice) != null;
      } on AppFailure {
        installed[choice] = false;
      }
    }
    final choice = resolveAsrEngine(
      settings.asrEngine,
      widget.totalMemoryBytes,
    );
    if (choice != settings.asrEngine) {
      await scope.settings.save(settings.copyWith(asrEngine: choice));
    }
    if (!mounted) return;
    setState(() {
      _choice = choice;
      _installed
        ..clear()
        ..addAll(installed);
    });
  }

  bool _allowed(AsrEngineChoice choice) {
    return choice.allowedWith(widget.totalMemoryBytes);
  }

  Future<void> _select(AsrEngineChoice? choice) async {
    if (choice == null || !_allowed(choice)) return;
    final store = AppScope.of(context).settings;
    final settings = await store.load();
    await store.save(settings.copyWith(asrEngine: choice));
    if (!mounted) return;
    setState(() => _choice = choice);
  }

  Future<void> _download(AsrEngineChoice choice) async {
    if (_downloading != null || !_allowed(choice)) return;
    final asr = AppScope.of(context).asr;
    setState(() {
      _downloading = choice;
      _shownMb = -1;
      _received = 0;
      _progressTotal = 0;
      _error = null;
    });
    try {
      await asr.download(
        choice,
        onProgress: (received, total) {
          if (!mounted) return;
          final shown = received ~/ 1000000;
          final percent = downloadPercent(received, total);
          if (shown == _shownMb &&
              percent == downloadPercent(_received, _progressTotal) &&
              total == _progressTotal) {
            return;
          }
          _shownMb = shown;
          _received = received;
          _progressTotal = total;
          setState(() {});
        },
      );
      if (!mounted) return;
      setState(() => _installed[choice] = true);
    } on AppFailure catch (error) {
      if (!mounted) return;
      setState(() => _error = _message(error));
    } finally {
      if (mounted) {
        setState(() => _downloading = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.speechModels)),
      body: ListView(
        children: [
          RadioGroup<AsrEngineChoice>(
            groupValue: _choice,
            onChanged: _select,
            child: Column(
              children: [
                for (final choice in AsrEngineChoice.values)
                  _tile(choice, text),
              ],
            ),
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

  Widget _tile(AsrEngineChoice choice, AppText text) {
    final bytes = AppScope.of(context).asr.listedBytes(choice);
    final allowed = _allowed(choice);
    final ready = _installed[choice] ?? false;
    final downloading = _downloading == choice;
    final size = bytes == null ? text.modelNotListed : formatModelSize(bytes);
    final subtitle = StringBuffer(size);
    if (ready) subtitle.write(text.downloadedSuffix);
    if (!allowed) subtitle.write(text.notEnoughMemorySuffix);
    if (downloading) {
      subtitle.clear();
      final percent = _shownMb < 0
          ? null
          : downloadPercent(_received, _progressTotal);
      if (_shownMb < 0) {
        subtitle.write(text.downloading);
      } else if (_progressTotal < 0) {
        subtitle.write(
          text.extractingFraction(
            _shownMb,
            (-_progressTotal) ~/ 1000000,
            percent,
          ),
        );
      } else if (_progressTotal > 0) {
        subtitle.write(
          text.downloadingFraction(
            _shownMb,
            _progressTotal ~/ 1000000,
            percent,
          ),
        );
      } else {
        subtitle.write(text.downloadingAmount(_shownMb));
      }
    }
    return RadioListTile<AsrEngineChoice>(
      title: Text(choice.label),
      subtitle: Text(subtitle.toString()),
      value: choice,
      enabled: allowed,
      secondary: !allowed || ready || bytes == null
          ? null
          : TextButton(
              onPressed: _downloading == null ? () => _download(choice) : null,
              child: Text(text.download),
            ),
    );
  }
}

UiLine _message(AppFailure error) {
  return uiFailure(
    error,
    fallback: switch (error.type) {
      AppErrorType.modelMissing => (text) => text.speechModelNotReady,
      AppErrorType.cancelled => (text) => text.downloadPaused,
      _ => (text) => text.downloadDidNotFinish,
    },
  );
}
