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
import 'package:gptanywhere/features/settings/asr_settings_page.dart';
import 'package:gptanywhere/services/asr_catalog.dart';
import 'package:gptanywhere/services/asr_models.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';

void main() {
  testWidgets(
    'installed voice model shows size and the others offer download',
    (tester) async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      harness.installSmall();

      await tester.pumpWidget(harness.app());
      await tester.pump();

      expect(find.text('Speech models'), findsOneWidget);
      expect(find.text('SenseVoice'), findsOneWidget);
      expect(find.text('Whisper-small'), findsOneWidget);
      expect(find.text('Whisper-medium'), findsOneWidget);
      expect(find.text('4 B, downloaded'), findsOneWidget);
      expect(find.text('Download'), findsNWidgets(2));

      await tester.tap(find.text('Whisper-medium'));
      await tester.pump();
      expect(
        (await harness.store.load()).asrEngine,
        AsrEngineChoice.whisperMedium,
      );

      await tester.tap(find.text('Download').first);
      await tester.pump();
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('No network, so the download did not start.'),
        300,
      );
      expect(
        find.text('No network, so the download did not start.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a voice model download shows the percent beside the size', (
    tester,
  ) async {
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final asr = _ProgressAsr(release);
    final root = Directory.systemTemp.createTempSync('ta_asr_percent');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          settings: MemorySettingsStore(),
          models: ModelManager(
            catalog: ModelCatalog(const {}),
            root: root,
            transport: _IdleTransport(),
            network: _Offline(),
          ),
          translator: _UnusedEngine(),
          ocr: _UnusedOcr(),
          photos: _UnusedPhotos(),
          speech: _UnusedSpeech(),
          voice: _UnusedVoice(),
          asr: asr,
          importPicker: () async => null,
          child: const AsrSettingsPage(totalMemoryBytes: null),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Download').first);
    await tester.runAsync(() => asr.reported.future);
    await tester.pump();
    expect(find.text('Downloading 80 / 200 MB  40%'), findsOneWidget);
  });

  testWidgets('8GB phone cannot download Qwen3-ASR 1.7B float32', (
    tester,
  ) async {
    final harness = _QwenHarness(8 * 1024 * 1024 * 1024);
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app());
    await tester.pump();

    expect(find.text('Qwen3-ASR 0.6B int8'), findsOneWidget);
    expect(find.text('Qwen3-ASR 0.6B float32'), findsOneWidget);
    expect(find.text('Qwen3-ASR 1.7B int8'), findsOneWidget);
    expect(find.text('Qwen3-ASR 1.7B float32'), findsOneWidget);
    expect(find.textContaining('Not enough memory'), findsOneWidget);
    expect(find.text('Download'), findsNWidgets(6));
    await tester.scrollUntilVisible(find.text('Qwen3-ASR 1.7B float32'), 300);

    final tile = tester.widget<RadioListTile<AsrEngineChoice>>(
      find.widgetWithText(
        RadioListTile<AsrEngineChoice>,
        'Qwen3-ASR 1.7B float32',
      ),
    );
    expect(tile.enabled, isFalse);

    await tester.tap(
      find.widgetWithText(
        RadioListTile<AsrEngineChoice>,
        'Qwen3-ASR 1.7B float32',
      ),
    );
    await tester.pump();
    expect((await harness.store.load()).asrEngine, AsrEngineChoice.senseVoice);
  });

  testWidgets('12GB phone can select Qwen3-ASR 1.7B float32', (tester) async {
    final harness = _QwenHarness(largeTextModelMinBytes);
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app());
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Qwen3-ASR 1.7B float32'), 300);
    await tester.tap(find.text('Qwen3-ASR 1.7B float32'));
    await tester.pump();
    expect(
      (await harness.store.load()).asrEngine,
      AsrEngineChoice.qwen3Asr17Float32,
    );
  });
}

