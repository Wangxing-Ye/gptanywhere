import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../domain/app_settings.dart';
import '../../domain/engines.dart';
import '../../domain/translation_language.dart';
import '../../l10n/app_text.dart';
import '../../services/model_catalog.dart';
import '../../services/ocr_script.dart';
import 'photo_crop_page.dart';

class PhotoEntryPage extends StatefulWidget {
  const PhotoEntryPage({super.key});

  @override
  State<PhotoEntryPage> createState() => _PhotoEntryPageState();
}

class _PhotoEntryPageState extends State<PhotoEntryPage> {
  final _recognized = TextEditingController();
  var _source = TranslationLanguage.zhHans;
  var _target = TranslationLanguage.english;
  Uint8List? _image;
  var _output = '';
  UiLine _status = (text) => '';
  var _ready = false;
  var _busy = false;
  var _picking = false;
  var _checked = false;
  var _epoch = 0;
  String? _taskId;
  TranslationEngine? _translator;
  SettingsStore? _settingsStore;
  String _modelId = ModelCatalog.primaryTextModelId;
  var _thinking = false;

  @override
  void dispose() {
    final taskId = _taskId;
    _taskId = null;
    _epoch++;
    if (taskId != null) {
      _translator?.cancel(taskId);
    }
    _settingsStore?.revisions.removeListener(_onSettings);
    _recognized.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _translator = AppScope.of(context).translator;
    final store = AppScope.of(context).settings;
    if (!identical(_settingsStore, store)) {
      _settingsStore?.revisions.removeListener(_onSettings);
      _settingsStore = store;
      store.revisions.addListener(_onSettings);
    }
    if (!_checked) {
      _checked = true;
      _refreshModel();
    }
  }

  void _onSettings() {
    _refreshModel();
  }

  Future<void> _refreshModel() async {
    final scope = AppScope.of(context);
    final settings = await scope.settings.load();
    final total = await scope.deviceMemory.totalBytes();
    final choice = resolveTextModel(settings.textModel, total);
    _modelId = choice.id;
    _thinking = settings.thinkingEnabled;
    try {
      final installed = await scope.models.installed(_modelId);
      if (!mounted) return;
      setState(() => _ready = installed != null);
    } on AppFailure {
      if (!mounted) return;
      setState(() => _ready = false);
    }
  }

