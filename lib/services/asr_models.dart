import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../domain/app_error.dart';
import '../domain/app_settings.dart';
import 'asr_catalog.dart';
import 'model_transport.dart';

class AsrInstall {
  const AsrInstall({
    required this.engine,
    required this.modelPath,
    this.tokensPath,
    this.convPath,
    this.encoderPath,
    this.decoderPath,
    this.tokenizerPath,
  });

  final AsrEngineChoice engine;
  final String modelPath;
  final String? tokensPath;
  final String? convPath;
  final String? encoderPath;
  final String? decoderPath;
  final String? tokenizerPath;
}

abstract class AsrStore {
  int? listedBytes(AsrEngineChoice engine) => null;

  Future<AsrInstall?> installed(AsrEngineChoice engine);
  Future<AsrInstall> download(
    AsrEngineChoice engine, {
    void Function(int received, int total)? onProgress,
  });
}

abstract class TarExtractor {
  Future<void> extractNamed({
    required File archive,
    required Directory destination,
    required Set<String> names,
    int? expectedBytes,
    void Function(int written)? onProgress,
  });
}

class AsrModels implements AsrStore {
  AsrModels({
    required this.manifestJson,
    required this.root,
    required this.transport,
    required this.network,
    required this.extractor,
  });

  final String manifestJson;
  final Directory root;
  final ModelTransport transport;
  final NetworkGate network;
  final TarExtractor extractor;

  @override
  int? listedBytes(AsrEngineChoice engine) {
    try {
      return asrSpecFor(engine, manifestJson).sizeBytes;
    } on AppFailure {
      return null;
    }
  }

  @override
  Future<AsrInstall?> installed(AsrEngineChoice engine) async {
    final spec = asrSpecFor(engine, manifestJson);
    if (spec.files.isNotEmpty) return _installedQwen(spec, engine);
    if (spec.archive) return _installedSense(spec, engine);
    return _installedFile(spec, engine);
  }

  @override
  Future<AsrInstall> download(
    AsrEngineChoice engine, {
    void Function(int received, int total)? onProgress,
  }) async {
    final spec = asrSpecFor(engine, manifestJson);
    if (spec.files.isNotEmpty) {
      return _downloadQwen(spec, engine, onProgress);
    }
    final uri = Uri.parse(spec.downloadUrl);
    if (!await network.isOnline(target: uri)) {
      throw const AppFailure(
        AppErrorType.modelMissing,
        detail: '当前没有网络，没有开始下载。',
      );
    }
    await root.create(recursive: true);
    final partial = File('${root.path}/${spec.id}.partial');
    try {
      final result = await transport.fetch(
        url: uri,
        partial: partial,
        shouldPause: () => false,
        onProgress: (received, {int? total}) => onProgress?.call(
          received,
          spec.archive ? (total ?? 0) : spec.sizeBytes,
        ),
      );
      if (result == TransportResult.paused) {
        throw const AppFailure(AppErrorType.cancelled, detail: '下载已暂停。');
      }
    } catch (error) {
      if (error is AppFailure) rethrow;
      throw const AppFailure(
        AppErrorType.fileCorrupt,
        detail: '下载中断，已保留原来的模型。',
      );
    }
    if (spec.archive) {
      return _activateSense(spec, engine, partial, onProgress);
    }
    return _activateFile(spec, engine, partial);
  }

  Future<AsrInstall?> _installedFile(
    AsrSpec spec,
    AsrEngineChoice engine,
  ) async {
    final file = File('${root.path}/${spec.payloadName}');
    if (!file.existsSync() || file.lengthSync() != spec.sizeBytes) return null;
    final side = _sidecar(file);
    final recorded = side.existsSync() ? side.readAsStringSync().trim() : '';
    if (recorded != spec.sha256) {
      if (await _hash(file) != spec.sha256) {
        throw AppFailure(AppErrorType.fileCorrupt, detail: spec.id);
      }
      side.writeAsStringSync(spec.sha256);
    }
    return AsrInstall(engine: engine, modelPath: file.path);
  }

