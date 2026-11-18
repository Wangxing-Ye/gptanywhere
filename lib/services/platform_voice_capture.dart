import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../domain/app_error.dart';
import '../domain/voice_capture.dart';

class PlatformVoiceCapture implements VoiceCapture {
  PlatformVoiceCapture({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel(_methodName),
      _events = events ?? const EventChannel(_eventName) {
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: _onError,
    );
  }

  static const _methodName = 'dev.local.gptanywhere/voice';
  static const _eventName = 'dev.local.gptanywhere/voice_events';
  static const recordingLimitMs = 30000;
  static const importLimitMs = 60000;

  final MethodChannel _methods;
  final EventChannel _events;
  final _elapsed = StreamController<int>.broadcast();
  late final StreamSubscription<dynamic> _subscription;
  Completer<CapturedAudio?>? _done;

  @override
  Stream<int> get elapsedMs => _elapsed.stream;

  @override
  Future<CapturedAudio?> get recording => _done?.future ?? Future.value();

  void _onEvent(Object? event) {
    final map = Map<Object?, Object?>.from(event as Map);
    final elapsed = map['elapsedMs'];
    if (elapsed is int) _elapsed.add(elapsed);
    if (map['done'] == true) {
      final bytes = map['wav'];
      final audio = bytes is Uint8List && bytes.isNotEmpty
          ? CapturedAudio(
              wav: bytes,
              interrupted: map['interrupted'] == true,
              reachedLimit: map['reachedLimit'] == true,
            )
          : null;
      final done = _done;
      if (done != null && !done.isCompleted) done.complete(audio);
    }
    final error = map['error'] as String?;
    if (error != null) {
      final done = _done;
      if (done != null && !done.isCompleted) {
        done.completeError(_failure(map['errorType'] as String?, error));
      }
    }
  }

  void _onError(Object error) {
    final done = _done;
    if (done != null && !done.isCompleted) {
      done.completeError(
        AppFailure(AppErrorType.modelLoadFailed, detail: error.toString()),
      );
    }
  }

  @override
  Future<void> startRecording({int maxMs = recordingLimitMs}) async {
    final limit = maxMs > recordingLimitMs ? recordingLimitMs : maxMs;
    _done = Completer<CapturedAudio?>();
    try {
      await _methods.invokeMethod<void>('startRecording', {'maxMs': limit});
    } on PlatformException catch (error) {
      _done = null;
      throw _failure(error.code, error.message ?? error.code);
    }
  }

  @override
  Future<void> stopRecording() async {
    try {
      await _methods.invokeMethod<void>('stopRecording');
    } on PlatformException catch (error) {
      throw _failure(error.code, error.message ?? error.code);
    }
  }

  @override
  Future<Uint8List?> importAudio() async {
    final picked = await FilePicker.pickFile(type: FileType.audio);
    final path = picked?.path;
    if (path == null) return null;
    try {
      final bytes = await _methods.invokeMethod<Uint8List>('decode', {
        'path': path,
        'maxMs': importLimitMs,
      });
      if (bytes == null || bytes.isEmpty) {
        throw const AppFailure(AppErrorType.fileCorrupt);
      }
      return bytes;
    } on PlatformException catch (error) {
      throw _failure(error.code, error.message ?? error.code);
    }
  }

  @override
  Future<void> play(Uint8List wav) async {
    try {
      await _methods.invokeMethod<void>('play', {'wav': wav});
    } on PlatformException catch (error) {
      throw _failure(error.code, error.message ?? error.code);
    }
  }

  @override
  Future<void> stopPlayback() async {
    try {
      await _methods.invokeMethod<void>('stopPlayback');
    } on PlatformException catch (error) {
      throw _failure(error.code, error.message ?? error.code);
    }
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    await _elapsed.close();
  }

  AppFailure _failure(String? code, String detail) {
    final type = switch (code) {
      'permissionDenied' ||
      'permission_denied' => AppErrorType.permissionDenied,
      'audioInterrupted' => AppErrorType.audioInterrupted,
      'noSpeech' => AppErrorType.noSpeech,
      'cancelled' => AppErrorType.cancelled,
      _ => AppErrorType.fileCorrupt,
    };
    return AppFailure(type, detail: detail);
  }
}
