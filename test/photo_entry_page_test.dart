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
import 'package:gptanywhere/services/asr_models.dart';
import 'package:gptanywhere/features/translate/photo_crop_page.dart';
import 'package:gptanywhere/features/translate/photo_entry_page.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';
import 'package:gptanywhere/services/ocr_script.dart';

void main() {
  test(
    'photo script follows the writing system, not every translated language',
    () {
      expect(ocrScriptForLanguage('en'), 'latin');
      expect(ocrScriptForLanguage('fr'), 'latin');
      expect(ocrScriptForLanguage('vi'), 'latin');
      expect(ocrScriptForLanguage('zh-Hans'), 'chinese');
      expect(ocrScriptForLanguage('zh-Hant'), 'chinese');
      expect(ocrScriptForLanguage('ja'), 'japanese');
      expect(ocrScriptForLanguage('ko'), 'korean');
      expect(ocrScriptForLanguage('hi'), 'devanagari');
      expect(() => ocrScriptForLanguage('ar'), throwsA(isA<AppFailure>()));
      expect(() => ocrScriptForLanguage('ru'), throwsA(isA<AppFailure>()));
      expect(() => ocrScriptForLanguage('th'), throwsA(isA<AppFailure>()));
      expect(() => ocrScriptForLanguage('uk'), throwsA(isA<AppFailure>()));
      expect(() => ocrScriptForLanguage('en-GB'), throwsA(isA<AppFailure>()));
    },
  );

  testWidgets('gallery text is translated by the engine and not invented', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('ta_photo');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const payload = [4, 5, 6, 7];
    final digest = sha256.convert(payload).toString();
    final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
    file.writeAsBytesSync(payload);
    File('${file.path}.sha256').writeAsStringSync(digest);
    final engine = _RecordingEngine();

    await tester.pumpWidget(
      MaterialApp(
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
              network: _OfflineGate(),
            ),
            translator: engine,
            ocr: _FixedOcr('车站'),
            photos: _FixedPhotos(_png),
            importPicker: () async => null,
            speech: _QuietSpeech(),
            voice: _IdleVoice(),
            asr: _MissingAsr(),
            child: const PhotoEntryPage(),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    await tester.tap(find.text('Gallery'));
    await tester.pump();
    await tester.pump();

    expect(find.text('车站'), findsWidgets);
    expect(find.text('Station', skipOffstage: false), findsOneWidget);
    expect(engine.requests.single, '车站');
    expect(find.textContaining('今天下午三点'), findsNothing);
    expect(tester.takeException(), isNull);

    final field = find.byKey(const Key('photo-recognized'));
    await tester.showKeyboard(field);
    await tester.pump();
    expect(_recognizedFocused(tester), isTrue);
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Translate'));
    await tester.tap(find.widgetWithText(FilledButton, 'Translate'));
    await tester.pump();
    expect(_recognizedFocused(tester), isFalse);

    await tester.showKeyboard(field);
    await tester.pump();
    expect(_recognizedFocused(tester), isTrue);
    await tester.ensureVisible(find.text('Read again'));
    await tester.tap(find.text('Read again'));
    await tester.pump();
    await tester.pump();
    expect(_recognizedFocused(tester), isFalse);

    await tester.showKeyboard(field);
    await tester.pump();
    await tester.ensureVisible(find.text('Translation'));
    await tester.tap(find.text('Translation'));
    await tester.pump();
    expect(_recognizedFocused(tester), isFalse);
  });

  testWidgets('camera text is translated by the engine', (tester) async {
    final root = Directory.systemTemp.createTempSync('ta_photo_camera');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const payload = [4, 5, 6, 7];
    final digest = sha256.convert(payload).toString();
    final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
    file.writeAsBytesSync(payload);
    File('${file.path}.sha256').writeAsStringSync(digest);
    final engine = _RecordingEngine();

    await tester.pumpWidget(
      MaterialApp(
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
              network: _OfflineGate(),
            ),
            translator: engine,
            ocr: _FixedOcr('门口'),
            photos: _FixedPhotos(_png),
            importPicker: () async => null,
            speech: _QuietSpeech(),
            voice: _IdleVoice(),
            asr: _MissingAsr(),
            child: const PhotoEntryPage(),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    await tester.tap(find.text('Camera'));
    await tester.pump();
    await tester.pump();
    await _confirmCrop(tester);

    expect(find.text('门口'), findsWidgets);
    expect(find.text('Station', skipOffstage: false), findsOneWidget);
    expect(engine.requests.single, '门口');
  });

  testWidgets('canceling the crop keeps the previous photo', (tester) async {
    final root = Directory.systemTemp.createTempSync('ta_photo_crop_cancel');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppScope(
            settings: MemorySettingsStore(),
            models: ModelManager(
              catalog: ModelCatalog(const {}),
              root: root,
              transport: _UnusedTransport(),
              network: _OfflineGate(),
            ),
            translator: _RecordingEngine(),
            ocr: _FixedOcr('车站'),
            photos: _FixedPhotos(_png),
            importPicker: () async => null,
            speech: _QuietSpeech(),
            voice: _IdleVoice(),
            asr: _MissingAsr(),
            child: const PhotoEntryPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Gallery'));
    await tester.pump();
    await tester.pump();
    expect(find.text('车站'), findsWidgets);

    await tester.tap(find.text('Camera'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Crop'), findsOneWidget);
    await tester.tap(find.byKey(PhotoCropPage.cancelKey));
    await tester.pump();
    await tester.pump();

    expect(find.text('Crop'), findsNothing);
    expect(find.text('The image was not changed.'), findsOneWidget);
    expect(find.text('车站'), findsWidgets);
  });

  testWidgets('a declined gallery pick leaves the page without a result', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('ta_photo_empty');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppScope(
            settings: MemorySettingsStore(),
            models: ModelManager(
              catalog: ModelCatalog(const {}),
              root: root,
              transport: _UnusedTransport(),
              network: _OfflineGate(),
            ),
            translator: _RecordingEngine(),
            ocr: _FixedOcr('不应出现'),
            photos: _FixedPhotos(null),
            importPicker: () async => null,
            speech: _QuietSpeech(),
            voice: _IdleVoice(),
            asr: _MissingAsr(),
            child: const PhotoEntryPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Gallery'));
    await tester.pump();
    await tester.pump();

    expect(find.text('不应出现'), findsNothing);
    expect(find.text('No translation yet'), findsOneWidget);
    expect(find.textContaining('Choose a photo'), findsNothing);
  });

  testWidgets('a camera failure unlocks the gallery and camera buttons', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('ta_photo_fail');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppScope(
            settings: MemorySettingsStore(),
            models: ModelManager(
              catalog: ModelCatalog(const {}),
              root: root,
              transport: _UnusedTransport(),
              network: _OfflineGate(),
            ),
            translator: _RecordingEngine(),
            ocr: _FixedOcr('不应出现'),
            photos: _BrokenCamera(),
            importPicker: () async => null,
            speech: _QuietSpeech(),
            voice: _IdleVoice(),
            asr: _MissingAsr(),
            child: const PhotoEntryPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Camera'));
    await tester.pump();
    await tester.pump();

    expect(find.text('This image cannot be read.'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('不应出现'), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Camera'))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Gallery'),
          )
          .onPressed,
      isNotNull,
    );
  });
}

bool _recognizedFocused(WidgetTester tester) {
  return tester
      .state<EditableTextState>(find.byType(EditableText))
      .widget
      .focusNode
      .hasFocus;
}

Future<void> _confirmCrop(WidgetTester tester) async {
  final use = find.byKey(PhotoCropPage.useKey);
  expect(use, findsOneWidget);
  await tester.tap(use);
  await tester.pump();
  await tester.pump();
}

/// 1×1 opaque PNG so the preview can decode inside a widget test.
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
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x77,
  0x53,
  0xDE,
  0x00,
  0x00,
  0x00,
  0x0C,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xD7,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0x00,
  0x00,
  0x00,
  0x03,
  0x00,
  0x01,
  0x00,
  0x05,
  0xFE,
  0x02,
  0xFE,
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

class _OfflineGate implements NetworkGate {
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

class _BrokenCamera implements PhotoSource {
  @override
  Future<Uint8List?> pickFromGallery() async => null;

  @override
  Future<Uint8List?> takePicture() async {
    throw Exception('camera result was not delivered');
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

class _IdleVoice implements VoiceCapture {
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

class _QuietSpeech implements SpeechEngine {
  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<SpeechSegment> transcribe(SpeechRequest request) async* {}
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

  @override
  Future<OcrDocument> recognize(Uint8List image, String script) async {
    return OcrDocument(
      blocks: [
        OcrBlock(id: 'b0', text: text, left: 0, top: 0, right: 1, bottom: 1),
      ],
      readingOrder: const ['b0'],
    );
  }
}

class _RecordingEngine implements TranslationEngine {
  final requests = <String>[];

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    requests.add(request.text);
    yield TranslationEvent(
      taskId: request.taskId,
      delta: 'Station',
      isFinal: false,
    );
    yield TranslationEvent(taskId: request.taskId, delta: '', isFinal: true);
  }
}