  Future<AsrInstall?> _installedSense(
    AsrSpec spec,
    AsrEngineChoice engine,
  ) async {
    final dir = Directory('${root.path}/$senseVoiceModelId');
    final model = File('${dir.path}/model.onnx');
    final tokens = File('${dir.path}/tokens.txt');
    if (!model.existsSync() ||
        model.lengthSync() != spec.sizeBytes ||
        !tokens.existsSync() ||
        tokens.lengthSync() == 0) {
      return null;
    }
    final recorded = File('${dir.path}/model.sha256');
    if (!recorded.existsSync() ||
        recorded.readAsStringSync().trim() != spec.sha256) {
      if (await _hash(model) != spec.sha256) {
        throw AppFailure(AppErrorType.fileCorrupt, detail: spec.id);
      }
      recorded.writeAsStringSync(spec.sha256);
    }
    return AsrInstall(
      engine: engine,
      modelPath: model.path,
      tokensPath: tokens.path,
    );
  }

  Future<AsrInstall> _activateFile(
    AsrSpec spec,
    AsrEngineChoice engine,
    File partial,
  ) async {
    final active = File('${root.path}/${spec.payloadName}');
    if (partial.lengthSync() != spec.sizeBytes ||
        await _hash(partial) != spec.sha256) {
      if (partial.existsSync()) partial.deleteSync();
      throw AppFailure(AppErrorType.fileCorrupt, detail: spec.id);
    }
    final backup = File('${active.path}.bak');
    if (backup.existsSync()) backup.deleteSync();
    if (active.existsSync()) active.renameSync(backup.path);
    try {
      partial.renameSync(active.path);
      _sidecar(active).writeAsStringSync(spec.sha256);
    } catch (_) {
      if (!active.existsSync() && backup.existsSync()) {
        backup.renameSync(active.path);
      }
      throw AppFailure(AppErrorType.fileCorrupt, detail: spec.id);
    }
    if (backup.existsSync()) backup.deleteSync();
    return AsrInstall(engine: engine, modelPath: active.path);
  }

  Future<AsrInstall> _activateSense(
    AsrSpec spec,
    AsrEngineChoice engine,
    File partial,
    void Function(int received, int total)? onProgress,
  ) async {
    final staging = Directory('${root.path}/$senseVoiceModelId.next');
    staging.createSync(recursive: true);
    try {
      onProgress?.call(0, -spec.sizeBytes);
      await extractor.extractNamed(
        archive: partial,
        destination: staging,
        names: const {'model.onnx', 'tokens.txt'},
        expectedBytes: spec.sizeBytes,
        onProgress: (written) => onProgress?.call(written, -spec.sizeBytes),
      );
      final model = File('${staging.path}/model.onnx');
      final tokens = File('${staging.path}/tokens.txt');
      if (!model.existsSync() ||
          model.lengthSync() != spec.sizeBytes ||
          await _hash(model) != spec.sha256 ||
          !tokens.existsSync() ||
          tokens.lengthSync() == 0) {
        if (partial.existsSync()) partial.deleteSync();
        throw const AppFailure(
          AppErrorType.fileCorrupt,
          detail: '听写模型无法校验，请重新下载。',
        );
      }
      File('${staging.path}/model.sha256').writeAsStringSync(spec.sha256);
    } catch (error) {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      if (error is AppFailure && error.detail == '听写模型无法校验，请重新下载。') {
        rethrow;
      }
      throw const AppFailure(
        AppErrorType.fileCorrupt,
        detail: '听写模型无法解压，已保留下载的文件。',
      );
    }
    final active = Directory('${root.path}/$senseVoiceModelId');
    final backup = Directory('${root.path}/$senseVoiceModelId.bak');
    if (backup.existsSync()) backup.deleteSync(recursive: true);
    if (active.existsSync()) active.renameSync(backup.path);
    try {
      staging.renameSync(active.path);
    } catch (_) {
      if (!active.existsSync() && backup.existsSync()) {
        backup.renameSync(active.path);
      }
      throw const AppFailure(
        AppErrorType.fileCorrupt,
        detail: '下载中断，已保留原来的模型。',
      );
    }
    if (backup.existsSync()) backup.deleteSync(recursive: true);
    if (partial.existsSync()) partial.deleteSync();
    return AsrInstall(
      engine: engine,
      modelPath: '${active.path}/model.onnx',
      tokensPath: '${active.path}/tokens.txt',
    );
  }

