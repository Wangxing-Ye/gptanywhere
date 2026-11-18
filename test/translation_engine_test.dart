import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptanywhere/domain/engines.dart';
import 'package:gptanywhere/services/llama_cli_output.dart';
import 'package:gptanywhere/services/llama_translation_engine.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';
import 'package:gptanywhere/domain/translation_language.dart';
import 'package:gptanywhere/services/translation_prompts.dart';

void main() {
  test('chat transcript keeps the generated line', () {
    const raw = '''
build      : b1-29c720e
using custom system prompt

> 今天下午三点不见，不是五点。
Today at 3 o'clock PM, not at 5 o'clock PM.

[ Prompt: 13.3 t/s | Generation: 8.9 t/s ]

Exiting...
''';
    expect(
      parseLlamaCliOutput(raw, '今天下午三点不见，不是五点。'),
      "Today at 3 o'clock PM, not at 5 o'clock PM.",
    );
  });

  test('an unfinished banner is not shown and a cut echo is removed', () {
    const prompt = '你好 在美国，想去海南 ，是面签的吗';
    expect(parseLlamaCliOutput('mod', prompt), '');
    expect(
      parseLlamaCliOutput(
        'model      : qwen\n> $prompt\nHello. To go to Hainan.',
        prompt,
      ),
      '',
    );
    expect(
      parseLlamaCliOutput(
        'model      : qwen\n> $prompt\nHello. To go to Hainan.',
        prompt,
        finished: true,
      ),
      'Hello. To go to Hainan.',
    );
    expect(
      parseLlamaCliOutput(
        'mod> 你好 在美国，想去海南 ，是Hello. To go to Hainan in the United States, is a visa required?',
        prompt,
        finished: true,
      ),
      'Hello. To go to Hainan in the United States, is a visa required?',
    );
  });

  test('plain subprocess output is kept', () {
    expect(
      parseLlamaCliOutput(
        '火车在15:00时不发车。\n',
        'The train does not leave at 15:00.',
      ),
      '火车在15:00时不发车。',
    );
  });

  test('each translation language is named in the system prompt', () {
    expect(translationSystemPrompt('zh-Hant'), contains('Traditional Chinese'));
    expect(translationSystemPrompt('ja'), contains('Japanese'));
    expect(() => translationSystemPrompt('en-GB'), throwsA(isA<AppFailure>()));
    for (final language in TranslationLanguage.values) {
      expect(
        translationSystemPrompt(language.code),
        contains(language.promptName),
      );
    }
    expect(() => translationSystemPrompt('yue'), throwsA(isA<AppFailure>()));
  });

  test('a language pair translates into the other writing system', () {
    expect(translationTargetCode('zh-Hans', 'en', '今天天气真好'), 'en');
    expect(
      translationTargetCode('zh-Hans', 'en', 'the weather is good. today'),
      'zh-Hans',
    );
    expect(translationTargetCode('en', 'zh-Hans', '今天天气真好'), 'en');
    expect(translationTargetCode('zh-Hans', 'en', '15:00'), 'en');
    expect(translationTargetCode('zh-Hans', 'en', 'Hi 你好'), 'en');
    expect(translationTargetCode('en', 'fr', 'bonjour'), 'fr');
    expect(translationTargetCode('zh-Hans', 'zh-Hant', '今天天气真好'), 'zh-Hant');
    expect(
      translationSystemPrompt(
        translationTargetCode('zh-Hans', 'en', 'the weather is good. today'),
      ),
      'Translate the user text into Simplified Chinese. '
      'Output only the translation.',
    );
  });

  test('photo and voice source menus follow the recognizer', () {
    expect(TranslationLanguage.photoSources.map((language) => language.code), [
      'en',
      'zh-Hans',
      'zh-Hant',
      'nl',
      'fr',
      'de',
      'hi',
      'id',
      'it',
      'ja',
      'ko',
      'pl',
      'pt',
      'es',
      'tr',
      'vi',
    ]);
    expect(
      TranslationLanguage.senseVoiceSources.map((language) => language.code),
      ['zh-Hans', 'zh-Hant', 'en', 'ja', 'ko'],
    );
  });

  test('cancel drops a late chunk and the next task stays separate', () async {
    final manager = await _readyManager();
    final runner = _HoldingRunner();
    final engine = LlamaTranslationEngine(models: manager, runner: runner);
    const firstId = 'task-1';
    final collected = <TranslationEvent>[];
    final subscription = engine
        .translate(
          const TranslationRequest(
            taskId: firstId,
            source: 'zh-Hans',
            target: 'en',
            text: '今天下午三点不见，不是五点。',
            tokenBudget: 32,
            modelVersion: ModelCatalog.primaryTextModelId,
          ),
        )
        .listen(collected.add);
    await runner.waitUntilStarted(firstId);
    runner.add(firstId, 'Today');
    await Future<void>.delayed(Duration.zero);
    await engine.cancel(firstId);
    runner.add(firstId, ' LEAKED');
    await subscription.cancel();

    const secondId = 'task-2';
    final secondFuture = engine
        .translate(
          const TranslationRequest(
            taskId: secondId,
            source: 'en',
            target: 'zh-Hans',
            text: 'The train does not leave at 15:00.',
            tokenBudget: 32,
            modelVersion: ModelCatalog.primaryTextModelId,
          ),
        )
        .toList();
    await runner.waitUntilStarted(secondId);
    runner.add(secondId, '火车没有在15点离开。');
    await runner.controllers[secondId]!.close();
    final second = await secondFuture;

    expect(
      collected.map((event) => event.delta).join(),
      isNot(contains('LEAKED')),
    );
    expect(second.map((event) => event.delta).join(), contains('火车没有在15点离开。'));
    expect(runner.systemPrompts[secondId], contains('Simplified Chinese'));
    expect(runner.cancelled, contains(firstId));
    expect(runner.thinking[firstId], isFalse);
  });

  test('a request names its own model and thinking flag', () async {
    final manager = await _readyManager();
    final runner = _HoldingRunner();
    final engine = LlamaTranslationEngine(models: manager, runner: runner);
    expect(
      engine
          .translate(
            const TranslationRequest(
              taskId: 'other',
              source: 'en',
              target: 'zh-Hans',
              text: 'hello',
              tokenBudget: 8,
              modelVersion: 'qwen3.5-2b-q4-k-m',
              thinking: true,
            ),
          )
          .toList(),
      throwsA(isA<AppFailure>()),
    );
    const id = 'same';
    final future = engine
        .translate(
          const TranslationRequest(
            taskId: id,
            source: 'en',
            target: 'zh-Hans',
            text: 'hello',
            tokenBudget: 8,
            modelVersion: ModelCatalog.primaryTextModelId,
            thinking: true,
          ),
        )
        .toList();
    await runner.waitUntilStarted(id);
    await runner.controllers[id]!.close();
    await future;
    expect(runner.thinking[id], isTrue);
  });

  test('an installed Gemma model is the file sent to the runner', () async {
    const modelId = 'gemma-3-4b-it-q4-k-m';
    final root = await Directory.systemTemp.createTemp('ta_gemma');
    const payload = [4, 3, 2, 1];
    final digest = sha256.convert(payload).toString();
    final file = File('${root.path}/$modelId.gguf');
    await file.writeAsBytes(payload);
    await File('${file.path}.sha256').writeAsString(digest);
    final manager = ModelManager(
      catalog: ModelCatalog({
        modelId: CatalogPackage(
          id: modelId,
          sizeBytes: payload.length,
          sha256: digest,
          downloadUrl: 'http://127.0.0.1/gemma.gguf',
          capabilities: const ['text_translation'],
        ),
      }),
      root: root,
      transport: _UnusedTransport(),
      network: _Offline(),
    );
    final runner = _HoldingRunner();
    final engine = LlamaTranslationEngine(models: manager, runner: runner);
    const taskId = 'gemma';
    final future = engine
        .translate(
          const TranslationRequest(
            taskId: taskId,
            source: 'zh-Hans',
            target: 'en',
            text: '你好',
            tokenBudget: 8,
            modelVersion: modelId,
          ),
        )
        .toList();
    await runner.waitUntilStarted(taskId);
    await runner.controllers[taskId]!.close();
    await future;
    expect(runner.paths[taskId], file.path);
    expect(runner.thinking[taskId], isFalse);
    expect(runner.systemPrompts[taskId], contains('English'));
    await root.delete(recursive: true);
  });
}

