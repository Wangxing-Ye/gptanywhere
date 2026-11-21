import 'package:flutter/foundation.dart';

/// Gemma 4 E4B stays unavailable when total memory is under 12 GiB.
const gemma4E4bMinBytes = 12 * 1024 * 1024 * 1024;

/// Qwen3-ASR 1.7B float32 stays unavailable when total memory is under 16 GiB.
const qwen3Asr17Float32MinBytes = 16 * 1024 * 1024 * 1024;

enum TextModelChoice {
  qwen31_7b('qwen3-1.7b-q4-k-m', 'Qwen3-1.7B', 0),
  qwen35_0_8b('qwen3.5-0.8b-q4-k-m', 'Qwen3.5-0.8B', 0),
  qwen35_2b('qwen3.5-2b-q4-k-m', 'Qwen3.5-2B', 0),
  qwen35_4b('qwen3.5-4b-q4-k-m', 'Qwen3.5-4B', 0),
  gemma3_1b('gemma-3-1b-it-q4-k-m', 'Gemma 3 1B', 0),
  gemma3_4b('gemma-3-4b-it-q4-k-m', 'Gemma 3 4B', 0),
  gemma4E2b('gemma-4-e2b-it-q4-0', 'Gemma 4 E2B', 0),
  gemma4E4b('gemma-4-e4b-it-q4-0', 'Gemma 4 E4B', gemma4E4bMinBytes),
  lfm25_1_2b('lfm2.5-1.2b-instruct-q4-k-m', 'LFM2.5-1.2B', 0),
  lfm25Vl1_6b('lfm2.5-vl-1.6b-q4-k-m', 'LFM2.5-VL-1.6B', 0),
  lfm3_1_7b('lfm3-1.7b-q4-k-m', 'LFM3-1.7B', 0),
  minicpmV47_1b('minicpm-v-4.7-1b-q4-k-m', 'MiniCPM-V 4.7 1B', 0),
  minicpm5_1b('minicpm5-1b-q4-k-m', 'MiniCPM5-1B', 0),
  minicpm5_2b('minicpm5-2b-q4-k-m', 'MiniCPM5-2B', 0);

  const TextModelChoice(this.id, this.label, this.minMemoryBytes);

  final String id;
  final String label;

  /// Zero means the phone's total memory does not gate this model.
  final int minMemoryBytes;

  bool allowedWith(int? totalBytes) {
    if (minMemoryBytes <= 0) return true;
    return totalBytes != null && totalBytes >= minMemoryBytes;
  }

  static TextModelChoice fromStorage(String? raw) {
    for (final choice in values) {
      if (choice.id == raw) return choice;
    }
    return qwen31_7b;
  }
}

TextModelChoice resolveTextModel(TextModelChoice choice, int? totalBytes) {
  if (!choice.allowedWith(totalBytes)) return TextModelChoice.qwen31_7b;
  return choice;
}

/// Whole-number percent for a download. A non-positive total means unknown.
int? downloadPercent(int received, int total) {
  final denom = total < 0 ? -total : total;
  if (denom <= 0 || received < 0) return null;
  final value = (received * 100) ~/ denom;
  if (value < 0) return 0;
  if (value > 100) return 100;
  return value;
}

String formatModelSize(int bytes) {
  if (bytes >= 1000000000) {
    return '${(bytes / 1000000000).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1000000) {
    return '${(bytes / 1000000).toStringAsFixed(0)} MB';
  }
  return '$bytes B';
}

enum AsrEngineChoice {
  senseVoice('SenseVoice', 0),
  whisperSmall('Whisper-small', 0),
  whisperMedium('Whisper-medium', 0),
  qwen3Asr06Int8('Qwen3-ASR 0.6B int8', 0),
  qwen3Asr06Float32('Qwen3-ASR 0.6B float32', 0),
  qwen3Asr17Int8('Qwen3-ASR 1.7B int8', 0),
  qwen3Asr17Float32('Qwen3-ASR 1.7B float32', qwen3Asr17Float32MinBytes);