  Future<AsrInstall?> _installedQwen(
    AsrSpec spec,
    AsrEngineChoice engine,
  ) async {
    final dir = Directory('${root.path}/${spec.id}');
    final tokenDir = Directory('${root.path}/$qwen3AsrTokenizerId');
    final tokenizer = asrTokenizerSpec(manifestJson);
    if (!await _filesPresent(dir, spec.files)) return null;
    if (!await _filesPresent(tokenDir, tokenizer.files)) return null;
    return _qwenInstall(engine, dir, tokenDir, spec);
  }

  Future<AsrInstall> _downloadQwen(
    AsrSpec spec,
    AsrEngineChoice engine,
    void Function(int received, int total)? onProgress,
  ) async {
    final tokenizer = asrTokenizerSpec(manifestJson);
    final probe = Uri.parse(spec.files.first.downloadUrl);
    if (!await network.isOnline(target: probe)) {
      throw const AppFailure(
        AppErrorType.modelMissing,
        detail: '当前没有网络，没有开始下载。',
      );
    }
    await root.create(recursive: true);
    final tokenDir = Directory('${root.path}/$qwen3AsrTokenizerId');
    final active = Directory('${root.path}/${spec.id}');
    final needTokenizer = !await _alreadyGood(tokenDir, tokenizer.files);
    final needModel = !await _alreadyGood(active, spec.files);
    if (!needTokenizer && !needModel) {
      return _qwenInstall(engine, active, tokenDir, spec);
    }
    final total =
        (needModel ? spec.sizeBytes : 0) +
        (needTokenizer ? tokenizer.sizeBytes : 0);
    final tokenStaging = Directory('${root.path}/$qwen3AsrTokenizerId.next');
    final staging = Directory('${root.path}/${spec.id}.next');
    try {
      var received = 0;
      if (needTokenizer) {
        if (tokenStaging.existsSync()) {
          tokenStaging.deleteSync(recursive: true);
        }
        tokenStaging.createSync(recursive: true);
        received = await _fetchFiles(
          tokenizer.files,
          tokenStaging,
          received,
          total,
          onProgress,
        );
      }
      if (needModel) {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
        staging.createSync(recursive: true);
        await _fetchFiles(spec.files, staging, received, total, onProgress);
      }
    } catch (error) {
      if (tokenStaging.existsSync()) tokenStaging.deleteSync(recursive: true);
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      if (error is AppFailure) rethrow;
      throw const AppFailure(
        AppErrorType.fileCorrupt,
        detail: '下载中断，已保留原来的模型。',
      );
    }
    try {
      if (needTokenizer) _swapDirectory(tokenStaging, tokenDir);
      if (needModel) _swapDirectory(staging, active);
    } catch (error) {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      if (tokenStaging.existsSync()) {
        tokenStaging.deleteSync(recursive: true);
      }
      if (error is AppFailure) rethrow;
      throw const AppFailure(
        AppErrorType.fileCorrupt,
        detail: '下载中断，已保留原来的模型。',
      );
    }
    return _qwenInstall(engine, active, tokenDir, spec);
  }

  Future<int> _fetchFiles(
    List<AsrFile> files,
    Directory staging,
    int received,
    int total,
    void Function(int received, int total)? onProgress,
  ) async {
    var done = received;
    final overall = total;
    for (final file in files) {
      final partial = File('${staging.path}/${file.name}.partial');
      final result = await transport.fetch(
        url: Uri.parse(file.downloadUrl),
        partial: partial,
        shouldPause: () => false,
        onProgress: (got, {int? total}) =>
            onProgress?.call(done + got, overall),
      );
      if (result == TransportResult.paused) {
        throw const AppFailure(AppErrorType.cancelled, detail: '下载已暂停。');
      }
      if (partial.lengthSync() != file.sizeBytes ||
          await _hash(partial) != file.sha256) {
        if (partial.existsSync()) partial.deleteSync();
        throw const AppFailure(
          AppErrorType.fileCorrupt,
          detail: '听写模型无法校验，请重新下载。',
        );
      }
      final active = File('${staging.path}/${file.name}');
      partial.renameSync(active.path);
      File('${active.path}.sha256').writeAsStringSync(file.sha256);
      done += file.sizeBytes;
      onProgress?.call(done, total);
    }
    return done;
  }

