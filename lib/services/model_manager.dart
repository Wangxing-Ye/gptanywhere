import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../domain/app_error.dart';
import 'model_catalog.dart';
import 'model_transport.dart';

class _Blob {
  const _Blob({
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.url,
  });

  final String fileName;
  final int sizeBytes;
  final String sha256;
  final String url;
}

class InstalledModel {
  const InstalledModel({required this.id, required this.path});

  final String id;
  final String path;
}

class ModelManager {
  ModelManager({
    required this.catalog,
    required this.root,
    required this.transport,
    required this.network,
  });

  final ModelCatalog catalog;
  final Directory root;
  final ModelTransport transport;
  final NetworkGate network;

  final _paused = <String>{};
  var _downloadStarted = false;

  bool get downloadWasStarted => _downloadStarted;

  Future<InstalledModel?> installed(String id) async {
    final package = _require(id);
    final blob = _languageBlob(package);
    final active = _named(blob.fileName);
    if (!active.existsSync()) return null;
    if (active.lengthSync() != blob.sizeBytes || !await _hashMatches(blob)) {
      throw AppFailure(AppErrorType.fileCorrupt, detail: id);
    }
    return InstalledModel(id: id, path: active.path);
  }

  /// This model's vision file when the catalog lists one and the bytes match.
  Future<String?> readyVisionPath(String id) async {
    final vision = catalog[id]?.vision;
    if (vision == null) return null;
    if (!await _matches(_visionBlob(vision))) return null;
    return _named(vision.fileName).path;
  }

  /// Language file is present, and the vision file too when this model has one.
  Future<bool> isFullyInstalled(String id) async {
    final package = catalog[id];
    if (package == null) return false;
    try {
      if (await installed(id) == null) return false;
    } on AppFailure {
      return false;
    }
    final vision = package.vision;
    if (vision == null) return true;
    return _matches(_visionBlob(vision));
  }

  Future<InstalledModel> download(
    String id, {
    void Function(int received, int total)? onProgress,
  }) async {
    final package = _require(id);
    final language = _languageBlob(package);
    final vision = package.vision == null ? null : _visionBlob(package.vision!);
    final needLanguage = !await _matches(language);
    final needVision = vision != null && !await _matches(vision);
    if (!needLanguage && !needVision) {
      return (await installed(id))!;
    }
    final parts = <_Blob>[
      if (needLanguage) language,
      if (vision != null && needVision) vision,
    ];
    final combined = parts.fold<int>(0, (sum, part) => sum + part.sizeBytes);
    var completed = 0;
    InstalledModel? activated;
    _paused.remove(id);
    await root.create(recursive: true);
    for (final part in parts) {
      final uri = Uri.parse(part.url);
      if (!await network.isOnline(target: uri)) {
        throw AppFailure(AppErrorType.modelMissing, detail: '当前没有网络，没有开始下载。');
      }
      _downloadStarted = true;
      final partial = _partialNamed(part.fileName);
      TransportResult result;
      try {
        result = await transport.fetch(
          url: uri,
          partial: partial,
          shouldPause: () => _paused.contains(id),
          onProgress: (received, {int? total}) =>
              onProgress?.call(completed + received, combined),
        );
      } catch (_) {
        throw AppFailure(AppErrorType.fileCorrupt, detail: '下载中断，已保留原来的模型。');
      }
      if (result == TransportResult.paused) {
        throw AppFailure(AppErrorType.cancelled, detail: '下载已暂停。');
      }
      final String path;
      try {
        path = await _verifyAndActivateBlob(id, part, partial);
      } on AppFailure {
        if (part.fileName == language.fileName) rethrow;
        throw AppFailure(AppErrorType.fileCorrupt, detail: '下载中断，已保留原来的模型。');
      }
      if (part.fileName == language.fileName) {
        activated = InstalledModel(id: id, path: path);
      }
      completed += part.sizeBytes;
    }
    return activated ?? (await installed(id))!;
  }

  void pause(String id) {
    _paused.add(id);
  }

