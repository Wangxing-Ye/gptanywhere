import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../domain/app_settings.dart';
import '../../domain/engines.dart';
import '../../domain/translation_language.dart';
import '../../domain/voice_capture.dart';
import '../../l10n/app_text.dart';
import '../../services/asr_catalog.dart';
import '../../services/asr_models.dart';
import '../../services/chat_prompts.dart';
import '../../services/model_catalog.dart';
import '../../services/ocr_script.dart';
import '../../services/platform_voice_capture.dart';
import '../../services/wav_audio.dart';
import '../settings/asr_settings_page.dart';
import '../settings/text_model_settings_page.dart';
import 'chat_session.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.session});

  final ChatSession session;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  var _engine = AsrEngineChoice.senseVoice;
  var _modelId = ModelCatalog.primaryTextModelId;
  var _thinking = false;
  var _textReady = false;
  var _asrReady = false;
  var _settled = false;
  var _busy = false;
  var _recording = false;
  var _elapsedMs = 0;
  var _epoch = 0;
  var _playing = -1;
  var _checked = false;
  String? _taskId;
  UiLine? _notice;
  ChatEngine? _chat;
  SpeechEngine? _speech;
  VoiceCapture? _voice;
  SettingsStore? _settingsStore;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    _composer.addListener(_onComposer);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _chat = scope.chat;
    _speech = scope.speech;
    _voice = scope.voice;
    final store = scope.settings;
    if (!identical(_settingsStore, store)) {
      _settingsStore?.revisions.removeListener(_refresh);
      _settingsStore = store;
      store.revisions.addListener(_refresh);
    }
    if (!_checked) {
      _checked = true;
      _refresh();
    }
  }

  @override
  void dispose() {
    _epoch++;
    _cancelActive();
    widget.session.removeListener(_onSession);
    _settingsStore?.revisions.removeListener(_refresh);
    _composer.removeListener(_onComposer);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onComposer() {
    if (mounted) setState(() {});
  }

  void _onSession() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _refresh() async {
    final scope = AppScope.of(context);
    final settings = await scope.settings.load();
    final total = await scope.deviceMemory.totalBytes();
    final choice = resolveTextModel(settings.textModel, total);
    final asrChoice = resolveAsrEngine(settings.asrEngine, total);
    _modelId = choice.id;
    _thinking = settings.thinkingEnabled;
    _engine = asrChoice;
    final textReady = await scope.models.installed(_modelId) != null;
    AsrInstall? asr;
    try {
      asr = await scope.asr.installed(asrChoice);
    } on AppFailure {
      asr = null;
    }
    if (!mounted) return;
    setState(() {
      _textReady = textReady;
      _asrReady = asr != null;
      _settled = true;
    });
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
    await _refresh();
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

  Future<void> _sendText() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _busy) return;
    _composer.clear();
    final epoch = ++_epoch;
    await _cancelActive();
    if (!mounted || epoch != _epoch) return;
    widget.session.add(ChatMessage(role: ChatRole.user, text: text));
    await _reply(epoch);
  }

  Future<void> _addImage({required bool camera}) async {
    if (_busy) return;
    final epoch = ++_epoch;
    await _cancelActive();
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _busy = true;
      _notice = camera
          ? (text) => text.openingCamera
          : (text) => text.openingGallery;
    });
    final photos = AppScope.of(context).photos;
    Uint8List? bytes;
    try {
      bytes = camera
          ? await photos.takePicture()
          : await photos.pickFromGallery();
    } on AppFailure catch (error) {
      _stop(
        epoch,
        error.type == AppErrorType.fileCorrupt
            ? (text) => text.imageUnreadable
            : _message(error),
      );
      return;
    } catch (_) {
      _stop(epoch, (text) => text.imageUnreadable);
      return;
    }
    if (!mounted || epoch != _epoch) return;
    if (bytes == null) {
      _stop(epoch, null);
      return;
    }
    final image = bytes;
    final index = widget.session.add(
      ChatMessage(role: ChatRole.user, text: '', image: image),
    );
    if (AppScope.of(context).models.catalog[_modelId]?.vision != null) {
      await _reply(epoch);
      return;
    }
    setState(() => _notice = (text) => text.readingImage);
    try {
      final document = await AppScope.of(context).ocr.recognize(
        image,
        ocrScriptForLanguage(TranslationLanguage.zhHans.code),
      );
      if (!mounted || epoch != _epoch) return;
      final recognized = document.plainText.trim();
      widget.session.replace(
        index,
        ChatMessage(role: ChatRole.user, text: recognized, image: image),
      );
      if (recognized.isEmpty) {
        _stop(epoch, (text) => text.noTextInImage);
        return;
      }
      await _reply(epoch);
    } on AppFailure catch (error) {
      _stop(epoch, _message(error));
    } catch (_) {
      _stop(epoch, (text) => text.photoTranslationFailed);
    }
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
      _notice = (text) => text.recording;
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
        _stop(epoch, (text) => text.noSpeech);
        return;
      }
      await _acceptAudio(epoch, audio.wav);
    } on AppFailure catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() => _recording = false);
      _stop(epoch, _message(error, microphone: true));
    } finally {
      await elapsed.cancel();
    }
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    await _voice?.stopRecording();
  }

  Future<void> _importAudio() async {
    if (_recording || _busy || !_asrReady) return;
    final epoch = ++_epoch;
    await _cancelActive();
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _busy = true;
      _notice = (text) => text.openingAudio;
    });
    try {
      final wav = await AppScope.of(context).voice.importAudio();
      if (!mounted || epoch != _epoch) return;
      if (wav == null) {
        _stop(epoch, null);
        return;
      }
      await _acceptAudio(epoch, wav);
    } on AppFailure catch (error) {
      _stop(epoch, _message(error));
    }
  }

  Future<void> _acceptAudio(int epoch, Uint8List wav) async {
    widget.session.add(ChatMessage(role: ChatRole.user, text: '', wav: wav));
    if (wavIsSilent(wav)) {
      _stop(epoch, (text) => text.noSpeech);
      return;
    }
    await _transcribe(epoch, wav);
  }

  Future<void> _transcribe(int epoch, Uint8List wav) async {
    final scope = AppScope.of(context);
    final install = await scope.asr.installed(_engine);
    if (!mounted || epoch != _epoch) return;
    if (install == null) {
      setState(() {
        _busy = false;
        _asrReady = false;
      });
      return;
    }
    final file = File(
      '${Directory.systemTemp.path}/ta_chat_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    file.writeAsBytesSync(wav);
    final taskId = DateTime.now().microsecondsSinceEpoch.toString();
    _taskId = taskId;
    setState(() => _notice = (text) => text.transcribing);
    try {
      var recognized = '';
      await for (final segment in scope.speech.transcribe(
        SpeechRequest(
          taskId: taskId,
          wavPath: file.path,
          language: asrLanguageCode(
            TranslationLanguage.zhHans.code,
            engine: _engine.nativeEngine,
          ),
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
        if (segment.text.isEmpty) continue;
        recognized = segment.text;
      }
      if (!mounted || epoch != _epoch || _taskId != taskId) return;
      final text = recognized.trim();
      _replaceLastUser(text: text, wav: wav);
      if (text.isEmpty) {
        _stop(epoch, (text) => text.noSpeech);
        return;
      }
      await _reply(epoch);
    } on AppFailure catch (error) {
      _stop(epoch, _message(error));
    } finally {
      if (file.existsSync()) file.deleteSync();
    }
  }

  void _replaceLastUser({
    required String text,
    Uint8List? wav,
    Uint8List? image,
  }) {
    final messages = widget.session.messages;
    if (messages.isEmpty) return;
    final last = messages.last;
    if (last.role != ChatRole.user) return;
    widget.session.replace(
      messages.length - 1,
      ChatMessage(
        role: ChatRole.user,
        text: text,
        image: image ?? last.image,
        wav: wav ?? last.wav,
      ),
    );
  }

  Future<void> _reply(int epoch) async {
    if (!mounted || epoch != _epoch) return;
    if (!_textReady) {
      setState(() => _busy = false);
      return;
    }
    final seesImages =
        AppScope.of(context).models.catalog[_modelId]?.vision != null;
    final turns = [
      for (final message in widget.session.messages)
        if (message.text.trim().isNotEmpty ||
            (seesImages &&
                message.image != null &&
                message.role == ChatRole.user))
          ChatTurn(
            role: message.role,
            text: message.text.trim(),
            image: seesImages ? message.image : null,
          ),
    ];
    if (turns.isEmpty || turns.last.role != ChatRole.user) {
      setState(() => _busy = false);
      return;
    }
    final taskId = DateTime.now().microsecondsSinceEpoch.toString();
    _taskId = taskId;
    final index = widget.session.add(
      const ChatMessage(role: ChatRole.assistant, text: ''),
    );
    var spoken = '';
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await for (final event in _chat!.reply(
        ChatRequest(
          taskId: taskId,
          messages: turns,
          tokenBudget: chatReplyTokenBudget,
          modelVersion: _modelId,
          thinking: _thinking,
        ),
      )) {
        if (!mounted || epoch != _epoch || _taskId != event.taskId) return;
        final next = event.text.isNotEmpty ? event.text : event.delta;
        if (next.isEmpty) continue;
        spoken = next;
        widget.session.replace(
          index,
          ChatMessage(role: ChatRole.assistant, text: spoken),
        );
      }
      if (!mounted || epoch != _epoch || _taskId != taskId) return;
      if (spoken.isEmpty) widget.session.removeAt(index);
      setState(() => _busy = false);
    } on AppFailure catch (error) {
      if (!mounted || epoch != _epoch || _taskId != taskId) return;
      if (spoken.isEmpty) widget.session.removeAt(index);
      setState(() {
        _busy = false;
        _notice = _message(error);
      });
    }
  }

  Future<void> _togglePlay(int index) async {
    final wav = widget.session.messages[index].wav;
    if (wav == null || _voice == null) return;
    if (_playing == index) {
      await _voice!.stopPlayback();
      if (mounted) setState(() => _playing = -1);
      return;
    }
    try {
      await _voice!.stopPlayback();
      await _voice!.play(wav);
      if (mounted) setState(() => _playing = index);
    } on AppFailure catch (error) {
      if (!mounted) return;
      setState(() => _notice = _message(error));
    }
  }

  void _stop(int epoch, UiLine? notice) {
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _busy = false;
      _recording = false;
      _notice = notice;
    });
  }

  Future<void> _cancel() async {
    _epoch++;
    if (_recording) await _stopRecording();
    await _cancelActive();
    _dropEmptyAssistant();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _recording = false;
      _notice = (text) => text.canceled;
    });
  }

  Future<void> _cancelActive() async {
    final taskId = _taskId;
    _taskId = null;
    if (taskId != null) {
      await _chat?.cancel(taskId);
      await _speech?.cancel(taskId);
    }
    await _voice?.stopPlayback();
    _playing = -1;
  }

  void _dropEmptyAssistant() {
    final messages = widget.session.messages;
    if (messages.isEmpty) return;
    final last = messages.last;
    if (last.role == ChatRole.assistant && last.text.isEmpty) {
      widget.session.removeAt(messages.length - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final clock = (_elapsedMs / 1000).floor().toString().padLeft(2, '0');
    return Column(
      children: [
        if (_settled && !_textReady)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              children: [
                Flexible(child: Text(text.modelNotReady)),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const Key('chat-text-download'),
                  onPressed: _openTextModels,
                  child: Text(text.download),
                ),
              ],
            ),
          ),
        Expanded(
          child: GestureDetector(
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: ListView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.all(20),
              children: [
                for (var i = 0; i < widget.session.messages.length; i++)
                  _bubble(text, i, widget.session.messages[i]),
              ],
            ),
          ),
        ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_notice!(text), key: const Key('chat-notice')),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: text.gallery,
                    onPressed: _busy ? null : () => _addImage(camera: false),
                    icon: const Icon(Icons.photo_outlined),
                  ),
                  IconButton(
                    tooltip: text.camera,
                    onPressed: _busy ? null : () => _addImage(camera: true),
                    icon: const Icon(Icons.photo_camera_outlined),
                  ),
                  IconButton(
                    tooltip: _recording ? text.stopAfter(clock) : text.record,
                    onPressed: !_asrReady
                        ? null
                        : _recording
                        ? _stopRecording
                        : _busy
                        ? null
                        : _record,
                    icon: Icon(_recording ? Icons.stop : Icons.mic_none),
                  ),
                  IconButton(
                    tooltip: text.chooseAudio,
                    onPressed: _busy || !_asrReady ? null : _importAudio,
                    icon: const Icon(Icons.audio_file_outlined),
                  ),
                  if (_settled && !_asrReady)
                    OutlinedButton(
                      key: const Key('chat-speech-download'),
                      onPressed: _openSpeechModels,
                      child: Text(text.download),
                    ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      minLines: 1,
                      maxLines: 4,
                      enabled: !_busy,
                      decoration: InputDecoration(hintText: text.messageHint),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_busy)
                    IconButton(
                      tooltip: text.cancel,
                      onPressed: _cancel,
                      icon: const Icon(Icons.close),
                    )
                  else
                    IconButton(
                      tooltip: text.send,
                      onPressed: _composer.text.trim().isEmpty
                          ? null
                          : _sendText,
                      icon: const Icon(Icons.send),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bubble(AppText text, int index, ChatMessage message) {
    final mine = message.role == ChatRole.user;
    final theme = Theme.of(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: mine
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.image != null)
              Image.memory(message.image!, height: 160, fit: BoxFit.contain),
            if (message.wav != null)
              IconButton(
                tooltip: _playing == index ? text.stopPlayback : text.play,
                onPressed: () => _togglePlay(index),
                icon: Icon(_playing == index ? Icons.stop : Icons.play_arrow),
              ),
            if (message.text.isNotEmpty) SelectableText(message.text),
          ],
        ),
      ),
    );
  }

  UiLine _message(AppFailure error, {bool microphone = false}) {
    if (error.type == AppErrorType.permissionDenied) {
      return microphone
          ? (text) => text.microphonePermissionDenied
          : (text) => text.cameraPermissionDenied;
    }
    return uiFailure(
      error,
      fallback: switch (error.type) {
        AppErrorType.noSpeech => (text) => text.noSpeech,
        AppErrorType.noText => (text) => text.noTextInImage,
        AppErrorType.languageUnsupported => (text) => text.scriptUnsupported,
        AppErrorType.modelMissing => (text) => text.modelNotReady,
        AppErrorType.cancelled => (text) => text.canceled,
        AppErrorType.fileCorrupt => (text) => text.audioUnreadable,
        AppErrorType.modelLoadFailed => (text) => text.translationDidNotStart,
        _ => (text) => text.translationDidNotFinish,
      },
    );
  }
}
