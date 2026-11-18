enum AppErrorType {
  modelMissing,
  languageUnsupported,
  fileCorrupt,
  insufficientStorage,
  insufficientMemory,
  noText,
  noSpeech,
  permissionDenied,
  audioInterrupted,
  modelLoadFailed,
  cancelled,
  purchaseFailed,
}

class AppFailure implements Exception {
  const AppFailure(this.type, {this.detail});

  final AppErrorType type;
  final String? detail;

  @override
  String toString() => detail == null ? type.name : '${type.name}: $detail';
}
