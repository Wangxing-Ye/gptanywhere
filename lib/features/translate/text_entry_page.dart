import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../domain/app_settings.dart';
import '../../domain/engines.dart';
import '../../domain/translation_language.dart';
import '../../l10n/app_text.dart';
import '../../services/model_catalog.dart';
import '../settings/text_model_settings_page.dart';

class TextEntryPage extends StatefulWidget {
  const TextEntryPage({super.key});

  @override
  State<TextEntryPage> createState() => _TextEntryPageState();
}

class _TextEntryPageState extends State<TextEntryPage> {
  late final TextEditingController _sourceController = TextEditingController()
    ..addListener(_onSourceEdited);
  var _source = TranslationLanguage.zhHans;
  var _target = TranslationLanguage.english;
  var _output = '';
  UiLine _status = (text) => text.checkingModel;
  var _ready = false;
  var _running = false;
  var _settled = false;
  var _checked = false;
  String? _taskId;
  TranslationEngine? _translator;
  SettingsStore? _settingsStore;
  String _modelId = ModelCatalog.primaryTextModelId;
  String _modelLabel = TextModelChoice.qwen31_7b.label;
  var _thinking = false;

  @override
  void dispose() {
    final taskId = _taskId;
    _taskId = null;
    if (taskId != null) {
      _translator?.cancel(taskId);
    }
    _settingsStore?.revisions.removeListener(_onSettings);
    _sourceController
      ..removeListener(_onSourceEdited)
      ..dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _translator = AppScope.of(context).translator;
    final store = AppScope.of(context).settings;
    if (!identical(_settingsStore, store)) {
      _settingsStore?.revisions.removeListener(_onSettings);
      _settingsStore = store;
      store.revisions.addListener(_onSettings);
    }
    if (!_checked) {
      _checked = true;
      _refreshModel();
    }
  }

  void _onSettings() {
    _refreshModel();
  }

  void _onSourceEdited() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshModel() async {
    final scope = AppScope.of(context);
    final settings = await scope.settings.load();
    final total = await scope.deviceMemory.totalBytes();
    final choice = resolveTextModel(settings.textModel, total);
    _modelId = choice.id;
    _modelLabel = choice.label;
    _thinking = settings.thinkingEnabled;
    try {
      final installed = await scope.models.installed(_modelId);
      if (!mounted) return;
      setState(() {
        _settled = true;
        _ready = installed != null;
        _status = installed == null
            ? (text) => text.modelNotReady
            : (text) => text.currentModel(_modelLabel);
      });
    } on AppFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _settled = true;
        _ready = false;
        _status = _message(error);
      });
    }
  }

  Future<void> _openTextModels() async {
    final total = await AppScope.of(context).deviceMemory.totalBytes();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TextModelSettingsPage(totalMemoryBytes: total),
      ),
    );
    if (!mounted) return;
    await _refreshModel();
  }

  Future<void> _translate() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final text = _sourceController.text.trim();
    if (text.isEmpty || !_ready || _running) return;
    if (_source.code == _target.code) {
      setState(() => _status = (text) => text.chooseDifferentTarget);
      return;
    }
    final taskId = DateTime.now().microsecondsSinceEpoch.toString();
    final scope = AppScope.of(context);
    setState(() {
      _taskId = taskId;
      _output = '';
      _running = true;
      _status = (text) => text.translating;
    });
    try {
      await for (final event in scope.translator.translate(
        TranslationRequest(
          taskId: taskId,
          source: _source.code,
          target: _target.code,
          text: text,
          tokenBudget: 128,
          modelVersion: _modelId,
          thinking: _thinking,
        ),
      )) {
        if (!mounted || _taskId != event.taskId) return;
        final next = event.text.isNotEmpty ? event.text : event.delta;
        if (next.isEmpty) continue;
        setState(() => _output = next);
      }
      if (!mounted || _taskId != taskId) return;
      setState(
        () => _status = _output.isEmpty
            ? (text) => text.noTranslation
            : (text) => text.currentModel(_modelLabel),
      );
    } on AppFailure catch (error) {
      if (!mounted || _taskId != taskId) return;
      setState(() => _status = _message(error));
    } finally {
      if (mounted && _taskId == taskId) {
        setState(() => _running = false);
      }
    }
  }

  Future<void> _cancel() async {
    final taskId = _taskId;
    _taskId = null;
    if (taskId != null) {
      await AppScope.of(context).translator.cancel(taskId);
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _status = (text) => text.canceled;
    });
  }

  Future<void> _copy() async {
    if (_output.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _output));
    if (!mounted) return;
    setState(() => _status = (text) => text.translationCopied);
  }

  void _swap() {
    setState(() {
      final nextTarget = _source;
      _source = _target;
      _target = nextTarget;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return GestureDetector(
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Expanded(child: _languageMenu(source: true)),
              IconButton(
                tooltip: text.swapLanguages,
                onPressed: _swap,
                icon: const Icon(Icons.swap_horiz),
              ),
              Expanded(child: _languageMenu(source: false)),
            ],
          ),
          const SizedBox(height: 8),
          _statusLine(text),
          const SizedBox(height: 12),
          TextField(
            controller: _sourceController,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: text.sourceText,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              if (_running)
                OutlinedButton(onPressed: _cancel, child: Text(text.cancel))
              else
                FilledButton(
                  onPressed: _ready && _sourceController.text.trim().isNotEmpty
                      ? _translate
                      : null,
                  child: Text(text.translate),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                text.translation,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              TextButton(
                onPressed: _output.isEmpty ? null : _copy,
                child: Text(text.copy),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _output.isEmpty ? text.noTranslationYet : _output,
            key: const Key('translation-output'),
            style: _output.isEmpty
                ? TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _statusLine(AppText text) {
    if (_settled && !_ready) {
      return Row(
        children: [
          Flexible(
            child: Text(text.modelNotReady, key: const Key('translate-status')),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _openTextModels,
            child: Text(text.download),
          ),
        ],
      );
    }
    return Text(_status(text), key: const Key('translate-status'));
  }

  Widget _languageMenu({required bool source}) {
    final value = source ? _source : _target;
    final items = TranslationLanguage.values;
    final chinese = AppText.of(context).chinese;
    return DropdownButton<TranslationLanguage>(
      isExpanded: true,
      value: items.contains(value) ? value : items.first,
      items: [
        for (final language in items)
          DropdownMenuItem(
            value: language,
            child: Text(language.uiLabel(chinese)),
          ),
      ],
      onChanged: (TranslationLanguage? language) {
        if (language == null) return;
        setState(() {
          if (source) {
            _source = language;
          } else {
            _target = language;
          }
        });
      },
    );
  }

  UiLine _message(AppFailure error) {
    return uiFailure(
      error,
      fallback: switch (error.type) {
        AppErrorType.modelMissing => (text) => text.modelNotReadyToTranslate,
        AppErrorType.fileCorrupt => (text) => text.verifyFailedKeptOld,
        AppErrorType.insufficientStorage => (text) => text.notEnoughStorage,
        AppErrorType.languageUnsupported =>
          (text) => text.languagePairUnsupported,
        AppErrorType.cancelled => (text) => text.canceled,
        AppErrorType.modelLoadFailed => (text) => text.translationDidNotStart,
        _ => (text) => text.translationDidNotFinish,
      },
    );
  }
}
