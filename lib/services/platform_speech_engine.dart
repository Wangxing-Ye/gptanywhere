import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/engines.dart';
import 'asr_output.dart';
import 'wav_audio.dart';

class PlatformSpeechEngine implements SpeechEngine {
  PlatformSpeechEngine({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel(_methodName),
      _events = events ?? const EventChannel(_eventName) {
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: _onChannelError,
    );
  }

  static const _methodName = 'dev.local.gptanywhere/asr';
  static const _eventName = 'dev.local.gptanywhere/asr_events';

  final MethodChannel _methods;
  final EventChannel _events;
  final _controllers = <String, StreamController<SpeechSegment>>{};
  final _stdout = <String, StringBuffer>{};
  late final StreamSubscription<dynamic> _subscription;

  void _onEvent(Object? event) {
    final map = Map<Object?, Object?>.from(event as Map);
    final taskId = map['taskId'] as String?;
    if (taskId == null) return;
    final controller = _controllers[taskId];
    if (controller == null || controller.isClosed) return;
    final error = map['error'] as String?;
    if (error != null) {
      controller.addError(
        AppFailure(_errorType(map['errorType'] as String?), detail: error),
      );
      controller.close();
      _controllers.remove(taskId);
      _stdout.remove(taskId);
      return;
    }
    final chunk = map['chunk'] as String? ?? '';
    if (chunk.isNotEmpty) {
      (_stdout[taskId] ??= StringBuffer()).write(chunk);
    }
    if (map['done'] == true) {
      final text = transcriptFromAsr(
        _stdout[taskId]?.toString() ?? '',
        json: map['json'] == true,
      );
      _stdout.remove(taskId);
      if (text == null) {
        controller.addError(const AppFailure(AppErrorType.noSpeech));
      } else {
        controller.add(
          SpeechSegment(startMs: 0, endMs: 0, text: text, isFinal: true),
        );
      }
      controller.close();
      _controllers.remove(taskId);
    }
  }

  void _onChannelError(Object error) {
    for (final controller in _controllers.values) {
      if (!controller.isClosed) {
        controller.addError(
          AppFailure(AppErrorType.modelLoadFailed, detail: error.toString()),
        );
        controller.close();
      }
    }
    _controllers.clear();
    _stdout.clear();
  }

  @override
  Stream<SpeechSegment> transcribe(SpeechRequest request) {
    final controller = StreamController<SpeechSegment>();
    if (isEnglishOnlyAsrWeight(request.modelPath)) {
      controller.addError(
        const AppFailure(
          AppErrorType.languageUnsupported,
          detail: 'english-only weight',
        ),
      );
      controller.close();
      return controller.stream;
    }
    final wav = File(request.wavPath);
    if (!wav.existsSync() || wavIsSilent(wav.readAsBytesSync())) {
      controller.addError(const AppFailure(AppErrorType.noSpeech));
      controller.close();
      return controller.stream;
    }
    _controllers[request.taskId] = controller;
    _stdout[request.taskId] = StringBuffer();
    _methods
        .invokeMethod<void>('start', {
          'taskId': request.taskId,
          'engine': request.engineName,
          'modelPath': request.modelPath,
          'tokensPath': request.tokensPath,
          'convPath': request.convPath,
          'encoderPath': request.encoderPath,
          'decoderPath': request.decoderPath,
          'tokenizerPath': request.tokenizerPath,
          'language': request.language,
          'wavPath': request.wavPath,
        })
        .catchError((Object error) {
          if (!controller.isClosed) {
            controller.addError(
              AppFailure(
                AppErrorType.modelLoadFailed,
                detail: error.toString(),
              ),
            );
            controller.close();
          }
          _controllers.remove(request.taskId);
          _stdout.remove(request.taskId);
        });
    return controller.stream;
  }

  @override
  Future<void> cancel(String taskId) async {
    try {
      await _methods.invokeMethod<void>('cancel', {'taskId': taskId});
    } finally {
      final controller = _controllers.remove(taskId);
      _stdout.remove(taskId);
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
    }
  }

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    for (final controller in _controllers.values) {
      if (!controller.isClosed) await controller.close();
    }
    _controllers.clear();
    _stdout.clear();
  }
}

AppErrorType _errorType(String? name) {
  for (final type in AppErrorType.values) {
    if (type.name == name) return type;
  }
  return AppErrorType.modelLoadFailed;
}
