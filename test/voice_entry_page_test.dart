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
import 'package:gptanywhere/domain/translation_language.dart';
import 'package:gptanywhere/domain/voice_capture.dart';
import 'package:gptanywhere/features/translate/voice_entry_page.dart';
import 'package:gptanywhere/services/asr_catalog.dart';
import 'package:gptanywhere/services/asr_models.dart';
import 'package:gptanywhere/services/asr_output.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';
import 'package:gptanywhere/services/wav_audio.dart';

void main() {
  test('sense voice json keeps spoken text and drops nospeech', () {
    const spoken =
        '{"lang":"zh","emotion":"NEUTRAL","event":"Speech","text":"车站","timestamps":[]}';
    expect(transcriptFromAsr(spoken, json: true), '车站');
    const quiet =
        '{"lang":"zh","emotion":"NEUTRAL","event":"nospeech","text":"没","timestamps":[]}';
    expect(transcriptFromAsr(quiet, json: true), isNull);
    expect(transcriptFromAsr('  the train  ', json: false), 'the train');
    expect(isEnglishOnlyAsrWeight('ggml-small.en.bin'), isTrue);
    expect(isEnglishOnlyAsrWeight('ggml-small.bin'), isFalse);
  });

  test('asr accepts only the SenseVoice language codes', () {
    expect(asrLanguageCode('zh-Hans'), 'zh');
    expect(asrLanguageCode('zh-Hant'), 'zh');
    expect(asrLanguageCode('en'), 'en');
    expect(asrLanguageCode('ja'), 'ja');
    expect(asrLanguageCode('ko'), 'ko');
    expect(() => asrLanguageCode('fr'), throwsA(isA<AppFailure>()));
    expect(() => asrLanguageCode('ar'), throwsA(isA<AppFailure>()));
    expect(asrLanguageCode('fr', engine: 'whisper'), 'fr');
    expect(asrLanguageCode('zh-Hant', engine: 'whisper'), 'zh');
    expect(asrLanguageCode('ar', engine: 'qwen3Asr'), 'ar');
    expect(
      () => asrLanguageCode('en-GB', engine: 'whisper'),
      throwsA(isA<AppFailure>()),
    );
  });

  test('digital silence is not sent to a model', () {
    final silent = wavFromPcm16(samples: Int16List(1600));
    final audible = wavFromPcm16(
      samples: Int16List.fromList(List.filled(1600, 2000)),
    );
    expect(wavIsSilent(silent), isTrue);
    expect(wavIsSilent(audible), isFalse);
  });

  test('catalog points SenseVoice at the onnx hash and whisper at the bin', () {
    final manifest = File('models/manifest.json').readAsStringSync();
    final sense = asrSpecFor(AsrEngineChoice.senseVoice, manifest);
    final whisper = asrSpecFor(AsrEngineChoice.whisperSmall, manifest);
    final medium = asrSpecFor(AsrEngineChoice.whisperMedium, manifest);
    expect(sense.archive, isTrue);
    expect(sense.sizeBytes, 937617178);
    expect(
      sense.sha256,
      '977016bd9c79f9eb343430b5cc305e07ab64d5212dff41b0dcfa1694bee9a8cb',
    );
    expect(whisper.archive, isFalse);
    expect(whisper.sizeBytes, 487601967);
    expect(medium.archive, isFalse);
    expect(medium.sizeBytes, 1533763059);
    expect(
      medium.sha256,
      '6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208',
    );
    expect(medium.payloadName, 'whisper-medium-multilingual.bin');
    expect(medium.downloadUrl, contains('ggml-medium.bin'));
    expect(medium.downloadUrl, isNot(contains('.en')));
    expect(isEnglishOnlyAsrWeight(medium.payloadName), isFalse);
    expect(isEnglishOnlyAsrWeight('ggml-medium.en.bin'), isTrue);

    final smallQwen = asrSpecFor(AsrEngineChoice.qwen3Asr06Int8, manifest);
    final floatQwen = asrSpecFor(AsrEngineChoice.qwen3Asr06Float32, manifest);
    final largeInt8 = asrSpecFor(AsrEngineChoice.qwen3Asr17Int8, manifest);
    final largeFloat = asrSpecFor(AsrEngineChoice.qwen3Asr17Float32, manifest);
    final tokenizer = asrTokenizerSpec(manifest);
    expect(smallQwen.archive, isFalse);
    expect(smallQwen.sizeBytes, 982554174);
    expect(smallQwen.files.map((file) => file.name), [
      'conv_frontend.onnx',
      'encoder.int8.onnx',
      'decoder.int8.onnx',
    ]);
    expect(
      floatQwen.files.map((file) => file.name),
      containsAll(['encoder.onnx', 'encoder.onnx.data', 'decoder.onnx.data']),
    );
    expect(largeInt8.sizeBytes, 2399761248);
    expect(largeFloat.sizeBytes, 9404125598);
    expect(tokenizer.files.map((file) => file.name), [
      'vocab.json',
      'merges.txt',
      'tokenizer_config.json',
    ]);
    for (final spec in [
      smallQwen,
      floatQwen,
      largeInt8,
      largeFloat,
      tokenizer,
    ]) {
      final sum = spec.files.fold<int>(
        0,
        (total, file) => total + file.sizeBytes,
      );
      expect(sum, spec.sizeBytes);
      expect(spec.files, isNotEmpty);
    }
  });

  test('a rejected qwen download keeps the previous files', () async {
    final root = Directory.systemTemp.createTempSync('ta_qwen_asr');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const oldBytes = [9, 8, 7, 6];
    const newBytes = [1, 2, 3, 4];
    const wanted = [7, 7, 7, 7];
    final oldDigest = sha256.convert(oldBytes).toString();
    final newDigest = sha256.convert(newBytes).toString();
    final wantedDigest = sha256.convert(wanted).toString();
    final modelDir = Directory('${root.path}/$qwen3Asr06Int8Id')..createSync();
    for (final name in const [
      'conv_frontend.onnx',
      'encoder.int8.onnx',
      'decoder.int8.onnx',
    ]) {
      File('${modelDir.path}/$name').writeAsBytesSync(oldBytes);
      File('${modelDir.path}/$name.sha256').writeAsStringSync(oldDigest);
    }
    final tokenDir = Directory('${root.path}/$qwen3AsrTokenizerId')
      ..createSync();
    for (final name in const [
      'vocab.json',
      'merges.txt',
      'tokenizer_config.json',
    ]) {
      File('${tokenDir.path}/$name').writeAsBytesSync(newBytes);
      File('${tokenDir.path}/$name.sha256').writeAsStringSync(newDigest);
    }
    final models = AsrModels(
      manifestJson: _qwenManifest(
        modelDigest: wantedDigest,
        tokenDigest: newDigest,
      ),
      root: root,
      transport: _WritesTransport(newBytes),
      network: _Online(),
      extractor: _BrokenExtractor(),
    );

    expect(
      models.download(AsrEngineChoice.qwen3Asr06Int8),
      throwsA(isA<AppFailure>()),
    );
    expect(
      File('${modelDir.path}/conv_frontend.onnx').readAsBytesSync(),
      oldBytes,
    );
    expect(
      Directory('${root.path}/$qwen3Asr06Int8Id.next').existsSync(),
      isFalse,
    );
    expect(File('${tokenDir.path}/vocab.json').readAsBytesSync(), newBytes);
  });

  test('an accepted qwen download keeps onnx and data names', () async {
    final root = Directory.systemTemp.createTempSync('ta_qwen_ok');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const bytes = [1, 2, 3, 4];
    final digest = sha256.convert(bytes).toString();
    final models = AsrModels(
      manifestJson: _qwenManifest(modelDigest: digest, tokenDigest: digest),
      root: root,
      transport: _WritesTransport(bytes),
      network: _Online(),
      extractor: _BrokenExtractor(),
    );

    final install = await models.download(AsrEngineChoice.qwen3Asr06Float32);
    expect(install.convPath, endsWith('/conv_frontend.onnx'));
    expect(install.encoderPath, endsWith('/encoder.onnx'));
    expect(install.decoderPath, endsWith('/decoder.onnx'));
    expect(install.tokenizerPath, endsWith('/$qwen3AsrTokenizerId'));
    expect(install.modelPath, install.convPath);
    expect(File('${install.encoderPath}.data').readAsBytesSync(), bytes);
    expect(File('${install.tokenizerPath}/vocab.json').existsSync(), isTrue);

    final again = await models.installed(AsrEngineChoice.qwen3Asr06Float32);
    expect(again?.encoderPath, install.encoderPath);
  });

  test('a failed extract keeps the previous sense voice files', () async {
    final root = Directory.systemTemp.createTempSync('ta_asr');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const payload = [9, 8, 7, 6];
    final digest = sha256.convert(payload).toString();
    final dir = Directory('${root.path}/$senseVoiceModelId')..createSync();
    File('${dir.path}/model.onnx').writeAsBytesSync(payload);
    File('${dir.path}/tokens.txt').writeAsStringSync('tokens');
    File('${dir.path}/model.sha256').writeAsStringSync(digest);
    final models = AsrModels(
      manifestJson:
          '{"packages":[{"id":"$senseVoiceModelId","capabilities":["asr"],"sizeBytes":4,"sha256":"$digest","downloadUrl":"http://127.0.0.1/sense.tar.bz2"}]}',
      root: root,
      transport: _WritesTransport(const [1, 2, 3, 4]),
      network: _Online(),
      extractor: _BrokenExtractor(),
    );

    expect(
      models.download(AsrEngineChoice.senseVoice),
      throwsA(isA<AppFailure>()),
    );
    expect(File('${dir.path}/model.onnx').readAsBytesSync(), payload);
    expect(File('${dir.path}/tokens.txt').readAsStringSync(), 'tokens');
  });

  testWidgets('imported speech is translated and silence is not invented', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('ta_voice');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const payload = [4, 5, 6, 7];
    final digest = sha256.convert(payload).toString();
    final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
    file.writeAsBytesSync(payload);
    File('${file.path}.sha256').writeAsStringSync(digest);
    final speech = _RecordingSpeech();
    final engine = _RecordingEngine();
    final audible = wavFromPcm16(
      samples: Int16List.fromList(List.filled(1600, 2000)),
    );

    await tester.pumpWidget(
      _page(
        root: root,
        digest: digest,
        payloadLength: payload.length,
        speech: speech,
        voice: _FixedVoice(audible),
        translator: engine,
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.tap(find.text('Choose audio'));
    await tester.pump();
    await tester.pump();

    expect(find.text('车站'), findsWidgets);
    expect(find.text('Station', skipOffstage: false), findsOneWidget);
    expect(engine.requests.single, '车站');
    expect(speech.calls, 1);
    expect(find.textContaining('今天下午三点'), findsNothing);

    await tester.showKeyboard(find.byKey(const Key('voice-recognized')));
    await tester.pump();
    expect(_voiceFocused(tester), isTrue);
    await tester.tap(find.text('Choose audio'));
    await tester.pump();
    await tester.pump();
    expect(_voiceFocused(tester), isFalse);

    speech.calls = 0;
    await tester.pumpWidget(
      _page(
        root: root,
        digest: digest,
        payloadLength: payload.length,
        speech: speech,
        voice: _FixedVoice(wavFromPcm16(samples: Int16List(1600))),
        translator: engine,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Choose audio'));
    await tester.pump();
    await tester.pump();

    expect(speech.calls, 0);
    expect(find.text('No speech was heard.'), findsOneWidget);
    expect(find.text('Station'), findsNothing);
  });

  testWidgets(
    'SenseVoice source menu is simplified, traditional, English, Japanese, Korean',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('ta_voice_sense_langs');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      const payload = [4, 5, 6, 7];
      final digest = sha256.convert(payload).toString();
      final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
      file.writeAsBytesSync(payload);
      File('${file.path}.sha256').writeAsStringSync(digest);

      await tester.pumpWidget(
        _page(
          root: root,
          digest: digest,
          payloadLength: payload.length,
          speech: _RecordingSpeech(),
          voice: _FixedVoice(Uint8List(0)),
          translator: _RecordingEngine(),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      final source = tester.widget<DropdownButton<TranslationLanguage>>(
        find.byType(DropdownButton<TranslationLanguage>).first,
      );
      expect(
        source.items!.map((item) => item.value),
        TranslationLanguage.senseVoiceSources,
      );
      expect(find.text('Current model: SenseVoice'), findsOneWidget);
    },
  );

  testWidgets('whisper medium is sent to whisper.cpp', (tester) async {
    final root = Directory.systemTemp.createTempSync('ta_voice_medium');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const payload = [4, 5, 6, 7];
    final digest = sha256.convert(payload).toString();
    final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
    file.writeAsBytesSync(payload);
    File('${file.path}.sha256').writeAsStringSync(digest);
    final speech = _RecordingSpeech();
    final asr = _ReadyAsr();
    final audible = wavFromPcm16(
      samples: Int16List.fromList(List.filled(1600, 2000)),
    );

    await tester.pumpWidget(
      _page(
        root: root,
        digest: digest,
        payloadLength: payload.length,
        speech: speech,
        voice: _FixedVoice(audible),
        translator: _RecordingEngine(),
        settings: const AppSettings(asrEngine: AsrEngineChoice.whisperMedium),
        asr: asr,
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('Current model: Whisper-medium'), findsOneWidget);
    final source = tester.widget<DropdownButton<TranslationLanguage>>(
      find.byType(DropdownButton<TranslationLanguage>).first,
    );
    expect(source.items!.map((item) => item.value), TranslationLanguage.values);
    expect(asr.seen, contains(AsrEngineChoice.whisperMedium));

    await tester.tap(find.text('Choose audio'));
    await tester.pump();
    await tester.pump();

    expect(speech.last?.engineName, 'whisper');
    expect(speech.last?.modelPath, '/tmp/whisperMedium.bin');
  });

  testWidgets('qwen3 asr sends the sherpa file paths', (tester) async {
    final root = Directory.systemTemp.createTempSync('ta_voice_qwen');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    const payload = [4, 5, 6, 7];
    final digest = sha256.convert(payload).toString();
    final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
    file.writeAsBytesSync(payload);
    File('${file.path}.sha256').writeAsStringSync(digest);
    final speech = _RecordingSpeech();
    final audible = wavFromPcm16(
      samples: Int16List.fromList(List.filled(1600, 2000)),
    );

    await tester.pumpWidget(
      _page(
        root: root,
        digest: digest,
        payloadLength: payload.length,
        speech: speech,
        voice: _FixedVoice(audible),
        translator: _RecordingEngine(),
        settings: const AppSettings(asrEngine: AsrEngineChoice.qwen3Asr06Int8),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('Current model: Qwen3-ASR 0.6B int8'), findsOneWidget);

    await tester.tap(find.text('Choose audio'));
    await tester.pump();
    await tester.pump();

    expect(speech.last?.engineName, 'qwen3Asr');
    expect(speech.last?.convPath, '/tmp/qwen/conv_frontend.onnx');
    expect(speech.last?.encoderPath, '/tmp/qwen/encoder.int8.onnx');
    expect(speech.last?.decoderPath, '/tmp/qwen/decoder.int8.onnx');
    expect(speech.last?.tokenizerPath, '/tmp/qwen3-asr-tokenizer');
    expect(speech.last?.modelPath, speech.last?.convPath);
  });
}

String _qwenManifest({
  required String modelDigest,
  required String tokenDigest,
}) {
  String file(String name, String digest) {
    return '{"name":"$name","sizeBytes":4,"sha256":"$digest","downloadUrl":"http://127.0.0.1/$name"}';
  }

  String pack(String id, List<String> names, String digest, int size) {
    final files = names.map((name) => file(name, digest)).join(',');
    return '{"id":"$id","capabilities":["asr"],"sizeBytes":$size,"sha256":"$digest","downloadUrl":"http://127.0.0.1/$id","files":[$files]}';
  }

  return '''
{"packages":[
  ${pack(qwen3Asr06Int8Id, ['conv_frontend.onnx', 'encoder.int8.onnx', 'decoder.int8.onnx'], modelDigest, 12)},
  ${pack(qwen3Asr06Float32Id, ['conv_frontend.onnx', 'encoder.onnx', 'encoder.onnx.data', 'decoder.onnx', 'decoder.onnx.data'], modelDigest, 20)},
  ${pack(qwen3AsrTokenizerId, ['vocab.json', 'merges.txt', 'tokenizer_config.json'], tokenDigest, 12)}
]}''';
}

bool _voiceFocused(WidgetTester tester) {
  return tester
      .state<EditableTextState>(find.byType(EditableText))
      .widget
      .focusNode
      .hasFocus;
}

Widget _page({
  required Directory root,
  required String digest,
  required int payloadLength,
  required SpeechEngine speech,
  required VoiceCapture voice,
  required TranslationEngine translator,
  AppSettings settings = AppSettings.defaults,
  AsrStore? asr,
}) {
  return MaterialApp(
    home: Scaffold(
      body: AppScope(
        settings: MemorySettingsStore(initial: settings),
        models: ModelManager(
          catalog: ModelCatalog({
            ModelCatalog.primaryTextModelId: CatalogPackage(
              id: ModelCatalog.primaryTextModelId,
              sizeBytes: payloadLength,
              sha256: digest,
              downloadUrl: 'http://127.0.0.1/model.gguf',
              capabilities: const ['text_translation'],
            ),
          }),
          root: root,
          transport: _WritesTransport(const []),
          network: _Online(),
        ),
        translator: translator,
        ocr: _UnusedOcr(),
        photos: _UnusedPhotos(),
        speech: speech,
        voice: voice,
        asr: asr ?? _ReadyAsr(),
        importPicker: () async => null,
        child: const VoiceEntryPage(),
      ),
    ),
  );
}

class _Online implements NetworkGate {
  @override
  Future<bool> isOnline({Uri? target}) async => true;
}

class _WritesTransport implements ModelTransport {
  _WritesTransport(this.bytes);
  final List<int> bytes;

  @override
  Future<TransportResult> fetch({
    required Uri url,
    required File partial,
    required bool Function() shouldPause,
    required void Function(int received, {int? total}) onProgress,
  }) async {
    await partial.writeAsBytes(bytes);
    onProgress(bytes.length);
    return TransportResult.completed;
  }
}

class _BrokenExtractor implements TarExtractor {
  @override
  Future<void> extractNamed({
    required File archive,
    required Directory destination,
    required Set<String> names,
    int? expectedBytes,
    void Function(int written)? onProgress,
  }) async {
    throw const AppFailure(AppErrorType.fileCorrupt);
  }
}

class _ReadyAsr implements AsrStore {
  final seen = <AsrEngineChoice>[];

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
    seen.add(engine);
    final qwen = engine.nativeEngine == 'qwen3Asr';
    return AsrInstall(
      engine: engine,
      modelPath: qwen
          ? '/tmp/qwen/conv_frontend.onnx'
          : '/tmp/${engine.storageValue}.bin',
      tokensPath: qwen ? null : '/tmp/tokens.txt',
      convPath: qwen ? '/tmp/qwen/conv_frontend.onnx' : null,
      encoderPath: qwen ? '/tmp/qwen/encoder.int8.onnx' : null,
      decoderPath: qwen ? '/tmp/qwen/decoder.int8.onnx' : null,
      tokenizerPath: qwen ? '/tmp/qwen3-asr-tokenizer' : null,
    );
  }
}

class _FixedVoice implements VoiceCapture {
  _FixedVoice(this.wav);
  final Uint8List wav;

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
  Future<void> play(Uint8List wav) async {}

  @override
  Future<void> stopPlayback() async {}
}

class _RecordingSpeech implements SpeechEngine {
  var calls = 0;
  SpeechRequest? last;

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<SpeechSegment> transcribe(SpeechRequest request) async* {
    calls++;
    last = request;
    yield const SpeechSegment(startMs: 0, endMs: 0, text: '车站', isFinal: true);
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
