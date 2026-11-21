import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptanywhere/app/app_scope.dart';
import 'package:gptanywhere/data/memory_settings_store.dart';
import 'package:gptanywhere/domain/app_settings.dart';
import 'package:gptanywhere/domain/engines.dart';
import 'package:gptanywhere/domain/photo_source.dart';
import 'package:gptanywhere/domain/voice_capture.dart';
import 'package:gptanywhere/features/chat/chat_page.dart';
import 'package:gptanywhere/features/chat/chat_session.dart';
import 'package:gptanywhere/services/asr_models.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';
import 'package:gptanywhere/services/wav_audio.dart';

void main() {
  testWidgets('a photo is shown and its text is the user message', (
    tester,
  ) async {
    final root = _readyRoot();
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final chat = _EchoChat();
    await tester.pumpWidget(
      _app(
        root: root,
        chat: chat,
        photos: _FixedPhotos(_png),
        ocr: _FixedOcr('车站'),
      ),
    );
    await _settle(tester);

    await tester.tap(find.byTooltip('Gallery'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('车站'), findsOneWidget);
    expect(chat.requests.single.messages.single.text, '车站');
    expect(chat.requests.single.messages.single.image, isNull);
    expect(find.text('Reply 1'), findsOneWidget);
    expect(find.textContaining('今天下午三点'), findsNothing);
  });

  testWidgets('speech is played and silence is not sent to the model', (
    tester,
  ) async {
    final root = _readyRoot();
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final chat = _EchoChat();
    final speech = _Speech('车站');
    final audible = wavFromPcm16(
      samples: Int16List.fromList(List.filled(1600, 2000)),
    );
    final voice = _PlayVoice(audible);
    await tester.pumpWidget(
      _app(
        root: root,
        chat: chat,
        speech: speech,
        voice: voice,
        asr: _ReadyAsr(),
      ),
    );
    await _settle(tester);

    await tester.tap(find.byTooltip('Choose audio'));
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip('Play'), findsOneWidget);
    expect(chat.requests.single.messages.single.text, '车站');
    expect(speech.calls, 1);

    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(voice.played, audible);

    chat.requests.clear();
    speech.calls = 0;
    voice.wav = wavFromPcm16(samples: Int16List(1600));
    await tester.tap(find.byTooltip('Choose audio'));
    await tester.pump();
    await tester.pump();

    expect(find.text('No speech was heard.'), findsOneWidget);
    expect(chat.requests, isEmpty);
    expect(speech.calls, 0);
  });

  testWidgets('the next reply includes the previous turn', (tester) async {
    final root = _readyRoot();
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final chat = _EchoChat();
    await tester.pumpWidget(_app(root: root, chat: chat));
    await _settle(tester);

    await tester.enterText(find.byType(TextField), 'one');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'two');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    final messages = chat.requests.last.messages;
    expect(messages.map((turn) => turn.text), ['one', 'Reply 1', 'two']);
  });

  testWidgets('scrolling or tapping the conversation hides the keyboard', (
    tester,
  ) async {
    final root = _readyRoot();
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await tester.pumpWidget(_app(root: root, chat: _EchoChat()));
    await _settle(tester);

    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    expect(_composerFocused(tester), isTrue);
    await tester.tapAt(tester.getRect(find.byType(ListView)).center);
    await tester.pump();
    expect(_composerFocused(tester), isFalse);

    await tester.enterText(find.byType(TextField), 'one');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    expect(_composerFocused(tester), isTrue);
    await tester.tap(find.text('one'));
    await tester.pump();
    expect(_composerFocused(tester), isFalse);

    for (var i = 0; i < 8; i++) {
      await tester.enterText(find.byType(TextField), 'line $i');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
    }
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    expect(_composerFocused(tester), isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 80));
    await tester.pump();
    expect(_composerFocused(tester), isFalse);
  });

  testWidgets('a late reply does not overwrite the newer one', (tester) async {
    final root = _readyRoot();
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final chat = _GateChat();
    await tester.pumpWidget(_app(root: root, chat: chat));
    await _settle(tester);

    await tester.enterText(find.byType(TextField), 'one');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    chat.emit(chat.requests.first.taskId, 'ONE');
    await tester.pump();
    expect(find.text('ONE'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    chat.emit(chat.requests.first.taskId, 'LEAK');
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'two');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    chat.emit(chat.requests.last.taskId, 'TWO');
    await tester.pump();

    expect(find.text('LEAK'), findsNothing);
    expect(find.textContaining('ONELEAK'), findsNothing);
    expect(find.text('TWO'), findsOneWidget);
  });

  testWidgets('a vision model sends the image and does not read its text', (
    tester,
  ) async {
    final root = _readyRoot();
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const id = 'qwen3.5-2b-q4-k-m';
    const payload = [4, 5, 6, 7];
    final digest = sha256.convert(payload).toString();
    File('${root.path}/$id.gguf').writeAsBytesSync(payload);
    File('${root.path}/$id.gguf.sha256').writeAsStringSync(digest);
    final chat = _EchoChat();
    final ocr = _FixedOcr('车站');
    await tester.pumpWidget(
      _app(
        root: root,
        chat: chat,
        photos: _FixedPhotos(_png),
        ocr: ocr,
        settings: const AppSettings(textModel: TextModelChoice.qwen35_2b),
        catalog: ModelCatalog({
          id: CatalogPackage(
            id: id,
            sizeBytes: payload.length,
            sha256: digest,
            downloadUrl: 'http://127.0.0.1/model.gguf',
            capabilities: const ['text_translation'],
            vision: CatalogVision(
              fileName: '$id.mmproj.gguf',
              sizeBytes: 2,
              sha256: 'ab',
              downloadUrl: 'http://127.0.0.1/vision.gguf',
            ),
          ),
        }),
      ),
    );
    await _settle(tester);

    await tester.tap(find.byTooltip('Gallery'));
    await tester.pump();
    await tester.pump();

    expect(ocr.calls, 0);
    expect(find.text('车站'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(chat.requests.single.messages.single.text, isEmpty);
    expect(chat.requests.single.messages.single.image, _png);
  });
}

final _png = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

bool _composerFocused(WidgetTester tester) {
  return tester
      .state<EditableTextState>(
        find.descendant(
          of: find.byType(TextField),
          matching: find.byType(EditableText),
        ),
      )
      .widget
      .focusNode
      .hasFocus;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();
}

Directory _readyRoot() {
  final root = Directory.systemTemp.createTempSync('ta_chat_page');
  const payload = [4, 5, 6, 7];
  final digest = sha256.convert(payload).toString();
  final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
  file.writeAsBytesSync(payload);
  File('${file.path}.sha256').writeAsStringSync(digest);
  return root;
}

Widget _app({
  required Directory root,
  required ChatEngine chat,
  PhotoSource? photos,
  OcrEngine? ocr,
  SpeechEngine? speech,
  VoiceCapture? voice,
  AsrStore? asr,
  AppSettings settings = AppSettings.defaults,
  ModelCatalog? catalog,
}) {
  const payloadLength = 4;
  final digest = sha256.convert(const [4, 5, 6, 7]).toString();
  return MaterialApp(
    home: Scaffold(
      body: AppScope(
        settings: MemorySettingsStore(initial: settings),
        models: ModelManager(
          catalog:
              catalog ??
              ModelCatalog({
                ModelCatalog.primaryTextModelId: CatalogPackage(
                  id: ModelCatalog.primaryTextModelId,
                  sizeBytes: payloadLength,
                  sha256: digest,
                  downloadUrl: 'http://127.0.0.1/model.gguf',
                  capabilities: const ['text_translation'],
                ),
              }),
          root: root,
          transport: _UnusedTransport(),
          network: _Offline(),
        ),
        translator: const _UnusedTranslator(),
        chat: chat,
        ocr: ocr ?? _FixedOcr(''),
        photos: photos ?? _FixedPhotos(null),
        speech: speech ?? _Speech(''),
        voice: voice ?? _PlayVoice(Uint8List(0)),
        asr: asr ?? _MissingAsr(),
        importPicker: () async => null,
        child: ChatPage(session: ChatSession()),
      ),
    ),
  );
}

class _EchoChat implements ChatEngine {
  final requests = <ChatRequest>[];

  @override
  Stream<ChatEvent> reply(ChatRequest request) async* {
    requests.add(request);
    yield ChatEvent(
      taskId: request.taskId,
      delta: 'Reply ${requests.length}',
      isFinal: false,
    );
    yield ChatEvent(taskId: request.taskId, delta: '', isFinal: true);
  }

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}
}

class _GateChat implements ChatEngine {
  final requests = <ChatRequest>[];
  final _gates = <String, StreamController<ChatEvent>>{};

  void emit(String taskId, String delta) {
    _gates[taskId]?.add(
      ChatEvent(taskId: taskId, delta: delta, isFinal: false),
    );
  }

  @override
  Stream<ChatEvent> reply(ChatRequest request) {
    requests.add(request);
    final controller = StreamController<ChatEvent>();
    _gates[request.taskId] = controller;
    return controller.stream;
  }

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}
}

