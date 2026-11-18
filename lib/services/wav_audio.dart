import 'dart:typed_data';

/// 16-bit little-endian PCM in a canonical WAV container.
Uint8List wavFromPcm16({required Int16List samples, int sampleRate = 16000}) {
  final dataBytes = samples.length * 2;
  final bytes = ByteData(44 + dataBytes);
  void writeString(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeString(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bytes.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// SenseVoice and whisper.cpp both label digital silence as speech.
/// Samples below this RMS never reach either program.
const silenceRms = 80;

bool wavIsSilent(Uint8List wav) {
  final samples = _pcm16(wav);
  if (samples.isEmpty) return true;
  var sum = 0.0;
  for (final sample in samples) {
    final value = sample.toDouble();
    sum += value * value;
  }
  final rms = sum / samples.length;
  return rms < silenceRms * silenceRms;
}

Int16List _pcm16(Uint8List wav) {
  if (wav.length < 44) return Int16List(0);
  final data = ByteData.sublistView(wav);
  var offset = 12;
  while (offset + 8 <= wav.length) {
    final id = String.fromCharCodes(wav.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    if (id == 'data') {
      final end = (start + size).clamp(0, wav.length);
      final count = (end - start) ~/ 2;
      final samples = Int16List(count);
      for (var i = 0; i < count; i++) {
        samples[i] = data.getInt16(start + i * 2, Endian.little);
      }
      return samples;
    }
    offset = start + size + (size.isOdd ? 1 : 0);
  }
  return Int16List(0);
}