  Future<InstalledModel> importFile({
    required String id,
    required String sourcePath,
  }) async {
    final package = _require(id);
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw AppFailure(AppErrorType.fileCorrupt, detail: id);
    }
    await root.create(recursive: true);
    final incoming = _incomingFile(package);
    if (await incoming.exists()) await incoming.delete();
    try {
      await source.copy(incoming.path);
    } catch (_) {
      if (await incoming.exists()) await incoming.delete();
      throw AppFailure(AppErrorType.fileCorrupt, detail: id);
    }
    return _verifyAndActivate(package, incoming);
  }

  Future<InstalledModel> _verifyAndActivate(
    CatalogPackage package,
    File incoming,
  ) async {
    final path = await _verifyAndActivateBlob(
      package.id,
      _languageBlob(package),
      incoming,
    );
    return InstalledModel(id: package.id, path: path);
  }

  Future<String> _verifyAndActivateBlob(
    String id,
    _Blob blob,
    File incoming,
  ) async {
    final active = _named(blob.fileName);
    final previous = await active.exists() ? await active.length() : null;
    try {
      if (!await incoming.exists() || await incoming.length() != blob.sizeBytes) {
        throw AppFailure(AppErrorType.fileCorrupt, detail: id);
      }
      final actual = await _hash(incoming);
      if (actual != blob.sha256) {
        throw AppFailure(AppErrorType.fileCorrupt, detail: id);
      }
      await _replaceActive(incoming, active);
      await _sidecarNamed(blob.fileName).writeAsString(blob.sha256);
      return active.path;
    } catch (error) {
      if (await incoming.exists()) await incoming.delete();
      if (previous != null && !await active.exists()) {
        throw AppFailure(AppErrorType.fileCorrupt, detail: id);
      }
      if (error is AppFailure) rethrow;
      throw AppFailure(AppErrorType.fileCorrupt, detail: id);
    }
  }

  Future<bool> _matches(_Blob blob) async {
    final active = _named(blob.fileName);
    if (!active.existsSync() || active.lengthSync() != blob.sizeBytes) {
      return false;
    }
    return _hashMatches(blob);
  }

  Future<bool> _hashMatches(_Blob blob) async {
    final recorded = _readSidecarNamed(blob.fileName);
    if (recorded == blob.sha256) return true;
    final active = _named(blob.fileName);
    if (!active.existsSync()) return false;
    if (await _hash(active) != blob.sha256) return false;
    await _sidecarNamed(blob.fileName).writeAsString(blob.sha256);
    return true;
  }

  _Blob _languageBlob(CatalogPackage package) {
    return _Blob(
      fileName: package.fileName,
      sizeBytes: package.sizeBytes,
      sha256: package.sha256,
      url: package.downloadUrl,
    );
  }

  _Blob _visionBlob(CatalogVision vision) {
    return _Blob(
      fileName: vision.fileName,
      sizeBytes: vision.sizeBytes,
      sha256: vision.sha256,
      url: vision.downloadUrl,
    );
  }

  Future<void> _replaceActive(File incoming, File active) async {
    final backup = File('${active.path}.bak');
    if (await backup.exists()) await backup.delete();
    if (await active.exists()) {
      await active.rename(backup.path);
    }
    try {
      await _move(incoming, active);
    } catch (error) {
      if (await backup.exists() && !await active.exists()) {
        await backup.rename(active.path);
      }
      rethrow;
    }
    if (await backup.exists()) await backup.delete();
  }

  Future<void> _move(File from, File to) async {
    try {
      await from.rename(to.path);
    } on FileSystemException {
      await from.copy(to.path);
      await from.delete();
    }
  }

  CatalogPackage _require(String id) {
    if (id.contains('/') || id.contains('\\') || id.contains('..')) {
      throw AppFailure(AppErrorType.fileCorrupt, detail: id);
    }
    final package = catalog[id];
    if (package == null) {
      throw AppFailure(AppErrorType.fileCorrupt, detail: id);
    }
    final active = _activeFile(package);
    final rootPath = root.absolute.path;
    if (!active.absolute.path.startsWith(
          '$rootPath${Platform.pathSeparator}',
        ) &&
        !active.absolute.path.startsWith('$rootPath/')) {
      throw AppFailure(AppErrorType.fileCorrupt, detail: id);
    }
    return package;
  }

  File _activeFile(CatalogPackage package) => _named(package.fileName);

  File _incomingFile(CatalogPackage package) =>
      File('${_named(package.fileName).path}.incoming');

  File _named(String fileName) =>
      File('${root.path}${Platform.pathSeparator}$fileName');

  File _partialNamed(String fileName) => File('${_named(fileName).path}.partial');

  File _sidecarNamed(String fileName) => File('${_named(fileName).path}.sha256');

  String? _readSidecarNamed(String fileName) {
    final file = _sidecarNamed(fileName);
    if (!file.existsSync()) return null;
    return file.readAsStringSync().trim();
  }

  Future<String> _hash(File file) {
    final path = file.path;
    return Isolate.run(() async {
      final digest = await sha256.bind(File(path).openRead()).first;
      return digest.toString();
    });
  }
}
