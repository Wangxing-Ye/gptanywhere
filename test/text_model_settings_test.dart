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
import 'package:gptanywhere/features/settings/text_model_settings_page.dart';
import 'package:gptanywhere/services/asr_models.dart';
import 'package:gptanywhere/services/device_memory.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';

void main() {
  test('unknown text model falls back and thinking stays off', () {
    expect(TextModelChoice.fromStorage(null), TextModelChoice.qwen31_7b);
    expect(TextModelChoice.fromStorage('nope'), TextModelChoice.qwen31_7b);
    expect(
      TextModelChoice.fromStorage(TextModelChoice.qwen35_2b.id),
      TextModelChoice.qwen35_2b,
    );
    expect(AppSettings.defaults.thinkingEnabled, isFalse);
    expect(AppSettings.defaults.textModel, TextModelChoice.qwen31_7b);
    expect(TextModelChoice.values.first, TextModelChoice.qwen31_7b);
  });

  test('download percent follows received bytes', () {
    expect(downloadPercent(0, 200), 0);
    expect(downloadPercent(80, 200), 40);
    expect(downloadPercent(50, -200), 25);
    expect(downloadPercent(200, 200), 100);
    expect(downloadPercent(300, 200), 100);
    expect(downloadPercent(10, 0), isNull);
  });

  test('Gemma 4 E4B needs 12 GiB and Qwen3.5-4B does not', () {
    expect(
      TextModelChoice.gemma4E4b.allowedWith(gemma4E4bMinBytes - 1),
      isFalse,
    );
    expect(TextModelChoice.gemma4E4b.allowedWith(gemma4E4bMinBytes), isTrue);
    expect(TextModelChoice.gemma4E4b.allowedWith(null), isFalse);
    expect(
      resolveTextModel(TextModelChoice.qwen35_4b, gemma4E4bMinBytes - 1),
      TextModelChoice.qwen35_4b,
    );
    expect(
      resolveTextModel(TextModelChoice.qwen35_4b, gemma4E4bMinBytes),
      TextModelChoice.qwen35_4b,
    );
    expect(
      resolveTextModel(TextModelChoice.gemma4E4b, gemma4E4bMinBytes - 1),
      TextModelChoice.qwen31_7b,
    );
    expect(
      resolveTextModel(TextModelChoice.gemma4E4b, gemma4E4bMinBytes),
      TextModelChoice.gemma4E4b,
    );
    expect(
      resolveTextModel(TextModelChoice.gemma3_4b, gemma4E4bMinBytes - 1),
      TextModelChoice.gemma3_4b,
    );
  });

  testWidgets('downloaded model shows its size and the others offer download', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.install(TextModelChoice.qwen31_7b, 4);

    await tester.pumpWidget(harness.app(totalBytes: 8 * 1024 * 1024 * 1024));
    await tester.pump();

    expect(find.text('4 B, downloaded'), findsOneWidget);
    expect(find.text('Download'), findsNWidgets(12));
    expect(find.text('LFM2.5-1.2B'), findsOneWidget);
    expect(find.text('LFM3-1.7B'), findsOneWidget);
    expect(find.text('LFM2.5-VL-1.6B'), findsOneWidget);
    expect(find.text('MiniCPM-V 4.7 1B'), findsOneWidget);
    expect(find.text('MiniCPM5-1B'), findsOneWidget);
    expect(find.text('MiniCPM5-2B'), findsOneWidget);
    expect(find.text('Gemma 3 1B'), findsOneWidget);
    expect(find.text('Gemma 3 4B'), findsOneWidget);
    expect(find.text('Gemma 4 E2B'), findsOneWidget);
    expect(find.text('Gemma 4 E4B'), findsOneWidget);
    final gemma3 = tester.widget<RadioListTile<TextModelChoice>>(
      find.widgetWithText(RadioListTile<TextModelChoice>, 'Gemma 3 4B'),
    );
    expect(gemma3.enabled, isTrue);
    final qwen4 = tester.widget<RadioListTile<TextModelChoice>>(
      find.widgetWithText(RadioListTile<TextModelChoice>, 'Qwen3.5-4B'),
    );
    expect(qwen4.enabled, isTrue);
    final gemma4 = tester.widget<RadioListTile<TextModelChoice>>(
      find.widgetWithText(RadioListTile<TextModelChoice>, 'Gemma 4 E4B'),
    );
    expect(gemma4.enabled, isFalse);
    await tester.scrollUntilVisible(find.byType(Switch), 300);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Qwen3.5-2B'));
    await tester.pump();
    expect((await harness.store.load()).textModel, TextModelChoice.qwen35_2b);

    await tester.scrollUntilVisible(find.byType(SwitchListTile), 300);
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect((await harness.store.load()).thinkingEnabled, isTrue);
  });

  testWidgets('12GB memory lets Qwen3.5-4B be selected', (tester) async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app(totalBytes: 12 * 1024 * 1024 * 1024));
    await tester.pump();

    final tile = tester.widget<RadioListTile<TextModelChoice>>(
      find.widgetWithText(RadioListTile<TextModelChoice>, 'Qwen3.5-4B'),
    );
    expect(tile.enabled, isTrue);
    expect(find.text('Download'), findsNWidgets(14));

    await tester.tap(find.text('Qwen3.5-4B'));
    await tester.pump();
    expect((await harness.store.load()).textModel, TextModelChoice.qwen35_4b);

    await tester.ensureVisible(find.text('Gemma 4 E4B'));
    await tester.tap(find.text('Gemma 4 E4B'));
    await tester.pump();
    expect((await harness.store.load()).textModel, TextModelChoice.gemma4E4b);
  });

  testWidgets('a text model download shows the percent beside the size', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('ta_text_percent');
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const total = 200000000;
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          settings: MemorySettingsStore(),
          models: _ProgressModels(
            release,
            catalog: ModelCatalog({
              TextModelChoice.qwen31_7b.id: CatalogPackage(
                id: TextModelChoice.qwen31_7b.id,
                sizeBytes: total,
                sha256: 'unused',
                downloadUrl: 'http://127.0.0.1/model.gguf',
                capabilities: const ['text_translation'],
              ),
            }),
            root: root,
          ),
          translator: _UnusedEngine(),
          ocr: _UnusedOcr(),
          photos: _UnusedPhotos(),
          speech: _UnusedSpeech(),
          voice: _UnusedVoice(),
          asr: _UnusedAsr(),
          importPicker: () async => null,
          deviceMemory: FixedDeviceMemory(8 * 1024 * 1024 * 1024),
          child: TextModelSettingsPage(
            totalMemoryBytes: 8 * 1024 * 1024 * 1024,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Download'));
    await tester.pump();
    expect(find.text('Downloading 80 / 200 MB  40%'), findsOneWidget);
  });
}