class _FixedPhotos implements PhotoSource {
  _FixedPhotos(this.bytes);
  final Uint8List? bytes;

  @override
  Future<Uint8List?> pickFromGallery() async => bytes;

  @override
  Future<Uint8List?> takePicture() async => bytes;
}

class _FixedOcr implements OcrEngine {
  _FixedOcr(this.text);
  final String text;

  @override
  Future<void> dispose() async {}

  var calls = 0;

  @override
  Future<OcrDocument> recognize(Uint8List image, String script) async {
    calls++;
    return OcrDocument(
      blocks: [
        OcrBlock(id: 'a', text: text, left: 0, top: 0, right: 1, bottom: 1),
      ],
      readingOrder: const ['a'],
    );
  }
}

class _Speech implements SpeechEngine {
  _Speech(this.text);
  String text;
  var calls = 0;

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<SpeechSegment> transcribe(SpeechRequest request) async* {
    calls++;
    yield SpeechSegment(startMs: 0, endMs: 10, text: text, isFinal: true);
  }
}

class _PlayVoice implements VoiceCapture {
  _PlayVoice(this.wav);
  Uint8List wav;
  Uint8List? played;

  @override
  Stream<int> get elapsedMs => const Stream.empty();

  @override
  Future<Uint8List?> importAudio() async => wav;

