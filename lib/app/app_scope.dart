import 'package:flutter/material.dart';

import '../domain/app_settings.dart';
import '../domain/engines.dart';
import '../domain/photo_source.dart';
import '../domain/voice_capture.dart';
import '../services/asr_models.dart';
import '../services/device_memory.dart';
import '../services/model_manager.dart';

typedef ImportPicker = Future<String?> Function();

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.settings,
    required this.models,
    required this.translator,
    required this.ocr,
    required this.photos,
    required this.speech,
    required this.voice,
    required this.asr,
    required this.importPicker,
    this.chat = const UnavailableChatEngine(),
    this.deviceMemory = const UnavailableDeviceMemory(),
    required super.child,
  });

  final SettingsStore settings;
  final ModelManager models;
  final TranslationEngine translator;
  final OcrEngine ocr;
  final PhotoSource photos;
  final SpeechEngine speech;
  final VoiceCapture voice;
  final AsrStore asr;
  final ImportPicker importPicker;
  final ChatEngine chat;
  final DeviceMemory deviceMemory;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) {
    return settings != oldWidget.settings ||
        models != oldWidget.models ||
        translator != oldWidget.translator ||
        ocr != oldWidget.ocr ||
        photos != oldWidget.photos ||
        speech != oldWidget.speech ||
        voice != oldWidget.voice ||
        asr != oldWidget.asr ||
        chat != oldWidget.chat ||
        deviceMemory != oldWidget.deviceMemory;
  }
}
