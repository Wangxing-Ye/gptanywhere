import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../domain/app_error.dart';
import '../domain/photo_source.dart';

class ImagePickerPhotoSource implements PhotoSource {
  ImagePickerPhotoSource({ImagePicker? picker, MethodChannel? cameraChannel})
    : _picker = picker ?? ImagePicker(),
      _camera = cameraChannel ?? const MethodChannel(_cameraChannel);

  final ImagePicker _picker;
  final MethodChannel _camera;

  static const _cameraChannel = 'dev.local.gptanywhere/camera';

  @override
  Future<Uint8List?> pickFromGallery() => _pick(ImageSource.gallery);

  @override
  Future<Uint8List?> takePicture() {
    if (Platform.isAndroid) return _takeAndroidPicture();
    return _pick(ImageSource.camera);
  }

  Future<Uint8List?> _takeAndroidPicture() async {
    try {
      final path = await _camera.invokeMethod<String>('takePicture');
      if (path == null || path.isEmpty) return null;
      final file = File(path);
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          throw const AppFailure(AppErrorType.fileCorrupt);
        }
        return bytes;
      } finally {
        if (file.existsSync()) file.deleteSync();
      }
    } on AppFailure {
      rethrow;
    } on PlatformException catch (error) {
      throw _fromPlatform(error);
    } on FileSystemException {
      throw const AppFailure(AppErrorType.fileCorrupt);
    }
  }

  Future<Uint8List?> _pick(ImageSource source) async {
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (file == null) return null;
      return await file.readAsBytes();
    } on PlatformException catch (error) {
      throw _fromPlatform(error);
    } on FileSystemException {
      throw const AppFailure(AppErrorType.fileCorrupt);
    }
  }

  AppFailure _fromPlatform(PlatformException error) {
    return switch (error.code) {
      'camera_access_denied' ||
      'photo_access_denied' ||
      'camera_access_restricted' => AppFailure(
        AppErrorType.permissionDenied,
        detail: error.code,
      ),
      _ => AppFailure(AppErrorType.fileCorrupt, detail: error.code),
    };
  }
}