class _QwenHarness {
  _QwenHarness(this.memory) {
    root = Directory.systemTemp.createTempSync('ta_qwen_menu');
    const digest = 'abc';
    final packages = [
      senseVoiceModelId,
      whisperSmallModelId,
      whisperMediumModelId,
      qwen3Asr06Int8Id,
      qwen3Asr06Float32Id,
      qwen3Asr17Int8Id,
      qwen3Asr17Float32Id,
    ];
    final manifest = StringBuffer('{"packages":[');
    for (var i = 0; i < packages.length; i++) {
      if (i > 0) manifest.write(',');
      manifest.write(
        '{"id":"${packages[i]}","capabilities":["asr"],"sizeBytes":100,"sha256":"$digest","downloadUrl":"http://127.0.0.1/${packages[i]}"}',
      );
    }
    manifest.write(']}');
    asr = AsrModels(
      manifestJson: manifest.toString(),
      root: root,
      transport: _IdleTransport(),
      network: _Offline(),
      extractor: _UnusedExtractor(),
    );
  }

  final int memory;
  late final Directory root;
  final store = MemorySettingsStore();
  late final AsrModels asr;

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  Widget app() {
    return MaterialApp(
      home: AppScope(
        settings: store,
        models: ModelManager(
          catalog: ModelCatalog(const {}),
          root: root,
          transport: _IdleTransport(),
          network: _Offline(),
        ),
        translator: _UnusedEngine(),
        ocr: _UnusedOcr(),
        photos: _UnusedPhotos(),
        speech: _UnusedSpeech(),
        voice: _UnusedVoice(),
        asr: asr,
        importPicker: () async => null,
        child: AsrSettingsPage(totalMemoryBytes: memory),
      ),
    );
  }
}

class _Harness {
  _Harness() {
    final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
    digest = sha256.convert(bytes).toString();
    root = Directory.systemTemp.createTempSync('ta_voice_menu');
    final manifest =
        '''
{"packages":[
  {"id":"$senseVoiceModelId","capabilities":["asr"],"sizeBytes":5,"sha256":"$digest","downloadUrl":"http://127.0.0.1/sense.tar.bz2"},
  {"id":"$whisperSmallModelId","capabilities":["asr"],"sizeBytes":4,"sha256":"$digest","downloadUrl":"http://127.0.0.1/small.bin"},
  {"id":"$whisperMediumModelId","capabilities":["asr"],"sizeBytes":16,"sha256":"$digest","downloadUrl":"http://127.0.0.1/medium.bin"}
]}''';
    asr = AsrModels(
      manifestJson: manifest,
      root: root,
      transport: _IdleTransport(),
      network: _Offline(),
      extractor: _UnusedExtractor(),
    );
  }

  late final Directory root;
  late final String digest;
  final store = MemorySettingsStore();
  late final AsrModels asr;

  void installSmall() {
    final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
    final file = File('${root.path}/$whisperSmallModelId.bin');
    file.writeAsBytesSync(bytes);
    File('${file.path}.sha256').writeAsStringSync(digest);
  }

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  Widget app() {
    return MaterialApp(
      home: AppScope(
        settings: store,
        models: ModelManager(
          catalog: ModelCatalog(const {}),
          root: root,
          transport: _IdleTransport(),
          network: _Offline(),
        ),
        translator: _UnusedEngine(),
        ocr: _UnusedOcr(),
        photos: _UnusedPhotos(),
        speech: _UnusedSpeech(),
        voice: _UnusedVoice(),
        asr: asr,
        importPicker: () async => null,
        child: const AsrSettingsPage(totalMemoryBytes: null),
      ),
    );
  }
}

class _ProgressAsr implements AsrStore {
  _ProgressAsr(this.release);

  final Completer<void> release;
  final reported = Completer<void>();

  @override
  int? listedBytes(AsrEngineChoice engine) => 200000000;

  @override
  Future<AsrInstall?> installed(AsrEngineChoice engine) async => null;

  @override
  Future<AsrInstall> download(
    AsrEngineChoice engine, {
    void Function(int received, int total)? onProgress,
  }) async {
    onProgress?.call(80000000, 200000000);
    if (!reported.isCompleted) reported.complete();
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

class _UnusedExtractor implements TarExtractor {
  @override
  Future<void> extractNamed({
    required File archive,
    required Directory destination,
    required Set<String> names,
    int? expectedBytes,
    void Function(int written)? onProgress,
  }) async {}
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
