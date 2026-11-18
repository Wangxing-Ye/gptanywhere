import '../domain/engines.dart';
import 'llama_cli_output.dart';
import 'model_manager.dart';
import 'translation_prompts.dart';

abstract class LlamaRunner {
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
  });

  Future<void> cancel(String taskId);
}

class LlamaTranslationEngine implements TranslationEngine {
  LlamaTranslationEngine({required this.models, required this.runner});

  final ModelManager models;
  final LlamaRunner runner;
  String? _active;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    final installed = await models.installed(request.modelVersion);
    if (installed == null) {
      throw AppFailure(AppErrorType.modelMissing);
    }
    final systemPrompt = translationSystemPrompt(
      translationTargetCode(request.source, request.target, request.text),
    );
    _active = request.taskId;
    final buffer = StringBuffer();
    var shown = '';
    try {
      await for (final piece in runner.run(
        taskId: request.taskId,
        modelPath: installed.path,
        systemPrompt: systemPrompt,
        prompt: request.text,
        maxTokens: request.tokenBudget,
        thinking: request.thinking,
      )) {
        if (_active != request.taskId) return;
        buffer.write(piece);
        final parsed = parseLlamaCliOutput(buffer.toString(), request.text);
        if (!parsed.startsWith(shown)) shown = '';
        final delta = parsed.substring(shown.length);
        shown = parsed;
        if (delta.isEmpty) continue;
        yield TranslationEvent(
          taskId: request.taskId,
          delta: delta,
          text: parsed,
          isFinal: false,
        );
      }
    } catch (error) {
      if (_active != request.taskId) return;
      if (error is AppFailure) rethrow;
      throw AppFailure(AppErrorType.modelLoadFailed, detail: error.toString());
    }
    if (_active != request.taskId) return;
    final parsed = parseLlamaCliOutput(
      buffer.toString(),
      request.text,
      finished: true,
    );
    if (!parsed.startsWith(shown)) shown = '';
    final delta = parsed.substring(shown.length);
    shown = parsed;
    yield TranslationEvent(
      taskId: request.taskId,
      delta: delta,
      text: parsed,
      isFinal: true,
    );
  }

  @override
  Future<void> cancel(String taskId) async {
    if (_active == taskId) _active = null;
    await runner.cancel(taskId);
  }

  @override
  Future<void> dispose() async {
    final taskId = _active;
    _active = null;
    if (taskId != null) await runner.cancel(taskId);
  }
}
