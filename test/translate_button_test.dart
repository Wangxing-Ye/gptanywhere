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
import 'package:gptanywhere/features/translate/text_entry_page.dart';
import 'package:gptanywhere/features/translate/voice_entry_page.dart';
import 'package:gptanywhere/services/asr_models.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';

void main() {
  testWidgets('text translate stays disabled until the source has words', (
    tester,
  ) async {
    final root = _readyRoot('ta_text_button');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await tester.pumpWidget(_app(root, const TextEntryPage()));
    await tester.pump();
    await tester.pump();

    expect(find.text('Current model: Qwen3-1.7B'), findsOneWidget);
    expect(_translateEnabled(tester), isFalse);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(_translateEnabled(tester), isFalse);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(_translateEnabled(tester), isTrue);
    expect(_fieldFocused(tester), isTrue);

    await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
    await tester.pump();
    expect(_fieldFocused(tester), isFalse);
    await _expectDismissOnBlankAndDrag(tester);
  });

  testWidgets(
    'voice translate stays disabled until recognized text has words',
    (tester) async {
      final root = _readyRoot('ta_voice_button');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        _app(root, const VoiceEntryPage(), asr: _ReadyAsr()),
      );
      await tester.pump();
      await tester.pump();

      expect(_pressed(tester, 'Record'), isNotNull);
      expect(_translateEnabled(tester), isFalse);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(_translateEnabled(tester), isFalse);

      await tester.enterText(find.byType(TextField), '车站');
      await tester.pump();
      expect(_translateEnabled(tester), isTrue);
      expect(_fieldFocused(tester), isTrue);

      await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
      await tester.pump();
      expect(_fieldFocused(tester), isFalse);
      await _expectDismissOnBlankAndDrag(tester);
    },
  );
}

Future<void> _expectDismissOnBlankAndDrag(WidgetTester tester) async {
  await tester.showKeyboard(find.byType(TextField));
  await tester.pump();
  expect(_fieldFocused(tester), isTrue);
  await tester.tap(find.text('Translation'));
  await tester.pump();
  expect(_fieldFocused(tester), isFalse);

  await tester.binding.setSurfaceSize(const Size(320, 240));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pump();
  await tester.showKeyboard(find.byType(TextField));
  await tester.pump();
  expect(_fieldFocused(tester), isTrue);
  await tester.drag(find.byType(ListView), const Offset(0, -120));
  await tester.pump();
  expect(_fieldFocused(tester), isFalse);
}

bool _fieldFocused(WidgetTester tester) {
  return tester
      .state<EditableTextState>(find.byType(EditableText))
      .widget
      .focusNode
      .hasFocus;
}

bool _translateEnabled(WidgetTester tester) {
  return tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
      null;
}

VoidCallback? _pressed(WidgetTester tester, String label) {
  return tester
      .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
      .onPressed;
}

Directory _readyRoot(String name) {
  final root = Directory.systemTemp.createTempSync(name);
  const payload = [4, 5, 6, 7];
  final digest = sha256.convert(payload).toString();
  final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
  file.writeAsBytesSync(payload);
  File('${file.path}.sha256').writeAsStringSync(digest);
  return root;
}

Widget _app(Directory root, Widget page, {AsrStore? asr}) {
  const payload = [4, 5, 6, 7];
  final digest = sha256.convert(payload).toString();
  return MaterialApp(
    home: Scaffold(
      body: AppScope(
        settings: MemorySettingsStore(),
        models: ModelManager(
          catalog: ModelCatalog({
            ModelCatalog.primaryTextModelId: CatalogPackage(
              id: ModelCatalog.primaryTextModelId,
              sizeBytes: payload.length,
              sha256: digest,
              downloadUrl: 'http://127.0.0.1/model.gguf',
              capabilities: const ['text_translation'],
            ),
          }),
          root: root,
          transport: _UnusedTransport(),
          network: _Offline(),
        ),
        translator: _QuietTranslator(),
        ocr: _QuietOcr(),
        photos: _QuietPhotos(),
        importPicker: () async => null,
        speech: _QuietSpeech(),
        voice: _QuietVoice(),
        asr: asr ?? _MissingAsr(),
        child: page,
      ),
    ),
  );
}

class _UnusedTransport implements ModelTransport {
  @override
  Future<TransportResult> fetch({
    required Uri url,
    required File partial,
    required bool Function() shouldPause,
    required void Function(int received, {int? total}) onProgress,
  }) async {
    return TransportResult.completed;
  }
}

class _Offline implements NetworkGate {
  @override
  Future<bool> isOnline({Uri? target}) async => false;
}

class _QuietTranslator implements TranslationEngine {
  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {}
}

class _QuietOcr implements OcrEngine {
  @override
  Future<void> dispose() async {}

  @override
  Future<OcrDocument> recognize(Uint8List image, String script) async {
    return const OcrDocument(blocks: [], readingOrder: []);
  }
}

class _QuietPhotos implements PhotoSource {
  @override
  Future<Uint8List?> pickFromGallery() async => null;

  @override
  Future<Uint8List?> takePicture() async => null;
}

class _QuietSpeech implements SpeechEngine {
  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<SpeechSegment> transcribe(SpeechRequest request) async* {}
}

class _QuietVoice implements VoiceCapture {
  @override
  Stream<int> get elapsedMs => const Stream.empty();

  @override
  Future<Uint8List?> importAudio() async => null;

  @override
  Future<CapturedAudio?> get recording => Future.value();

  @override
  Future<void> startRecording({required int maxMs}) async {}

  @override
  Future<void> stopRecording() async {}

  @override
  Future<void> play(Uint8List wav) async {}

  @override
  Future<void> stopPlayback() async {}
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
