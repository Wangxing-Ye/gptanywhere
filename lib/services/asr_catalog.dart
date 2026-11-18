import 'dart:convert';

import '../domain/app_error.dart';
import '../domain/app_settings.dart';

class AsrFile {
  const AsrFile({
    required this.name,
    required this.sizeBytes,
    required this.sha256,
    required this.downloadUrl,
  });

  final String name;
  final int sizeBytes;
  final String sha256;
  final String downloadUrl;
}

class AsrSpec {
  const AsrSpec({
    required this.id,
    required this.sizeBytes,
    required this.sha256,
    required this.downloadUrl,
    required this.archive,
    this.files = const [],
  });

  final String id;
  final int sizeBytes;
  final String sha256;
  final String downloadUrl;

  /// SenseVoice is published as a tar.bz2. The catalog hash is the onnx file.
  final bool archive;

  /// Qwen3-ASR is several ONNX files. Empty for the single-file engines.
  final List<AsrFile> files;

  String get payloadName => archive ? 'model.onnx' : '$id.bin';
}

const senseVoiceModelId = 'sense-voice-zh-en-ja-ko-yue-2024-07-17';
const whisperSmallModelId = 'whisper-small-multilingual';
const whisperMediumModelId = 'whisper-medium-multilingual';
const qwen3Asr06Int8Id = 'qwen3-asr-0.6b-int8';
const qwen3Asr06Float32Id = 'qwen3-asr-0.6b-float32';
const qwen3Asr17Int8Id = 'qwen3-asr-1.7b-int8';
const qwen3Asr17Float32Id = 'qwen3-asr-1.7b-float32';
const qwen3AsrTokenizerId = 'qwen3-asr-tokenizer';

AsrSpec asrSpecFor(AsrEngineChoice engine, String manifestJson) {
  final id = switch (engine) {
    AsrEngineChoice.senseVoice => senseVoiceModelId,
    AsrEngineChoice.whisperSmall => whisperSmallModelId,
    AsrEngineChoice.whisperMedium => whisperMediumModelId,
    AsrEngineChoice.qwen3Asr06Int8 => qwen3Asr06Int8Id,
    AsrEngineChoice.qwen3Asr06Float32 => qwen3Asr06Float32Id,
    AsrEngineChoice.qwen3Asr17Int8 => qwen3Asr17Int8Id,
    AsrEngineChoice.qwen3Asr17Float32 => qwen3Asr17Float32Id,
  };
  return asrPackage(
    manifestJson,
    id,
    archive: engine == AsrEngineChoice.senseVoice,
  );
}

AsrSpec asrTokenizerSpec(String manifestJson) {
  return asrPackage(manifestJson, qwen3AsrTokenizerId);
}

AsrSpec asrPackage(String manifestJson, String id, {bool archive = false}) {
  final root = jsonDecode(manifestJson) as Map<String, Object?>;
  final listed = root['packages'] as List<Object?>? ?? const [];
  for (final item in listed) {
    final map = item as Map<String, Object?>;
    if (map['id'] != id) continue;
    final capabilities = (map['capabilities'] as List<Object?>? ?? const [])
        .map((value) => value.toString())
        .toList();
    if (!capabilities.contains('asr')) {
      throw AppFailure(AppErrorType.modelMissing, detail: id);
    }
    final files = <AsrFile>[];
    for (final entry in map['files'] as List<Object?>? ?? const []) {
      final file = entry as Map<String, Object?>;
      files.add(
        AsrFile(
          name: file['name'] as String,
          sizeBytes: file['sizeBytes'] as int,
          sha256: file['sha256'] as String,
          downloadUrl: file['downloadUrl'] as String,
        ),
      );
    }
    return AsrSpec(
      id: id,
      sizeBytes: map['sizeBytes'] as int,
      sha256: map['sha256'] as String? ?? '',
      downloadUrl: map['downloadUrl'] as String? ?? '',
      archive: archive,
      files: files,
    );
  }
  throw AppFailure(AppErrorType.modelMissing, detail: id);
}

String asrLanguageCode(String language, {String engine = 'senseVoice'}) {
  if (engine == 'whisper' || engine == 'qwen3Asr') {
    return switch (language) {
      'zh-Hans' || 'zh-Hant' || 'zh' => 'zh',
      'en' ||
      'ar' ||
      'nl' ||
      'fr' ||
      'de' ||
      'hi' ||
      'id' ||
      'it' ||
      'ja' ||
      'ko' ||
      'pl' ||
      'pt' ||
      'ru' ||
      'es' ||
      'th' ||
      'tr' ||
      'uk' ||
      'vi' => language,
      _ => throw AppFailure(AppErrorType.languageUnsupported, detail: language),
    };
  }
  return switch (language) {
    'zh-Hans' || 'zh-Hant' || 'zh' => 'zh',
    'en' => 'en',
    'ja' => 'ja',
    'ko' => 'ko',
    _ => throw AppFailure(AppErrorType.languageUnsupported, detail: language),
  };
}
