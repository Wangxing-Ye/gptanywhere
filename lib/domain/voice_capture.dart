import 'dart:typed_data';

class CapturedAudio {
  const CapturedAudio({
    required this.wav,
    required this.interrupted,
    required this.reachedLimit,
  });

  final Uint8List wav;
  final bool interrupted;
  final bool reachedLimit;
}

/// Microphone and audio-file import. The page does not open the recorder.
abstract class VoiceCapture {
  Stream<int> get elapsedMs;

  Future<void> startRecording({required int maxMs});

  Future<void> stopRecording();

  /// Completes when recording stops, hits [maxMs], or loses the microphone.
  Future<CapturedAudio?> get recording;

  /// Null when the user cancels the picker.
  Future<Uint8List?> importAudio();

  /// Plays a local WAV. The page does not open a player.
  Future<void> play(Uint8List wav);

  Future<void> stopPlayback();
}