class _Harness {
  _Harness() {
    root = Directory.systemTemp.createTempSync('ta_text_model');
    const payload = [1, 2, 3, 4];
    digest = sha256.convert(payload).toString();
    store = MemorySettingsStore();
    models = ModelManager(
      catalog: ModelCatalog({
        for (final choice in TextModelChoice.values)
          choice.id: CatalogPackage(
            id: choice.id,
            sizeBytes: choice == TextModelChoice.qwen31_7b ? 4 : 8,
            sha256: digest,
            downloadUrl: 'http://127.0.0.1/${choice.id}',
            capabilities: const ['text_translation'],
          ),
      }),
      root: root,
      transport: _IdleTransport(),
      network: _Offline(),
    );
  }

  late final Directory root;
  late final String digest;
  late final MemorySettingsStore store;
  late final ModelManager models;

  void install(TextModelChoice choice, int size) {
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = i + 1;
    }
    final file = File('${root.path}/${choice.id}.gguf');
    file.writeAsBytesSync(bytes);
    File(
      '${file.path}.sha256',
    ).writeAsStringSync(sha256.convert(bytes).toString());
  }

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  Widget app({required int totalBytes}) {
    return MaterialApp(
      home: AppScope(
        settings: store,
        models: models,
        translator: _UnusedEngine(),
        ocr: _UnusedOcr(),
        photos: _UnusedPhotos(),
        speech: _UnusedSpeech(),
        voice: _UnusedVoice(),
        asr: _UnusedAsr(),
        importPicker: () async => null,
        deviceMemory: FixedDeviceMemory(totalBytes),
        child: TextModelSettingsPage(totalMemoryBytes: totalBytes),
      ),
    );
  }
}

class _ProgressModels extends ModelManager {
  _ProgressModels(this.release, {required super.catalog, required super.root})
    : super(transport: _IdleTransport(), network: _Offline());

  final Completer<void> release;

  @override
  Future<InstalledModel> download(
    String id, {
    void Function(int received, int total)? onProgress,
  }) async {
    onProgress?.call(80000000, catalog[id]!.sizeBytes);
    await release.future;
    throw const AppFailure(AppErrorType.cancelled, detail: '下载已暂停。');
  }
}

class _Offline implements NetworkGate {
  @override
  Future<bool> isOnline({Uri? target}) async => false;
}

class _IdleTransport implements ModelTransport {
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

class _UnusedEngine implements TranslationEngine {
  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {}
}

class _UnusedOcr implements OcrEngine {
  @override
  Future<void> dispose() async {}

  @override
  Future<OcrDocument> recognize(Uint8List image, String script) {
    throw const AppFailure(AppErrorType.noText);
  }
}

class _UnusedPhotos implements PhotoSource {
  @override
  Future<Uint8List?> pickFromGallery() async => null;

  @override
  Future<Uint8List?> takePicture() async => null;
}

class _UnusedSpeech implements SpeechEngine {
  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<SpeechSegment> transcribe(SpeechRequest request) async* {}
}

class _UnusedVoice implements VoiceCapture {
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

class _UnusedAsr implements AsrStore {
  @override
  int? listedBytes(AsrEngineChoice engine) => null;

  @override
  Future<AsrInstall> download(
    AsrEngineChoice engine, {
    void Function(int received, int total)? onProgress,
  }) {
    throw const AppFailure(AppErrorType.modelMissing);
  }

  @override
  Future<AsrInstall?> installed(AsrEngineChoice engine) async => null;
}