  @override
  Future<CapturedAudio?> get recording => Future.value();

  @override
  Future<void> startRecording({required int maxMs}) async {}

  @override
  Future<void> stopRecording() async {}

  @override
  Future<void> play(Uint8List wav) async {
    played = wav;
  }

  @override
  Future<void> stopPlayback() async {}
}

class _ReadyAsr implements AsrStore {
  @override
  int? listedBytes(AsrEngineChoice engine) => null;

  @override
  Future<AsrInstall> download(
    AsrEngineChoice engine, {
    void Function(int received, int total)? onProgress,
  }) async {
    throw const AppFailure(AppErrorType.modelMissing);
  }

  @override
  Future<AsrInstall?> installed(AsrEngineChoice engine) async {
    return AsrInstall(engine: engine, modelPath: '/tmp/sense.bin');
  }
}

class _MissingAsr implements AsrStore {
  @override
  int? listedBytes(AsrEngineChoice engine) => null;

  @override
  Future<AsrInstall> download(
    AsrEngineChoice engine, {
    void Function(int received, int total)? onProgress,
  }) async {
    throw const AppFailure(AppErrorType.modelMissing);
  }

  @override
  Future<AsrInstall?> installed(AsrEngineChoice engine) async => null;
}

class _UnusedTranslator implements TranslationEngine {
  const _UnusedTranslator();

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    throw const AppFailure(AppErrorType.modelMissing);
  }
}

class _Offline implements NetworkGate {
  @override
  Future<bool> isOnline({Uri? target}) async => false;
}

class _UnusedTransport implements ModelTransport {
  @override
  Future<TransportResult> fetch({
    required Uri url,
    required File partial,
    required bool Function() shouldPause,
    required void Function(int received, {int? total}) onProgress,
  }) {
    throw UnimplementedError();
  }
}
