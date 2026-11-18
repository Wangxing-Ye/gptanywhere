import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/app_error.dart';
import 'llama_translation_engine.dart';

class PlatformLlamaRunner implements LlamaRunner {
  PlatformLlamaRunner({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel(_methodName),
      _events = events ?? const EventChannel(_eventName) {
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: _onChannelError,
    );
  }

  static const _methodName = 'dev.local.gptanywhere/llama';
  static const _eventName = 'dev.local.gptanywhere/llama_events';

  final MethodChannel _methods;
  final EventChannel _events;
  final _controllers = <String, StreamController<String>>{};
  late final StreamSubscription<dynamic> _subscription;

  void _onEvent(Object? event) {
    final map = Map<Object?, Object?>.from(event as Map);
    final taskId = map['taskId'] as String?;
    if (taskId == null) return;
    final controller = _controllers[taskId];
    if (controller == null || controller.isClosed) return;
    final error = map['error'] as String?;
    if (error != null) {
      final typeName = map['errorType'] as String?;
      controller.addError(AppFailure(_errorType(typeName), detail: error));
      controller.close();
      _controllers.remove(taskId);
      return;
    }
    final chunk = map['chunk'] as String? ?? '';
    if (chunk.isNotEmpty) controller.add(chunk);
    if (map['done'] == true) {
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
  }

  @override
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
  }) {
    final controller = StreamController<String>();
    _controllers[taskId] = controller;
    _methods
        .invokeMethod<void>('start', {
          'taskId': taskId,
          'modelPath': modelPath,
          'systemPrompt': systemPrompt,
          'prompt': prompt,
          'maxTokens': maxTokens,
          'thinking': thinking,
          'imagePaths': imagePaths,
          'visionPath': visionPath,
          'imageMaxTokens': imageMaxTokens,
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
          _controllers.remove(taskId);
        });
    return controller.stream;
  }

  @override
  Future<void> cancel(String taskId) async {
    try {
      await _methods.invokeMethod<void>('cancel', {'taskId': taskId});
    } finally {
      final controller = _controllers.remove(taskId);
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
    }
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    for (final controller in _controllers.values) {
      if (!controller.isClosed) await controller.close();
    }
    _controllers.clear();
  }
}

AppErrorType _errorType(String? name) {
  for (final type in AppErrorType.values) {
    if (type.name == name) return type;
  }
  return AppErrorType.modelLoadFailed;
}
