import 'dart:io';
import 'dart:typed_data';

import '../domain/engines.dart';
import 'chat_prompts.dart';
import 'llama_cli_output.dart';
import 'llama_translation_engine.dart';
import 'model_manager.dart';

class LlamaChatEngine implements ChatEngine {
  LlamaChatEngine({required this.models, required this.runner});

  final ModelManager models;
  final LlamaRunner runner;
  String? _active;

  @override
  Stream<ChatEvent> reply(ChatRequest request) async* {
    final installed = await models.installed(request.modelVersion);
    if (installed == null) {
      throw const AppFailure(AppErrorType.modelMissing);
    }
    final kept = keptChatTurns(request.messages);
    final prompt = chatUserPrompt(request.messages);
    final images = [
      for (final turn in kept)
        if (turn.image != null) turn.image!,
    ];
    String? visionPath;
    if (images.isNotEmpty) {
      visionPath = await models.readyVisionPath(request.modelVersion);
      if (visionPath == null) {
        throw const AppFailure(
          AppErrorType.modelMissing,
          detail: '看图文件还没有准备好。',
        );
      }
    }
    _active = request.taskId;
    final buffer = StringBuffer();
    var shown = '';
    Directory? imageDir;
    try {
      final imagePaths = <String>[];
      if (images.isNotEmpty) {
        imageDir = await Directory.systemTemp.createTemp('ta_chat_image');
        for (var i = 0; i < images.length; i++) {
          final file = File(
            '${imageDir.path}${Platform.pathSeparator}image-$i${_imageSuffix(images[i])}',
          );
          await file.writeAsBytes(images[i], flush: true);
          imagePaths.add(file.path);
        }
      }
      await for (final piece in runner.run(
        taskId: request.taskId,
        modelPath: installed.path,
        systemPrompt: chatSystemPrompt(),
        prompt: prompt,
        maxTokens: request.tokenBudget,
        thinking: request.thinking,
        imagePaths: imagePaths,
        visionPath: visionPath,
        imageMaxTokens: images.isEmpty ? 0 : chatImageTokenReserve,
      )) {
        if (_active != request.taskId) return;
        buffer.write(piece);
        final parsed = parseLlamaCliOutput(buffer.toString(), prompt);
        if (!parsed.startsWith(shown)) shown = '';
        final delta = parsed.substring(shown.length);
        shown = parsed;
        if (delta.isEmpty) continue;
        yield ChatEvent(
          taskId: request.taskId,
          delta: delta,
          text: parsed,
          isFinal: false,
        );
      }
      if (_active != request.taskId) return;
      final parsed = parseLlamaCliOutput(
        buffer.toString(),
        prompt,
        finished: true,
      );
      if (!parsed.startsWith(shown)) shown = '';
      final delta = parsed.substring(shown.length);
      shown = parsed;
      yield ChatEvent(
        taskId: request.taskId,
        delta: delta,
        text: parsed,
        isFinal: true,
      );
    } catch (error) {
      if (_active != request.taskId) return;
      if (error is AppFailure) rethrow;
      throw AppFailure(AppErrorType.modelLoadFailed, detail: error.toString());
    } finally {
      final dir = imageDir;
      if (dir != null && dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
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

String _imageSuffix(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return '.png';
  }
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return '.jpg';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45) {
    return '.webp';
  }
  return '.img';
}
