import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptanywhere/services/crop_image.dart';

void main() {
  testWidgets('a crop keeps only the selected rectangle', (tester) async {
    late Uint8List bytes;
    var width = 0;
    var height = 0;
    ByteData? pixels;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 4, 4),
        Paint()..color = const Color(0xFFFF0000),
      );
      canvas.drawRect(
        const Rect.fromLTWH(1, 1, 2, 2),
        Paint()..color = const Color(0xFF00FF00),
      );
      final image = await recorder.endRecording().toImage(4, 4);
      bytes = await encodeCrop(image, const Rect.fromLTWH(1, 1, 2, 2));
      image.dispose();
      final cropped = await decodeStillImage(bytes);
      width = cropped?.width ?? 0;
      height = cropped?.height ?? 0;
      pixels = await cropped?.toByteData();
      cropped?.dispose();
    });
    expect(width, 2);
    expect(height, 2);
    final color = pixels;
    if (color == null) {
      fail('missing pixels');
    }
    expect(color.getUint8(0), 0);
    expect(color.getUint8(1), 255);
    expect(color.getUint8(2), 0);
  });

  test('a crop rectangle stays inside the image', () {
    final fitted = clampCrop(const Rect.fromLTWH(-10, -4, 30, 20), 8, 6);
    expect(fitted.left, greaterThanOrEqualTo(0));
    expect(fitted.top, greaterThanOrEqualTo(0));
    expect(fitted.right, lessThanOrEqualTo(8));
    expect(fitted.bottom, lessThanOrEqualTo(6));
    expect(fitted.width, greaterThanOrEqualTo(1));
    expect(fitted.height, greaterThanOrEqualTo(1));
  });
}