  Future<bool> _alreadyGood(Directory dir, List<AsrFile> files) async {
    try {
      return await _filesPresent(dir, files);
    } on AppFailure {
      return false;
    }
  }

  Future<bool> _filesPresent(Directory dir, List<AsrFile> files) async {
    for (final file in files) {
      final active = File('${dir.path}/${file.name}');
      if (!active.existsSync() || active.lengthSync() != file.sizeBytes) {
        return false;
      }
      final side = File('${active.path}.sha256');
      final recorded = side.existsSync() ? side.readAsStringSync().trim() : '';
      if (recorded == file.sha256) continue;
      if (await _hash(active) != file.sha256) {
        throw AppFailure(AppErrorType.fileCorrupt, detail: file.name);
      }
      side.writeAsStringSync(file.sha256);
    }
    return files.isNotEmpty;
  }

  AsrInstall _qwenInstall(
    AsrEngineChoice engine,
    Directory dir,
    Directory tokenDir,
    AsrSpec spec,
  ) {
    final conv = File('${dir.path}/conv_frontend.onnx');
    final encoder = _onnxName(spec.files, 'encoder');
    final decoder = _onnxName(spec.files, 'decoder');
    return AsrInstall(
      engine: engine,
      modelPath: conv.path,
      convPath: conv.path,
      encoderPath: '${dir.path}/$encoder',
      decoderPath: '${dir.path}/$decoder',
      tokenizerPath: tokenDir.path,
    );
  }

  String _onnxName(List<AsrFile> files, String prefix) {
    return files
        .map((file) => file.name)
        .firstWhere(
          (name) => name.startsWith(prefix) && name.endsWith('.onnx'),
        );
  }

  void _swapDirectory(Directory staging, Directory active) {
    final backup = Directory('${active.path}.bak');
    if (backup.existsSync()) backup.deleteSync(recursive: true);
    if (active.existsSync()) active.renameSync(backup.path);
    try {
      staging.renameSync(active.path);
    } catch (_) {
      if (!active.existsSync() && backup.existsSync()) {
        backup.renameSync(active.path);
      }
      throw const AppFailure(
        AppErrorType.fileCorrupt,
        detail: '下载中断，已保留原来的模型。',
      );
    }
    if (backup.existsSync()) backup.deleteSync(recursive: true);
  }

  File _sidecar(File file) => File('${file.path}.sha256');

  Future<String> _hash(File file) {
    return Isolate.run(() async {
      final digest = await sha256.bind(File(file.path).openRead()).first;
      return digest.toString();
    });
  }
}

class PlatformTarExtractor implements TarExtractor {
  PlatformTarExtractor({MethodChannel? channel, EventChannel? events})
    : _channel = channel ?? const MethodChannel(_channelName),
      _events = events ?? const EventChannel(_eventName);

  static const _channelName = 'dev.local.gptanywhere/asr';
  static const _eventName = 'dev.local.gptanywhere/asr_extract';
  final MethodChannel _channel;
  final EventChannel _events;

  @override
  Future<void> extractNamed({
    required File archive,
    required Directory destination,
    required Set<String> names,
    int? expectedBytes,
    void Function(int written)? onProgress,
  }) async {
    final subscription = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final written = event['extractBytes'];
      if (written is int) onProgress?.call(written);
    });
    try {
      await _channel.invokeMethod<void>('extract', {
        'archive': archive.path,
        'destination': destination.path,
        'names': names.toList(),
        'expectedBytes': expectedBytes,
      });
    } on PlatformException catch (error) {
      throw AppFailure(AppErrorType.fileCorrupt, detail: error.code);
    } finally {
      await subscription.cancel();
    }
  }
}
