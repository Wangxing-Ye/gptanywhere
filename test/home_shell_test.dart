import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptanywhere/app/app_scope.dart';
import 'package:gptanywhere/app/home_shell.dart';
import 'package:gptanywhere/data/memory_settings_store.dart';
import 'package:gptanywhere/domain/app_settings.dart';
import 'package:gptanywhere/domain/engines.dart';
import 'package:gptanywhere/domain/photo_source.dart';
import 'package:gptanywhere/domain/voice_capture.dart';
import 'package:gptanywhere/services/asr_models.dart';
import 'package:gptanywhere/main.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ta_shell');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  TranslateAnywhereApp harness(SettingsStore settings, {Key? key}) {
    return TranslateAnywhereApp(
      key: key,
      settings: settings,
      models: ModelManager(
        catalog: ModelCatalog.parse(
          File('models/manifest.json').readAsStringSync(),
        ),
        root: root,
        transport: _IdleTransport(),
        network: _OfflineGate(),
      ),
      translator: _UnusedEngine(),
      ocr: _SilentOcr(),
      photos: _EmptyPhotos(),
      speech: _QuietSpeech(),
      voice: _IdleVoice(),
      asr: _MissingAsr(),
      importPicker: () async => null,
    );
  }

  Future<void> show(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(widget);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets('three entries stay empty of recognition results', (
    tester,
  ) async {
    await show(tester, harness(MemorySettingsStore()));

    expect(find.text('GPTAnywhere'), findsOneWidget);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(
      bar.destinations.whereType<NavigationDestination>().map(
        (item) => item.label,
      ),
      ['Chat', 'Text', 'Photo', 'Voice'],
    );

    await tester.tap(find.text('Text'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('No translation yet'), findsOneWidget);
    expect(find.textContaining('The model is not ready'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.text('Translate'));
    await tester.pump();

    expect(find.text('No translation yet'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);

    await tester.tap(find.text('Photo'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('No translation yet'), findsOneWidget);
    expect(find.textContaining('今天下午三点'), findsNothing);
    expect(find.textContaining('The train'), findsNothing);

    await tester.tap(find.text('Voice'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Choose audio'), findsOneWidget);
    expect(find.text('No translation yet'), findsOneWidget);
    expect(find.textContaining('今天下午三点'), findsNothing);
    expect(find.textContaining('The train'), findsNothing);
  });

  testWidgets('wide layout uses a rail for the same three entries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await show(tester, harness(MemorySettingsStore()));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Chat'), findsWidgets);
    await tester.tap(find.text('Text'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('No translation yet'), findsOneWidget);
  });

  testWidgets('asr setting defaults to SenseVoice and can store whisper', (
    tester,
  ) async {
    final store = MemorySettingsStore();
    await show(tester, harness(store));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Text models'), findsOneWidget);

    expect(find.text('Speech models'), findsOneWidget);
    expect(find.text('Model that turns speech into text'), findsOneWidget);

    await tester.tap(find.text('Speech models'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    RadioGroup<AsrEngineChoice> group() {
      return tester.widget<RadioGroup<AsrEngineChoice>>(
        find.byType(RadioGroup<AsrEngineChoice>),
      );
    }

    expect(group().groupValue, AsrEngineChoice.senseVoice);
    expect(find.text('Whisper-small'), findsOneWidget);
    expect(find.text('Whisper-medium'), findsOneWidget);

    await tester.tap(find.text('Whisper-small'));
    await tester.pump();

    expect(group().groupValue, AsrEngineChoice.whisperSmall);
    expect((await store.load()).asrEngine, AsrEngineChoice.whisperSmall);

    await show(tester, harness(store, key: const ValueKey('reopen')));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Text models'), findsOneWidget);

    await tester.tap(find.text('Speech models'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(group().groupValue, AsrEngineChoice.whisperSmall);
  });

  test('unknown stored asr value falls back to SenseVoice', () {
    expect(AsrEngineChoice.fromStorage(null), AsrEngineChoice.senseVoice);
    expect(AsrEngineChoice.fromStorage('other'), AsrEngineChoice.senseVoice);
    expect(
      AsrEngineChoice.fromStorage('whisper'),
      AsrEngineChoice.whisperSmall,
    );
    expect(
      AsrEngineChoice.fromStorage('whisperMedium'),
      AsrEngineChoice.whisperMedium,
    );
    expect(AsrEngineChoice.whisperSmall.nativeEngine, 'whisper');
    expect(AsrEngineChoice.whisperMedium.nativeEngine, 'whisper');
    expect(
      AsrEngineChoice.fromStorage('qwen3Asr06Int8'),
      AsrEngineChoice.qwen3Asr06Int8,
    );
    expect(AsrEngineChoice.qwen3Asr06Int8.nativeEngine, 'qwen3Asr');
    expect(AsrEngineChoice.qwen3Asr17Float32.nativeEngine, 'qwen3Asr');
    expect(
      resolveAsrEngine(
        AsrEngineChoice.qwen3Asr17Float32,
        largeTextModelMinBytes - 1,
      ),
      AsrEngineChoice.senseVoice,
    );
    expect(
      resolveAsrEngine(
        AsrEngineChoice.qwen3Asr17Float32,
        largeTextModelMinBytes,
      ),
      AsrEngineChoice.qwen3Asr17Float32,
    );
    expect(
      resolveAsrEngine(
        AsrEngineChoice.qwen3Asr06Float32,
        largeTextModelMinBytes - 1,
      ),
      AsrEngineChoice.qwen3Asr06Float32,
    );
    expect(
      resolveAsrEngine(
        AsrEngineChoice.qwen3Asr17Int8,
        largeTextModelMinBytes - 1,
      ),
      AsrEngineChoice.qwen3Asr17Int8,
    );
  });

  testWidgets('shell can be constructed without the product app wrapper', (
    tester,
  ) async {
    await show(
      tester,
      MaterialApp(
        home: AppScope(
          settings: MemorySettingsStore(),
          models: ModelManager(
            catalog: ModelCatalog.parse(
              File('models/manifest.json').readAsStringSync(),
            ),
            root: root,
            transport: _IdleTransport(),
            network: _OfflineGate(),
          ),
          translator: _UnusedEngine(),
          ocr: _SilentOcr(),
          photos: _EmptyPhotos(),
          speech: _QuietSpeech(),
          voice: _IdleVoice(),
          asr: _MissingAsr(),
          importPicker: () async => null,
          child: HomeShell(settings: MemorySettingsStore()),
        ),
      ),
    );
    expect(find.text('GPTAnywhere'), findsOneWidget);
  });

  testWidgets('interface language defaults to English and can switch', (
    tester,
  ) async {
    final store = MemorySettingsStore();
    await show(tester, harness(store));

    expect((await store.load()).interfaceLanguage, InterfaceLanguage.english);
    expect(find.text('GPTAnywhere'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('English'), findsWidgets);

    await tester.tap(find.text('Language'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Interface language'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);

    await tester.tap(find.text('简体中文'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect((await store.load()).interfaceLanguage, InterfaceLanguage.zhHans);
    expect(find.text('界面语言'), findsOneWidget);

    Navigator.of(tester.element(find.text('界面语言'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('设置'), findsWidgets);
    expect(find.text('语言'), findsOneWidget);

    Navigator.of(tester.element(find.text('语言'))).pop();
    await tester.pump();
    expect(find.text('GPTAnywhere'), findsOneWidget);
    expect(find.text('文字'), findsWidgets);
  });

  testWidgets('a missing model opens its settings page', (tester) async {
    await show(tester, harness(MemorySettingsStore()));

    expect(find.text('The model is not ready.'), findsOneWidget);
    expect(find.text('Import'), findsNothing);
    expect(find.textContaining('Current model'), findsNothing);

    await tester.tap(find.byKey(const Key('chat-text-download')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Text models'), findsOneWidget);
  });

  testWidgets('a missing speech model opens speech models', (tester) async {
    await show(tester, harness(MemorySettingsStore()));

    await tester.tap(find.text('Voice'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('The model is not ready.'), findsOneWidget);
    expect(find.textContaining('Current model'), findsNothing);

    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Speech models'), findsOneWidget);
  });
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

class _EmptyPhotos implements PhotoSource {
  @override
  Future<Uint8List?> pickFromGallery() async => null;

  @override
  Future<Uint8List?> takePicture() async => null;
}

class _SilentOcr implements OcrEngine {
  @override
  Future<void> dispose() async {}

  @override
  Future<OcrDocument> recognize(Uint8List image, String script) {
    throw const AppFailure(AppErrorType.noText);
  }
}

class _OfflineGate implements NetworkGate {
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
  }) async {
    return TransportResult.paused;
  }
}

class _UnusedEngine implements TranslationEngine {
  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    throw AppFailure(AppErrorType.modelMissing);
  }
}
