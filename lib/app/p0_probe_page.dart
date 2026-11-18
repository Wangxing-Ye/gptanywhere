import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/engines.dart';
import '../l10n/app_text.dart';

class OcrSample {
  const OcrSample({
    required this.label,
    required this.script,
    required this.bytes,
  });

  final String label;
  final String script;
  final Uint8List bytes;
}

/// P0 diagnostic surface. This is not the product translate screen.
class P0ProbePage extends StatefulWidget {
  const P0ProbePage({
    super.key,
    required this.engine,
    required this.samples,
    this.autoRun = true,
  });

  final OcrEngine engine;
  final List<OcrSample> samples;
  final bool autoRun;

  @override
  State<P0ProbePage> createState() => _P0ProbePageState();
}

class _P0ProbePageState extends State<P0ProbePage> {
  var _running = false;
  UiLine _phase = (text) => text.ready;
  final _lines = <String>[];

  @override
  void initState() {
    super.initState();
    if (widget.autoRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  Future<void> _run() async {
    if (_running) {
      return;
    }
    setState(() {
      _running = true;
      _phase = (text) => text.readingImage;
      _lines.clear();
    });
    for (final sample in widget.samples) {
      try {
        final document = await widget.engine.recognize(
          sample.bytes,
          sample.script,
        );
        final text = document.plainText;
        debugPrint('P0_OCR_RESULT ${sample.label} $text');
        if (!mounted) {
          return;
        }
        setState(() => _lines.add('${sample.label}: $text'));
      } on AppFailure catch (error) {
        debugPrint('P0_OCR_ERROR ${sample.label} $error');
        if (!mounted) {
          return;
        }
        setState(() => _lines.add('${sample.label}: ${error.type.name}'));
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _running = false;
      _phase = (text) => text.ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.appTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              text.appTitle,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(text.p0Note),
            const SizedBox(height: 16),
            Text(_phase(text)),
            const SizedBox(height: 16),
            if (_running) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            for (final line in _lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(line),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _running ? null : _run,
                child: Text(text.readAgain),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
