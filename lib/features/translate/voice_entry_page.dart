import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../domain/app_settings.dart';
import '../../domain/engines.dart';
import '../../domain/voice_capture.dart';
import '../../domain/translation_language.dart';
import '../../l10n/app_text.dart';
import '../../services/asr_catalog.dart';
import '../../services/asr_models.dart';
import '../../services/model_catalog.dart';
import '../../services/platform_voice_capture.dart';
import '../../services/wav_audio.dart';
import '../settings/asr_settings_page.dart';

class VoiceEntryPage extends StatefulWidget {
  const VoiceEntryPage({super.key});

  @override
  State<VoiceEntryPage> createState() => _VoiceEntryPageState();
}

class _VoiceEntryPageState extends State<VoiceEntryPage>
    with WidgetsBindingObserver {
  late final TextEditingController _recognized = TextEditingController()
    ..addListener(_onRecognizedEdited);
  var _source = TranslationLanguage.zhHans;
  var _target = TranslationLanguage.english;
  var _engine = AsrEngineChoice.senseVoice;
  var _output = '';
  UiLine _status = (text) => text.checkingSpeechModel;
  var _asrReady = false;
  var _textReady = false;
  var _busy = false;
  var _recording = false;
  var _settled = false;
  var _elapsedMs = 0;
  var _checked = false;
  var _epoch = 0;
  String? _taskId;
  SpeechEngine? _speech;
  TranslationEngine? _translator;
  VoiceCapture? _voice;
  SettingsStore? _settingsStore;
  String _modelId = ModelCatalog.primaryTextModelId;
  var _thinking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final taskId = _taskId;
    _taskId = null;
    _epoch++;
    if (taskId != null) {
      _speech?.cancel(taskId);
      _translator?.cancel(taskId);
    }
    if (_recording) {
      _voice?.stopRecording();
    }
    _settingsStore?.revisions.removeListener(_onSettings);
    _recognized
      ..removeListener(_onRecognizedEdited)
      ..dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _recording) {
      _stopRecording();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_checked) {
      _checked = true;
      final scope = AppScope.of(context);
      _speech = scope.speech;
      _translator = scope.translator;
      _voice = scope.voice;
      _settingsStore = scope.settings;
      _settingsStore!.revisions.addListener(_onSettings);
      _refresh();
    }
  }

  void _onSettings() {
    _refresh();
  }

  void _onRecognizedEdited() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final scope = AppScope.of(context);
    final settings = await scope.settings.load();
    final total = await scope.deviceMemory.totalBytes();
    final choice = resolveTextModel(settings.textModel, total);
    final asrChoice = resolveAsrEngine(settings.asrEngine, total);
    if (asrChoice != settings.asrEngine) {
      await scope.settings.save(settings.copyWith(asrEngine: asrChoice));
    }
    _modelId = choice.id;
    _thinking = settings.thinkingEnabled;
    AsrInstall? asr;
    var textReady = false;
    try {
      asr = await scope.asr.installed(asrChoice);
      textReady = await scope.models.installed(_modelId) != null;
    } on AppFailure {
      asr = null;
    }
    if (!mounted) return;
    setState(() {
      _engine = asrChoice;
      if (!_sourceLanguages.contains(_source)) {
        _source = TranslationLanguage.zhHans;
      }
      _settled = true;
      _asrReady = asr != null;
      _textReady = textReady;
      if (!_busy && !_recording) {
        _status = asr == null ? (text) => text.modelNotReady : (text) => '';
      }
    });
  }

  Future<void> _openSpeechModels() async {
    final total = await AppScope.of(context).deviceMemory.totalBytes();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AsrSettingsPage(totalMemoryBytes: total),
      ),
    );
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _record() async {
    if (_recording || _busy || !_asrReady) return;
    final epoch = ++_epoch;
    await _cancelActive();
    if (!mounted || epoch != _epoch) return;
    final voice = AppScope.of(context).voice;
    setState(() {
      _recording = true;
      _busy = true;
      _elapsedMs = 0;
      _output = '';
      _status = (text) => text.recording;
    });
    final elapsed = voice.elapsedMs.listen((ms) {
      if (!mounted || epoch != _epoch) return;
      setState(() => _elapsedMs = ms);
    });
    try {
      await voice.startRecording(maxMs: PlatformVoiceCapture.recordingLimitMs);
      final audio = await voice.recording;
      if (!mounted || epoch != _epoch) return;
      setState(() => _recording = false);
      if (audio == null) {
        setState(() {
          _busy = false;
          _status = (text) => text.noSpeech;
        });
        return;
      }
      if (audio.reachedLimit) {
        setState(() => _status = (text) => text.reachedRecordLimit);
      } else if (audio.interrupted) {
        setState(() => _status = (text) => text.recordingInterruptedShort);
      }
      await _transcribe(epoch, audio.wav);
    } on AppFailure catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _recording = false;
        _busy = false;
        _status = _message(error);
      });
    } finally {
      await elapsed.cancel();
    }
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    await AppScope.of(context).voice.stopRecording();
  }

  Future<void> _import() async {
    if (_recording || _busy || !_asrReady) return;
    final epoch = ++_epoch;
    await _cancelActive();
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _busy = true;
      _status = (text) => text.openingAudio;
      _output = '';
    });
    try {
      final wav = await AppScope.of(context).voice.importAudio();
      if (!mounted || epoch != _epoch) return;
      if (wav == null) {
        setState(() {
          _busy = false;
          _status = (text) => '';
        });
        return;
      }
      await _transcribe(epoch, wav);
    } on AppFailure catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _busy = false;
        _status = _message(error);
      });
    }
  }

  Future<void> _transcribe(int epoch, Uint8List wav) async {
    if (wavIsSilent(wav)) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _busy = false;
        _recording = false;
        _status = (text) => text.noSpeech;
      });
      return;
    }
    final scope = AppScope.of(context);
    final install = await scope.asr.installed(_engine);
    if (!mounted || epoch != _epoch) return;
    if (install == null) {
      setState(() {
        _busy = false;
        _asrReady = false;
        _status = (text) => text.speechNotReadyToTranscribe;
      });
      return;
    }
    final temp = Directory.systemTemp;
    final file = File(
      '${temp.path}/ta_voice_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    file.writeAsBytesSync(wav);
    final taskId = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _taskId = taskId;
      _busy = true;
      _status = (text) => text.transcribing;
      _recognized.text = '';
    });
    try {
      await for (final segment in scope.speech.transcribe(
        SpeechRequest(
          taskId: taskId,
          wavPath: file.path,
          language: asrLanguageCode(_source.code, engine: _engine.nativeEngine),
          engineName: _engine.nativeEngine,
          modelPath: install.modelPath,
          tokensPath: install.tokensPath,
          convPath: install.convPath,
          encoderPath: install.encoderPath,
          decoderPath: install.decoderPath,
          tokenizerPath: install.tokenizerPath,
        ),
      )) {
        if (!mounted || epoch != _epoch || _taskId != taskId) return;
        if (!segment.isFinal && segment.text.isEmpty) continue;
        _recognized.text = segment.text;
        _hideKeyboard();
      }
      if (!mounted || epoch != _epoch || _taskId != taskId) return;
      _hideKeyboard();
      if (_recognized.text.trim().isEmpty) {
        setState(() {
          _busy = false;
          _status = (text) => text.noSpeech;
        });
        return;
      }
      if (!_textReady) {
        setState(() {
          _busy = false;
          _status = (text) => text.modelNotReadyToTranslate;
        });
        return;
      }
      await _translate(epoch);
    } on AppFailure catch (error) {
      if (!mounted || epoch != _epoch || _taskId != taskId) return;
      setState(() {
        _busy = false;
        _status = _message(error);
      });
    } finally {
      if (file.existsSync()) file.deleteSync();
    }
  }

  void _hideKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  Future<void> _translate(int epoch) async {
    _hideKeyboard();
    final text = _recognized.text.trim();
    if (!mounted || epoch != _epoch) return;
    if (text.isEmpty) {
      setState(() => _busy = false);
      return;
    }
    if (!_textReady) {
      setState(() {
        _busy = false;
        _status = (text) => text.modelNotReadyToTranslate;
      });
      return;
    }
    if (_source.code == _target.code) {
      setState(() {
        _busy = false;
        _status = (text) => text.chooseDifferentTarget;
      });
      return;
    }
    final taskId = DateTime.now().microsecondsSinceEpoch.toString();
    final scope = AppScope.of(context);
    setState(() {
      _taskId = taskId;
      _output = '';
      _busy = true;
      _status = (text) => text.translating;
    });
    try {
      await for (final event in scope.translator.translate(
        TranslationRequest(
          taskId: taskId,
          source: _source.code,
          target: _target.code,
          text: text,
          tokenBudget: 256,
          modelVersion: _modelId,
          thinking: _thinking,
        ),
      )) {
        if (!mounted || epoch != _epoch || _taskId != event.taskId) return;
        final next = event.text.isNotEmpty ? event.text : event.delta;
        if (next.isEmpty) continue;
        setState(() => _output = next);
      }
      if (!mounted || epoch != _epoch || _taskId != taskId) return;
      setState(() {
        _busy = false;
        _status = _output.isEmpty ? (text) => text.noTranslation : (text) => '';
      });
    } on AppFailure catch (error) {
      if (!mounted || epoch != _epoch || _taskId != taskId) return;
      setState(() {
        _busy = false;
        _status = _message(error);
      });
    }
  }

  Future<void> _cancelActive() async {
    final taskId = _taskId;
    _taskId = null;
    if (taskId != null) {
      await _speech?.cancel(taskId);
      await _translator?.cancel(taskId);
    }
  }

  Future<void> _cancel() async {
    _epoch++;
    if (_recording) await _stopRecording();
    await _cancelActive();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _recording = false;
      _status = (text) => text.canceled;
    });
  }

  @override
  Widget build(BuildContext context) {
    final seconds = (_elapsedMs / 1000).floor();
    final text = AppText.of(context);
    final clock = seconds.toString().padLeft(2, '0');
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
                onPressed: () {
                  final nextSource = _sourceLanguages.contains(_target)
                      ? _target
                      : TranslationLanguage.zhHans;
                  setState(() {
                    final nextTarget = _source;
                    _source = nextSource;
                    _target = nextTarget;
                  });
                },
                icon: const Icon(Icons.swap_horiz),
              ),
              Expanded(child: _languageMenu(source: false)),
            ],
          ),
          const SizedBox(height: 4),
          if (_settled && !_asrReady)
            Row(
              children: [
                Flexible(
                  child: Text(
                    text.modelNotReady,
                    key: const Key('voice-status'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _openSpeechModels,
                  child: Text(text.download),
                ),
              ],
            )
          else ...[
            if (_asrReady)
              Text(
                text.currentModel(_engine.label),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (_status(text).isNotEmpty) ...[
              if (_asrReady) const SizedBox(height: 8),
              Text(_status(text), key: const Key('voice-status')),
            ],
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _asrReady && !_busy ? _record : null,
                  child: Text(text.record),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _asrReady && !_busy ? _import : null,
                  child: Text(text.chooseAudio),
                ),
              ),
            ],
          ),
          if (_recording || (_busy && !_recording)) ...[
            const SizedBox(height: 8),
            if (_recording)
              OutlinedButton(
                onPressed: _stopRecording,
                child: Text(text.stopAfter(clock)),
              ),
            if (_busy && !_recording)
              OutlinedButton(onPressed: _cancel, child: Text(text.cancel)),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const Key('voice-recognized'),
            controller: _recognized,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: text.recognizedText,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed:
                  !_busy && _textReady && _recognized.text.trim().isNotEmpty
                  ? () => _translate(_epoch)
                  : null,
              child: Text(text.translate),
            ),
          ),
          const SizedBox(height: 16),
          Text(text.translation, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            _output.isEmpty ? text.noTranslationYet : _output,
            key: const Key('voice-output'),
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

  List<TranslationLanguage> get _sourceLanguages {
    if (_engine == AsrEngineChoice.senseVoice) {
      return TranslationLanguage.senseVoiceSources;
    }
    return TranslationLanguage.values;
  }

  Widget _languageMenu({required bool source}) {
    final value = source ? _source : _target;
    final items = source ? _sourceLanguages : TranslationLanguage.values;
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
      onChanged: _busy
          ? null
          : (TranslationLanguage? language) {
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
    final detail = error.detail ?? '';
    if (detail.contains('超过')) {
      return (text) => text.chinese ? detail : text.recordingTooLong;
    }
    if (detail.contains('没有网络') ||
        detail.contains('下载') ||
        detail.contains('解压') ||
        detail.contains('校验') ||
        detail.contains('已暂停')) {
      return uiFailure(
        error,
        fallback: (text) => text.chinese ? detail : text.downloadDidNotFinish,
      );
    }
    return switch (error.type) {
      AppErrorType.noSpeech => (text) => text.noSpeech,
      AppErrorType.permissionDenied =>
        (text) => text.microphonePermissionDenied,
      AppErrorType.audioInterrupted => (text) => text.recordingInterrupted,
      AppErrorType.languageUnsupported => (text) => text.asrLanguageUnsupported,
      AppErrorType.fileCorrupt => (text) => text.audioUnreadable,
      AppErrorType.modelMissing => (text) => text.speechNotReadyToTranscribe,
      AppErrorType.cancelled => (text) => text.canceled,
      AppErrorType.modelLoadFailed => (text) => text.transcriptionDidNotStart,
      _ => (text) => text.speechTranslationFailed,
    };
  }
}
