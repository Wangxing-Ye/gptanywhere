import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/engines.dart';

/// ML Kit Text Recognition v2 through the Flutter plugin.
/// Android artifacts are the bundled `com.google.mlkit` models, not the
/// Play-services downloader. The recognizer is closed after each call.
class MlkitOcrEngine implements OcrEngine {
  @override
  Future<void> dispose() async {}

  @override
  Future<OcrDocument> recognize(Uint8List image, String script) async {
    final kind = switch (script) {
      'latin' => TextRecognitionScript.latin,
      'chinese' => TextRecognitionScript.chinese,
      'japanese' => TextRecognitionScript.japanese,
      'korean' => TextRecognitionScript.korean,
      // The plugin spells this script devanagiri.
      'devanagari' => TextRecognitionScript.devanagiri,
      _ => throw AppFailure(AppErrorType.languageUnsupported, detail: script),
    };

    final recognizer = TextRecognizer(script: kind);
    final file = File(
      '${Directory.systemTemp.path}/ta_ocr_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    try {
      await file.writeAsBytes(image, flush: true);
      final size = await _imageSize(image);
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(file.path),
      );
      final blocks = <OcrBlock>[];
      for (var i = 0; i < recognized.blocks.length; i++) {
        final block = recognized.blocks[i];
        final text = block.text.trim();
        if (text.isEmpty) {
          continue;
        }
        final box = block.boundingBox;
        blocks.add(
          OcrBlock(
            id: 'b$i',
            text: text,
            left: _unit(box.left, size.width),
            top: _unit(box.top, size.height),
            right: _unit(box.right, size.width),
            bottom: _unit(box.bottom, size.height),
          ),
        );
      }
      if (blocks.isEmpty) {
        throw const AppFailure(AppErrorType.noText);
      }
      return OcrDocument(
        blocks: blocks,
        readingOrder: [for (final block in blocks) block.id],
      );
    } finally {
      await recognizer.close();
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<({double width, double height})> _imageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final width = frame.image.width.toDouble();
    final height = frame.image.height.toDouble();
    frame.image.dispose();
    codec.dispose();
    if (width <= 0 || height <= 0) {
      throw const AppFailure(AppErrorType.fileCorrupt);
    }
    return (width: width, height: height);
  }

  double _unit(double value, double extent) {
    if (extent <= 0) {
      return 0;
    }
    final unit = value / extent;
    if (unit < 0) {
      return 0;
    }
    if (unit > 1) {
      return 1;
    }
    return unit;
  }
}
