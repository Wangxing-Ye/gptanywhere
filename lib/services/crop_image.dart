import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Longest side kept after a crop, matching the gallery pick limit.
const cropMaxEdge = 1600;

/// Decodes one still frame. Returns null when the bytes are not an image.
Future<ui.Image?> decodeStillImage(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } catch (_) {
    return null;
  }
}

/// Keeps [crop] in image pixels and encodes it as PNG.
Future<Uint8List> encodeCrop(ui.Image image, Rect crop) async {
  final clamped = clampCrop(crop, image.width, image.height);
  var width = clamped.width.round();
  var height = clamped.height.round();
  if (width < 1) width = 1;
  if (height < 1) height = 1;
  final longSide = width > height ? width : height;
  if (longSide > cropMaxEdge) {
    final scale = cropMaxEdge / longSide;
    width = (width * scale).round().clamp(1, cropMaxEdge);
    height = (height * scale).round().clamp(1, cropMaxEdge);
  }
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    image,
    clamped,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final scaled = await picture.toImage(width, height);
  picture.dispose();
  final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
  scaled.dispose();
  if (data == null) {
    throw StateError('crop');
  }
  return data.buffer.asUint8List();
}

/// Pulls [crop] inside the image and keeps at least one pixel on each side.
Rect clampCrop(Rect crop, int imageWidth, int imageHeight) {
  final width = imageWidth.toDouble();
  final height = imageHeight.toDouble();
  final minX = _minSide(imageWidth);
  final minY = _minSide(imageHeight);
  var left = crop.left;
  var top = crop.top;
  var right = crop.right;
  var bottom = crop.bottom;
  if (right - left < minX) right = left + minX;
  if (bottom - top < minY) bottom = top + minY;
  if (left < 0) {
    right -= left;
    left = 0;
  }
  if (top < 0) {
    bottom -= top;
    top = 0;
  }
  if (right > width) {
    left -= right - width;
    right = width;
  }
  if (bottom > height) {
    top -= bottom - height;
    bottom = height;
  }
  left = left.clamp(0, width - minX);
  top = top.clamp(0, height - minY);
  right = right.clamp(left + minX, width);
  bottom = bottom.clamp(top + minY, height);
  return Rect.fromLTRB(left, top, right, bottom);
}

double _minSide(int edge) {
  if (edge <= 1) return 1;
  final portion = edge * 0.08;
  if (portion < 1) return 1;
  if (portion > 48) return 48;
  return portion;
}
