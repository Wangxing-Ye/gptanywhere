import 'dart:typed_data';

import 'app_error.dart';

export 'app_error.dart';

/// Domain contracts. Screens call these types only.

class GlossaryEntry {
  const GlossaryEntry({required this.source, required this.target});

  final String source;
  final String target;
}

class TranslationRequest {
  const TranslationRequest({
    required this.taskId,
    required this.source,
    required this.target,
    required this.text,
    required this.tokenBudget,
    required this.modelVersion,
    this.thinking = false,
    this.glossary = const [],
  });

  final String taskId;
  final String source;
  final String target;
  final String text;
  final List<GlossaryEntry> glossary;
  final int tokenBudget;
  final String modelVersion;
  final bool thinking;
}

class TranslationEvent {
  const TranslationEvent({
    required this.taskId,
    required this.delta,
    required this.isFinal,
    this.text = '',
  });

  final String taskId;
  final String delta;

  /// Translation parsed so far. Pages replace the previous text with this.
  final String text;
  final bool isFinal;
}

abstract class TranslationEngine {
  Stream<TranslationEvent> translate(TranslationRequest request);
  Future<void> cancel(String taskId);
  Future<void> dispose();
}

enum ChatRole { user, assistant }

class ChatTurn {
  const ChatTurn({required this.role, required this.text, this.image});

  final ChatRole role;
  final String text;
  final Uint8List? image;
}

class ChatRequest {
  const ChatRequest({
    required this.taskId,
    required this.messages,
    required this.tokenBudget,
    required this.modelVersion,
    this.thinking = false,
  });

  final String taskId;
  final List<ChatTurn> messages;
  final int tokenBudget;
  final String modelVersion;
  final bool thinking;
}

class ChatEvent {
  const ChatEvent({
    required this.taskId,
    required this.delta,
    required this.isFinal,
    this.text = '',
  });

  final String taskId;
  final String delta;

  /// Reply parsed so far. The page replaces the previous text with this.
  final String text;
  final bool isFinal;
}

abstract class ChatEngine {
  Stream<ChatEvent> reply(ChatRequest request);
  Future<void> cancel(String taskId);
  Future<void> dispose();
}

class UnavailableChatEngine implements ChatEngine {
  const UnavailableChatEngine();

  @override
  Stream<ChatEvent> reply(ChatRequest request) async* {
    throw const AppFailure(AppErrorType.modelMissing);
  }

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> dispose() async {}
}

class OcrBlock {
  const OcrBlock({
    required this.id,
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String id;
  final String text;

  /// Bounds normalized to 0–1 in the upright image.
  final double left;
  final double top;
  final double right;
  final double bottom;
}

class OcrDocument {
  const OcrDocument({required this.blocks, required this.readingOrder});

  final List<OcrBlock> blocks;
  final List<String> readingOrder;

  String get plainText {
    final byId = {for (final block in blocks) block.id: block.text};
    return [
      for (final id in readingOrder)
        if (byId[id] != null) byId[id]!,
    ].join('\n');
  }
}

abstract class OcrEngine {
  /// [script] is a writing system id such as `latin` or `chinese`.
  /// LLM language support must not be passed here as if it were OCR support.
  Future<OcrDocument> recognize(Uint8List image, String script);
  Future<void> dispose();
}

class SpeechSegment {
  const SpeechSegment({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.isFinal,
  });

  final int startMs;
  final int endMs;
  final String text;
  final bool isFinal;
}

class SpeechRequest {
  const SpeechRequest({
    required this.taskId,
    required this.wavPath,
    required this.language,
    required this.engineName,
    required this.modelPath,
    this.tokensPath,
    this.convPath,
    this.encoderPath,
    this.decoderPath,
    this.tokenizerPath,
  });

  final String taskId;
  final String wavPath;
  final String language;
  final String engineName;
  final String modelPath;
  final String? tokensPath;
  final String? convPath;
  final String? encoderPath;
  final String? decoderPath;
  final String? tokenizerPath;
}

abstract class SpeechEngine {
  Stream<SpeechSegment> transcribe(SpeechRequest request);
  Future<void> cancel(String taskId);
  Future<void> dispose();
}

abstract class SpeechSynthesizer {
  Future<Uint8List> synthesize(String text, String language, String voiceId);
  Future<void> dispose();
}