  const AsrEngineChoice(this.label, this.minMemoryBytes);

  final String label;

  /// Zero means the phone's total memory does not gate this model.
  final int minMemoryBytes;

  bool allowedWith(int? totalBytes) {
    if (minMemoryBytes <= 0) return true;
    return totalBytes != null && totalBytes >= minMemoryBytes;
  }

  static AsrEngineChoice fromStorage(String? raw) {
    return switch (raw) {
      'whisper' || 'whisperSmall' => AsrEngineChoice.whisperSmall,
      'whisperMedium' => AsrEngineChoice.whisperMedium,
      'qwen3Asr06Int8' => AsrEngineChoice.qwen3Asr06Int8,
      'qwen3Asr06Float32' => AsrEngineChoice.qwen3Asr06Float32,
      'qwen3Asr17Int8' => AsrEngineChoice.qwen3Asr17Int8,
      'qwen3Asr17Float32' => AsrEngineChoice.qwen3Asr17Float32,
      _ => AsrEngineChoice.senseVoice,
    };
  }

  String get storageValue {
    return switch (this) {
      AsrEngineChoice.senseVoice => 'senseVoice',
      AsrEngineChoice.whisperSmall => 'whisperSmall',
      AsrEngineChoice.whisperMedium => 'whisperMedium',
      AsrEngineChoice.qwen3Asr06Int8 => 'qwen3Asr06Int8',
      AsrEngineChoice.qwen3Asr06Float32 => 'qwen3Asr06Float32',
      AsrEngineChoice.qwen3Asr17Int8 => 'qwen3Asr17Int8',
      AsrEngineChoice.qwen3Asr17Float32 => 'qwen3Asr17Float32',
    };
  }

  /// Native programs stay `senseVoice`, `whisper`, and `qwen3Asr`.
  String get nativeEngine {
    return switch (this) {
      AsrEngineChoice.senseVoice => 'senseVoice',
      AsrEngineChoice.whisperSmall ||
      AsrEngineChoice.whisperMedium => 'whisper',
      AsrEngineChoice.qwen3Asr06Int8 ||
      AsrEngineChoice.qwen3Asr06Float32 ||
      AsrEngineChoice.qwen3Asr17Int8 ||
      AsrEngineChoice.qwen3Asr17Float32 => 'qwen3Asr',
    };
  }
}

AsrEngineChoice resolveAsrEngine(AsrEngineChoice choice, int? totalBytes) {
  if (!choice.allowedWith(totalBytes)) return AsrEngineChoice.senseVoice;
  return choice;
}

enum InterfaceLanguage {
  english('en', 'English'),
  zhHans('zh-Hans', '简体中文');

  const InterfaceLanguage(this.storageValue, this.nativeName);

  final String storageValue;
  final String nativeName;

  static InterfaceLanguage fromStorage(String? raw) {
    for (final language in values) {
      if (language.storageValue == raw) return language;
    }
    return english;
  }
}

class AppSettings {
  const AppSettings({
    this.asrEngine = AsrEngineChoice.senseVoice,
    this.textModel = TextModelChoice.qwen31_7b,
    this.thinkingEnabled = false,
    this.interfaceLanguage = InterfaceLanguage.english,
  });

  static const defaults = AppSettings();

  final AsrEngineChoice asrEngine;
  final TextModelChoice textModel;
  final bool thinkingEnabled;
  final InterfaceLanguage interfaceLanguage;

  AppSettings copyWith({
    AsrEngineChoice? asrEngine,
    TextModelChoice? textModel,
    bool? thinkingEnabled,
    InterfaceLanguage? interfaceLanguage,
  }) {
    return AppSettings(
      asrEngine: asrEngine ?? this.asrEngine,
      textModel: textModel ?? this.textModel,
      thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
      interfaceLanguage: interfaceLanguage ?? this.interfaceLanguage,
    );
  }
}

abstract class SettingsStore {
  ValueListenable<int> get revisions;

  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}
