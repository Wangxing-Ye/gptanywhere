import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_scope.dart';
import 'app/app_theme.dart';
import 'app/home_shell.dart';
import 'l10n/app_text.dart';
import 'data/shared_preferences_settings_store.dart';
import 'domain/app_settings.dart';
import 'domain/engines.dart';
import 'domain/photo_source.dart';
import 'domain/voice_capture.dart';
import 'services/asr_models.dart';
import 'services/device_memory.dart';
import 'services/image_picker_photo_source.dart';
import 'services/llama_chat_engine.dart';
import 'services/llama_translation_engine.dart';
import 'services/mlkit_ocr_engine.dart';
import 'services/model_catalog.dart';
import 'services/model_manager.dart';
import 'services/model_transport.dart';
import 'services/platform_llama_runner.dart';
import 'services/platform_speech_engine.dart';
import 'services/platform_voice_capture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final manifest = await rootBundle.loadString('models/manifest.json');
  final catalog = ModelCatalog.parse(manifest);
  final models = ModelManager(
    catalog: catalog,
    root: Directory('${support.path}/models'),
    transport: HttpModelTransport(),
    network: SocketNetworkGate(),
  );
  final runner = PlatformLlamaRunner();
  runApp(
    TranslateAnywhereApp(
      settings: SharedPreferencesSettingsStore(),
      models: models,
      translator: LlamaTranslationEngine(models: models, runner: runner),
      chat: LlamaChatEngine(models: models, runner: runner),
      ocr: MlkitOcrEngine(),
      photos: ImagePickerPhotoSource(),
      speech: PlatformSpeechEngine(),
      voice: PlatformVoiceCapture(),
      asr: AsrModels(
        manifestJson: manifest,
        root: Directory('${support.path}/asr'),
        transport: HttpModelTransport(),
        network: SocketNetworkGate(),
        extractor: PlatformTarExtractor(),
      ),
      deviceMemory: PlatformDeviceMemory(),
      importPicker: _pickModelFile,
    ),
  );
}

Future<String?> _pickModelFile() async {
  final file = await FilePicker.pickFile();
  return file?.path;
}

class TranslateAnywhereApp extends StatefulWidget {
  const TranslateAnywhereApp({
    super.key,
    required this.settings,
    required this.models,
    required this.translator,
    this.chat = const UnavailableChatEngine(),
    required this.ocr,
    required this.photos,
    required this.speech,
    required this.voice,
    required this.asr,
    required this.importPicker,
    this.deviceMemory = const UnavailableDeviceMemory(),
  });

  final SettingsStore settings;
  final ModelManager models;
  final TranslationEngine translator;
  final ChatEngine chat;
  final OcrEngine ocr;
  final PhotoSource photos;
  final SpeechEngine speech;
  final VoiceCapture voice;
  final AsrStore asr;
  final ImportPicker importPicker;
  final DeviceMemory deviceMemory;

  @override
  State<TranslateAnywhereApp> createState() => _TranslateAnywhereAppState();
}

class _TranslateAnywhereAppState extends State<TranslateAnywhereApp> {
  var _language = InterfaceLanguage.english;

  @override
  void initState() {
    super.initState();
    widget.settings.revisions.addListener(_loadLanguage);
    _loadLanguage();
  }

  @override
  void didUpdateWidget(TranslateAnywhereApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings)) {
      oldWidget.settings.revisions.removeListener(_loadLanguage);
      widget.settings.revisions.addListener(_loadLanguage);
      _loadLanguage();
    }
  }

  @override
  void dispose() {
    widget.settings.revisions.removeListener(_loadLanguage);
    super.dispose();
  }

  Future<void> _loadLanguage() async {
    final settings = await widget.settings.load();
    if (!mounted || settings.interfaceLanguage == _language) return;
    setState(() => _language = settings.interfaceLanguage);
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: widget.settings,
      models: widget.models,
      translator: widget.translator,
      chat: widget.chat,
      ocr: widget.ocr,
      photos: widget.photos,
      speech: widget.speech,
      voice: widget.voice,
      asr: widget.asr,
      importPicker: widget.importPicker,
      deviceMemory: widget.deviceMemory,
      child: InterfaceScope(
        language: _language,
        child: MaterialApp(
          title: 'GPTAnywhere',
          theme: buildAppTheme(),
          home: HomeShell(settings: widget.settings),
        ),
      ),
    );
  }
}
