import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptanywhere/domain/engines.dart';
import 'package:gptanywhere/services/chat_prompts.dart';
import 'package:gptanywhere/services/llama_chat_engine.dart';
import 'package:gptanywhere/services/llama_cli_output.dart';
import 'package:gptanywhere/services/llama_translation_engine.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';

void main() {
  test('program marks and command text are left out of the reply', () {
    const raw = '''
\uFFFD\uFFFD \u25A0\u25A0Hello! How can I assist you today?

/regen regenerate the last response
/clear clear the chat history
/read <file> add a text file
/glob <pattern> add text files using globbing
pattern
Knowpia announces the token.
(truncated)
△△△△
<|im_end|>
''';
    expect(
      parseLlamaCliOutput(raw, 'hello'),
      'Hello! How can I assist you today?\nKnowpia announces the token.',
    );
    expect(
      parseLlamaCliOutput(
        '<think>\n\n</think>\n我今年18岁。',
        '你今年多大了',
        finished: true,
      ),
      '我今年18岁。',
    );
  });

  test('a truncated prompt echo is not part of the reply', () {
    const prompt = '''
User: what is his name
Assistant: 他的名字是Gary Winow。
User: no. it is jensen huang
''';
    expect(
      parseLlamaCliOutput(
        'Assistant: 他的名字是Gary W抱歉，我之前回答错了。正确的名字是 Jensen Huang。',
        prompt,
        finished: true,
      ),
      '抱歉，我之前回答错了。正确的名字是 Jensen Huang。',
    );
    expect(
      parseLlamaCliOutput(
        'Assistant: 他的名字是Gary WUser: ...\n(truncated)\n好的，宫保鸡丁是一道经典的中式菜肴。',
        prompt,
        finished: true,
      ),
      '好的，宫保鸡丁是一道经典的中式菜肴。',
    );
  });

  test('a truncated content line is left out of the reply', () {
    const prompt = '''
Assistant: - 二 (èr)
- 八 (bā)
- 十 (shí)
User: 那中国小学二年级有多少词汇呢
''';
    expect(
      parseLlamaCliOutput(
        '- 八 (b ...\n中国小学二年级通常会学习大约300-400个中文词汇。',
        prompt,
        finished: true,
      ),
      '中国小学二年级通常会学习大约300-400个中文词汇。',
    );
    expect(
      parseLlamaCliOutput('请看这里...', 'hello', finished: true),
      '请看这里...',
    );
  });

  test('a multiline prompt echo is not returned as the reply', () {
    const prompt = 'User: hello\nAssistant: hi\nUser: next';
    const raw = '''
> User: hello
Assistant: hi
User: next
Here is the reply.

Exiting...
''';
    expect(parseLlamaCliOutput(raw, prompt), 'Here is the reply.');
  });

  test('older turns are dropped before the reply budget', () {
    final turns = [
      for (var i = 0; i < 40; i++)
        ChatTurn(
          role: i.isEven ? ChatRole.user : ChatRole.assistant,
          text: '第$i轮${'词' * 180}',
        ),
    ];
    final prompt = chatUserPrompt(turns);
    expect(prompt, isNot(contains(turns.first.text)));
    expect(prompt, contains(turns.last.text));
    expect(prompt, endsWith('Assistant: ${turns.last.text}'));
  });

  test('the latest turns stay in order', () {
    const turns = [
      ChatTurn(role: ChatRole.user, text: 'one'),
      ChatTurn(role: ChatRole.assistant, text: 'A'),
      ChatTurn(role: ChatRole.user, text: 'two'),
    ];
    expect(chatUserPrompt(turns), 'User: one\nAssistant: A\nUser: two');
  });

  test(
    'cancel drops a late chunk and the prompt is not a translation',
    () async {
      final root = await Directory.systemTemp.createTemp('ta_chat_engine');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      const payload = [9, 8, 7, 6];
      final digest = sha256.convert(payload).toString();
      final file = File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');
      await file.writeAsBytes(payload);
      await File('${file.path}.sha256').writeAsString(digest);
      final manager = ModelManager(
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
      final runner = _HoldingRunner();
      final engine = LlamaChatEngine(models: manager, runner: runner);
      const turns = [
        ChatTurn(role: ChatRole.user, text: 'one'),
        ChatTurn(role: ChatRole.assistant, text: 'A'),
        ChatTurn(role: ChatRole.user, text: 'two'),
      ];
      final collected = <ChatEvent>[];
      final subscription = engine
          .reply(
            const ChatRequest(
              taskId: 'task-1',
              messages: turns,
              tokenBudget: chatReplyTokenBudget,
              modelVersion: ModelCatalog.primaryTextModelId,
            ),
          )
          .listen(collected.add);
      await runner.waitUntilStarted('task-1');
      runner.add('task-1', 'Hello');
      await Future<void>.delayed(Duration.zero);
      await engine.cancel('task-1');
      runner.add('task-1', ' LEAKED');
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(
        collected.map((event) => event.delta).join(),
        isNot(contains('LEAKED')),
      );
      expect(runner.systemPrompts['task-1'], chatSystemPrompt());
      expect(
        runner.systemPrompts['task-1'],
        isNot(contains('Translate the user')),
      );
      expect(runner.prompts['task-1'], contains('User: one'));
      expect(runner.prompts['task-1'], contains('Assistant: A'));
      expect(runner.prompts['task-1'], contains('User: two'));
      expect(runner.maxTokens['task-1'], chatReplyTokenBudget);
      expect(runner.imagePaths['task-1'], isEmpty);
      expect(runner.visionPaths['task-1'], isNull);
      expect(runner.cancelled, contains('task-1'));
    },
  );

  test('a media load line is not part of the reply', () {
    expect(
      parseLlamaCliOutput(
        "Loaded media from '/tmp/image-0.jpg'\nThe label says paid.",
        'User: ',
        finished: true,
      ),
      'The label says paid.',
    );
  });

  test('an image is passed with that model\'s vision file', () async {
    final root = await Directory.systemTemp.createTemp('ta_chat_vision');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final manager = await _visionManager(root);
    final runner = _HoldingRunner();
    final engine = LlamaChatEngine(models: manager, runner: runner);
    const image = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4];
    final subscription = engine
        .reply(
          ChatRequest(
            taskId: 'task-1',
            messages: [
              ChatTurn(
                role: ChatRole.user,
                text: '',
                image: Uint8List.fromList(image),
              ),
            ],
            tokenBudget: chatReplyTokenBudget,
            modelVersion: 'qwen3.5-2b-q4-k-m',
          ),
        )
        .listen((_) {});
    await runner.waitUntilStarted('task-1');
    final imagePath = runner.imagePaths['task-1']!.single;
    expect(File(imagePath).readAsBytesSync(), image);
    expect(imagePath, endsWith('.png'));
    expect(runner.visionPaths['task-1'], endsWith('qwen3.5-2b-q4-k-m.mmproj.gguf'));
    expect(runner.imageMaxTokens['task-1'], chatImageTokenReserve);
    expect(runner.prompts['task-1'], 'User: ');
    await runner.controllers['task-1']!.close();
    await subscription.asFuture<void>();
    expect(File(imagePath).existsSync(), isFalse);
  });

  test('a missing vision file is not replaced by recognized text', () async {
    final root = await Directory.systemTemp.createTemp('ta_chat_vision_missing');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final manager = await _visionManager(root, writeVision: false);
    final runner = _HoldingRunner();
    final engine = LlamaChatEngine(models: manager, runner: runner);
    await expectLater(
      engine
          .reply(
            ChatRequest(
              taskId: 'task-1',
              messages: [
                ChatTurn(
                  role: ChatRole.user,
                  text: '',
                  image: Uint8List.fromList(const [1, 2, 3]),
                ),
              ],
              tokenBudget: chatReplyTokenBudget,
              modelVersion: 'qwen3.5-2b-q4-k-m',
            ),
          )
          .drain<void>(),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.detail,
          'detail',
          contains('看图文件'),
        ),
      ),
    );
    expect(runner.started, isEmpty);
  });
}