  Future<void> _choose({required bool camera}) async {
    if (_picking) return;
    final epoch = ++_epoch;
    await _cancelActive();
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _picking = true;
      _busy = true;
      _status = camera
          ? (text) => text.openingCamera
          : (text) => text.openingGallery;
    });
    final photos = AppScope.of(context).photos;
    Uint8List? bytes;
    try {
      bytes = camera
          ? await photos.takePicture()
          : await photos.pickFromGallery();
    } on AppFailure catch (error) {
      _stopPick(epoch, _message(error));
      return;
    } catch (_) {
      _stopPick(epoch, (text) => text.imageUnreadable);
      return;
    }
    if (!mounted || epoch != _epoch) return;
    if (camera && bytes != null) {
      final decision = await Navigator.of(context).push<CropDecision>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) => PhotoCropPage(bytes: bytes!),
        ),
      );
      if (!mounted || epoch != _epoch) return;
      if (decision == null || decision.bytes == null) {
        _stopPick(
          epoch,
          decision != null && decision.unreadable
              ? (text) => text.imageUnreadable
              : (_image == null
                    ? (text) => ''
                    : (text) => text.imageNotChanged),
        );
        return;
      }
      bytes = decision.bytes;
    }
    if (bytes == null) {
      setState(() {
        _picking = false;
        _busy = false;
        _status = _image == null
            ? (text) => ''
            : (text) => text.imageNotChanged;
      });
      return;
    }
    final selected = bytes;
    setState(() {
      _picking = false;
      _image = selected;
      _output = '';
      _status = (text) => text.readingImage;
    });
    _recognized.text = '';
    await _recognize(epoch);
  }

  void _stopPick(int epoch, UiLine status) {
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _picking = false;
      _busy = false;
      _status = status;
    });
  }

  Future<void> _recognize(int epoch) async {
    final image = _image;
    if (image == null) return;
    setState(() {
      _busy = true;
      _status = (text) => text.readingImage;
      _output = '';
    });
    try {
      final document = await AppScope.of(
        context,
      ).ocr.recognize(image, ocrScriptForLanguage(_source.code));
      if (!mounted || epoch != _epoch) return;
      _recognized.text = document.plainText;
      _hideKeyboard();
      if (!_ready) {
        setState(() {
          _busy = false;
          _status = (text) => text.modelNotReadyToTranslate;
        });
        return;
      }
      await _translate(epoch);
    } on AppFailure catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _busy = false;
        _status = _message(error);
      });
    } catch (_) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _busy = false;
        _status = (text) => text.photoTranslationFailed;
      });
    }
  }

  void _hideKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  Future<void> _translate(int epoch) async {
    _hideKeyboard();
    final text = _recognized.text.trim();
    if (!mounted || epoch != _epoch) return;
    if (text.isEmpty || !_ready) {
      setState(() => _busy = false);
      return;
    }
    if (_source.code == _target.code) {
      setState(() {
        _busy = false;
        _status = (text) => text.chooseDifferentTarget;
      });
      return;
    }
    final taskId = DateTime.now().microsecondsSinceEpoch.toString();
    final scope = AppScope.of(context);
    setState(() {
      _taskId = taskId;
      _output = '';
      _busy = true;
      _status = (text) => text.translating;
    });
    try {
      await for (final event in scope.translator.translate(
        TranslationRequest(
          taskId: taskId,
          source: _source.code,
          target: _target.code,
          text: text,
          tokenBudget: 256,
          modelVersion: _modelId,
          thinking: _thinking,
        ),
      )) {
        if (!mounted || epoch != _epoch || _taskId != event.taskId) return;
        final next = event.text.isNotEmpty ? event.text : event.delta;
        if (next.isEmpty) continue;
        setState(() => _output = next);
      }
      if (!mounted || epoch != _epoch || _taskId != taskId) return;
      setState(() {
        _busy = false;
        _status = _output.isEmpty
            ? (text) => text.noTranslation
            : (text) => text.modelOnDevice;
      });
    } on AppFailure catch (error) {
      if (!mounted || epoch != _epoch || _taskId != taskId) return;
      setState(() {
        _busy = false;
        _status = _message(error);
      });
    } finally {
      if (mounted && epoch == _epoch && _taskId == taskId) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _cancelActive() async {
    final taskId = _taskId;
    _taskId = null;
    if (taskId != null) {
      await _translator?.cancel(taskId);
    }
  }

  Future<void> _cancel() async {
    _epoch++;
    await _cancelActive();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _picking = false;
      _status = (text) => text.canceled;
    });
  }

  Future<void> _copy() async {
    if (_output.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _output));
    if (!mounted) return;
    setState(() => _status = (text) => text.translationCopied);
  }

  void _swap() {
    final nextSource = _target.photoSource
        ? _target
        : TranslationLanguage.zhHans;
    final nextTarget = _source;
    setState(() {
      _source = nextSource;
      _target = nextTarget;
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final text = AppText.of(context);
    return GestureDetector(
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Expanded(child: _languageMenu(source: true)),
              IconButton(
                tooltip: text.swapLanguages,
                onPressed: _swap,
                icon: const Icon(Icons.swap_horiz),
              ),
              Expanded(child: _languageMenu(source: false)),
            ],
          ),
          if (_status(text).isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_status(text), key: const Key('photo-status')),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _picking ? null : () => _choose(camera: false),
                  child: Text(text.gallery),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _picking ? null : () => _choose(camera: true),
                  child: Text(text.camera),
                ),
              ),
            ],
          ),
          if (image != null || _busy) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (image != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () {
                              _recognize(++_epoch);
                            },
                      child: Text(text.readAgain),
                    ),
                  ),
                if (image != null && _busy) const SizedBox(width: 8),
                if (_busy)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _cancel,
                      child: Text(text.cancel),
                    ),
                  ),
              ],
            ),
          ],
          if (image != null) ...[
            const SizedBox(height: 12),
            Image.memory(
              image,
              height: 180,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return Text(text.imageCannotBeShown);
              },
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const Key('photo-recognized'),
            controller: _recognized,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: text.recognizedText,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: _busy
                ? const SizedBox.shrink()
                : FilledButton(
                    onPressed: _ready && image != null
                        ? () => _translate(_epoch)
                        : null,
                    child: Text(text.translate),
                  ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                text.translation,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              TextButton(
                onPressed: _output.isEmpty ? null : _copy,
                child: Text(text.copy),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _output.isEmpty ? text.noTranslationYet : _output,
            key: const Key('photo-output'),
            style: _output.isEmpty
                ? TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _languageMenu({required bool source}) {
    final value = source ? _source : _target;
    final items = source
        ? TranslationLanguage.photoSources
        : TranslationLanguage.values;
    final chinese = AppText.of(context).chinese;
    return DropdownButton<TranslationLanguage>(
      isExpanded: true,
      value: items.contains(value) ? value : items.first,
      items: [
        for (final language in items)
          DropdownMenuItem(
            value: language,
            child: Text(language.uiLabel(chinese)),
          ),
      ],
      onChanged: (TranslationLanguage? language) {
        if (language == null) return;
        setState(() {
          if (source) {
            _source = language;
          } else {
            _target = language;
          }
        });
      },
    );
  }

  UiLine _message(AppFailure error) {
    return uiFailure(
      error,
      fallback: switch (error.type) {
        AppErrorType.noText => (text) => text.noTextInImage,
        AppErrorType.permissionDenied => (text) => text.cameraPermissionDenied,
        AppErrorType.languageUnsupported => (text) => text.scriptUnsupported,
        AppErrorType.fileCorrupt => (text) => text.imageUnreadable,
        AppErrorType.modelMissing => (text) => text.modelNotReadyToTranslate,
        AppErrorType.cancelled => (text) => text.canceled,
        AppErrorType.modelLoadFailed => (text) => text.translationDidNotStart,
        _ => (text) => text.photoTranslationFailed,
      },
    );
  }
}
