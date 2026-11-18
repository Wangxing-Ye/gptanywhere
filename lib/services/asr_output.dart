import 'dart:convert';

/// Pulls the spoken text out of a local ASR program.
/// SenseVoice prints one JSON object per file. whisper.cpp prints plain text.
String? transcriptFromAsr(String stdout, {required bool json}) {
  if (json) {
    for (final line in const LineSplitter().convert(stdout)) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;
      final map = decoded.cast<Object?, Object?>();
      final event = (map['event'] as String? ?? '').toLowerCase();
      if (event.contains('nospeech')) return null;
      final text = (map['text'] as String? ?? '').trim();
      if (text.isEmpty) return null;
      return text;
    }
    return null;
  }
  final text = stdout.trim();
  if (text.isEmpty) return null;
  return text;
}

/// Chinese must not be sent to an English-only whisper weight.
bool isEnglishOnlyAsrWeight(String path) {
  final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  return name.contains('.en.') ||
      name.endsWith('.en') ||
      name.endsWith('.en.bin');
}