Future<ModelManager> _visionManager(
  Directory root, {
  bool writeVision = true,
}) async {
  const id = 'qwen3.5-2b-q4-k-m';
  const language = [9, 8, 7, 6];
  const vision = [3, 3];
  final languageHash = sha256.convert(language).toString();
  final visionHash = sha256.convert(vision).toString();
  final file = File('${root.path}/$id.gguf');
  await file.writeAsBytes(language);
  await File('${file.path}.sha256').writeAsString(languageHash);
  if (writeVision) {
    final side = File('${root.path}/$id.mmproj.gguf');
    await side.writeAsBytes(vision);
    await File('${side.path}.sha256').writeAsString(visionHash);
  }
  return ModelManager(
    catalog: ModelCatalog({
      id: CatalogPackage(
        id: id,
        sizeBytes: language.length,
        sha256: languageHash,
        downloadUrl: 'http://127.0.0.1/language.gguf',
        capabilities: const ['text_translation'],
        vision: CatalogVision(
          fileName: '$id.mmproj.gguf',
          sizeBytes: vision.length,
          sha256: visionHash,
          downloadUrl: 'http://127.0.0.1/vision.gguf',
        ),
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
  final prompts = <String, String>{};
  final maxTokens = <String, int>{};
  final imagePaths = <String, List<String>>{};
  final visionPaths = <String, String?>{};
  final imageMaxTokens = <String, int>{};
  final cancelled = <String>[];

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
    prompts[taskId] = prompt;
    this.maxTokens[taskId] = maxTokens;
    this.imagePaths[taskId] = imagePaths;
    visionPaths[taskId] = visionPath;
    this.imageMaxTokens[taskId] = imageMaxTokens;
    final controller = StreamController<String>();
    controllers[taskId] = controller;
    started.putIfAbsent(taskId, Completer<void>.new).complete();
    return controller.stream;
  }

  @override
  Future<void> cancel(String taskId) async {
    cancelled.add(taskId);
  }
}
