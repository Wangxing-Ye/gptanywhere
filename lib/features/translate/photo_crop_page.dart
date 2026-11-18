import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/app_text.dart';
import '../../services/crop_image.dart';

/// Result of the crop screen. A cancel leaves the previous photo in place.
class CropDecision {
  const CropDecision.kept(this.bytes) : unreadable = false;

  const CropDecision.canceled() : bytes = null, unreadable = false;

  const CropDecision.unreadable() : bytes = null, unreadable = true;

  final Uint8List? bytes;
  final bool unreadable;
}

/// Lets the user keep one rectangle of a photo taken on this device.
class PhotoCropPage extends StatefulWidget {
  const PhotoCropPage({super.key, required this.bytes});

  final Uint8List bytes;

  static const useKey = Key('photo-crop-use');
  static const cancelKey = Key('photo-crop-cancel');

  @override
  State<PhotoCropPage> createState() => _PhotoCropPageState();
}

enum _Handle { move, topLeft, topRight, bottomLeft, bottomRight }

class _PhotoCropPageState extends State<PhotoCropPage> {
  ui.Image? _image;
  Rect _crop = Rect.zero;
  var _failed = false;
  var _saving = false;
  _Handle? _handle;
  Rect? _origin;
  Offset? _panOrigin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final image = await decodeStillImage(widget.bytes);
    if (!mounted) {
      image?.dispose();
      return;
    }
    if (image == null) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _image = image;
      _crop = Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
    });
  }

  void _cancel() {
    Navigator.of(context).pop(const CropDecision.canceled());
  }

  bool _keepsWholePhoto(ui.Image image) {
    return _crop.left <= 0.5 &&
        _crop.top <= 0.5 &&
        _crop.right >= image.width - 0.5 &&
        _crop.bottom >= image.height - 0.5;
  }

  Future<void> _use() async {
    if (_saving || _failed) return;
    final image = _image;
    if (image == null || _keepsWholePhoto(image)) {
      Navigator.of(context).pop(CropDecision.kept(widget.bytes));
      return;
    }
    setState(() => _saving = true);
    try {
      final bytes = await encodeCrop(image, _crop);
      if (!mounted) return;
      Navigator.of(context).pop(CropDecision.kept(bytes));
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop(const CropDecision.unreadable());
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final image = _image;
    return Scaffold(
      appBar: AppBar(title: Text(text.cropPhoto)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: image == null
                  ? Center(
                      child: _failed
                          ? Text(text.imageUnreadable)
                          : const CircularProgressIndicator(),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final view = Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        final frame = _frame(view, image);
                        return GestureDetector(
                          onPanStart: (details) => _start(details, frame),
                          onPanUpdate: (details) => _move(details, frame),
                          onPanEnd: (_) => _end(),
                          onPanCancel: _end,
                          child: CustomPaint(
                            size: view,
                            painter: _CropPainter(
                              image: image,
                              destination: frame.destination,
                              hole: frame.hole,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(text.cropHint, textAlign: TextAlign.center),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: PhotoCropPage.cancelKey,
                      onPressed: _saving ? null : _cancel,
                      child: Text(text.cancel),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      key: PhotoCropPage.useKey,
                      onPressed: _failed || _saving ? null : _use,
                      child: Text(text.useCrop),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  _Frame _frame(Size view, ui.Image image) {
    final source = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, source, view);
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & view,
    );
    final scaleX = destination.width / source.width;
    final scaleY = destination.height / source.height;
    final hole = Rect.fromLTWH(
      destination.left + _crop.left * scaleX,
      destination.top + _crop.top * scaleY,
      _crop.width * scaleX,
      _crop.height * scaleY,
    );
    return _Frame(destination, hole, scaleX, scaleY);
  }

  void _start(DragStartDetails details, _Frame frame) {
    final handle = _hit(details.localPosition, frame.hole);
    if (handle == null) return;
    _handle = handle;
    _origin = _crop;
    _panOrigin = details.localPosition;
  }

  void _move(DragUpdateDetails details, _Frame frame) {
    final handle = _handle;
    final origin = _origin;
    final panOrigin = _panOrigin;
    final image = _image;
    if (handle == null ||
        origin == null ||
        panOrigin == null ||
        image == null) {
      return;
    }
    final delta = details.localPosition - panOrigin;
    final imageDelta = Offset(delta.dx / frame.scaleX, delta.dy / frame.scaleY);
    setState(() {
      _crop = _apply(origin, handle, imageDelta, image.width, image.height);
    });
  }

  void _end() {
    _handle = null;
    _origin = null;
    _panOrigin = null;
  }

  _Handle? _hit(Offset local, Rect hole) {
    const slop = 28.0;
    final corners = <_Handle, Offset>{
      _Handle.topLeft: hole.topLeft,
      _Handle.topRight: hole.topRight,
      _Handle.bottomLeft: hole.bottomLeft,
      _Handle.bottomRight: hole.bottomRight,
    };
    for (final entry in corners.entries) {
      if ((entry.value - local).distance <= slop) return entry.key;
    }
    if (hole.contains(local)) return _Handle.move;
    return null;
  }

  Rect _apply(
    Rect origin,
    _Handle handle,
    Offset delta,
    int imageWidth,
    int imageHeight,
  ) {
    var left = origin.left;
    var top = origin.top;
    var right = origin.right;
    var bottom = origin.bottom;
    switch (handle) {
      case _Handle.move:
        left += delta.dx;
        right += delta.dx;
        top += delta.dy;
        bottom += delta.dy;
      case _Handle.topLeft:
        left += delta.dx;
        top += delta.dy;
      case _Handle.topRight:
        right += delta.dx;
        top += delta.dy;
      case _Handle.bottomLeft:
        left += delta.dx;
        bottom += delta.dy;
      case _Handle.bottomRight:
        right += delta.dx;
        bottom += delta.dy;
    }
    return clampCrop(
      Rect.fromLTRB(left, top, right, bottom),
      imageWidth,
      imageHeight,
    );
  }
}

class _Frame {
  const _Frame(this.destination, this.hole, this.scaleX, this.scaleY);

  final Rect destination;
  final Rect hole;
  final double scaleX;
  final double scaleY;
}

class _CropPainter extends CustomPainter {
  const _CropPainter({
    required this.image,
    required this.destination,
    required this.hole,
  });

  final ui.Image image;
  final Rect destination;
  final Rect hole;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      destination,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final shade = Path()..addRect(Offset.zero & size);
    final opening = Path()..addRect(hole);
    canvas.drawPath(
      Path.combine(PathOperation.difference, shade, opening),
      Paint()..color = const Color(0x99000000),
    );
    canvas.drawRect(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    final third = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x88FFFFFF);
    canvas.drawLine(
      Offset(hole.left + hole.width / 3, hole.top),
      Offset(hole.left + hole.width / 3, hole.bottom),
      third,
    );
    canvas.drawLine(
      Offset(hole.left + hole.width * 2 / 3, hole.top),
      Offset(hole.left + hole.width * 2 / 3, hole.bottom),
      third,
    );
    canvas.drawLine(
      Offset(hole.left, hole.top + hole.height / 3),
      Offset(hole.right, hole.top + hole.height / 3),
      third,
    );
    canvas.drawLine(
      Offset(hole.left, hole.top + hole.height * 2 / 3),
      Offset(hole.right, hole.top + hole.height * 2 / 3),
      third,
    );
    final handle = Paint()..color = Colors.white;
    const radius = 7.0;
    for (final corner in [
      hole.topLeft,
      hole.topRight,
      hole.bottomLeft,
      hole.bottomRight,
    ]) {
      canvas.drawCircle(corner, radius, handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.destination != destination ||
        oldDelegate.hole != hole;
  }
}
