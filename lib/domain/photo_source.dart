import 'dart:typed_data';

/// System camera and gallery. The page does not open platform intents itself.
abstract class PhotoSource {
  Future<Uint8List?> pickFromGallery();

  Future<Uint8List?> takePicture();
}