Future<ModelManager> _readyManager() async {
  final root = await Directory.systemTemp.createTemp('ta_ready');
  const payload = [9, 8, 7, 6];
  final digest = sha256.convert(payload).toString();
  final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
  await file.writeAsBytes(payload);
  await File('${file.path}.sha256').writeAsString(digest);
  return ModelManager(
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
  );
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

class _HoldingRunner implements LlamaRunner {
  final controllers = <String, StreamController<String>>{};
  final started = <String, Completer<void>>{};
  final systemPrompts = <String, String>{};
  final cancelled = <String>[];

  final thinking = <String, bool>{};
  final paths = <String, String>{};

  Future<void> waitUntilStarted(String taskId) {
    return started.putIfAbsent(taskId, Completer<void>.new).future;
  }

  void add(String taskId, String chunk) {
    final controller = controllers[taskId];
    if (controller == null || controller.isClosed) return;
    controller.add(chunk);
  }

  @override
  Stream<String> run({
    required String taskId,
    required String modelPath,
    required String systemPrompt,
    required String prompt,
    required int maxTokens,
    required bool thinking,
    List<String> imagePaths = const [],
    String? visionPath,
    int imageMaxTokens = 0,
  }) {
    systemPrompts[taskId] = systemPrompt;
    this.thinking[taskId] = thinking;
    paths[taskId] = modelPath;
    final controller = StreamController<String>();
    controllers[taskId] = controller;
    started.putIfAbsent(taskId, Completer<void>.new).complete();
    return controller.stream;
  }

  @override
  Future<void> cancel(String taskId) async {
    cancelled.add(taskId);
    final controller = controllers[taskId];
    if (controller != null && !controller.isClosed) {
      controller.close();
    }
  }
}
