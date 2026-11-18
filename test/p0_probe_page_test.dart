import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptanywhere/app/p0_probe_page.dart';
import 'package:gptanywhere/domain/engines.dart';

class _FakeOcrEngine implements OcrEngine {
  @override
  Future<void> dispose() async {}

  @override
  Future<OcrDocument> recognize(Uint8List image, String script) async {
    return OcrDocument(
      blocks: [
        OcrBlock(
          id: 'b0',
          text: script == 'chinese'
              ? '今天下午三点不见，不是五点。'
              : 'The train does not leave at 15:00.',
          left: 0,
          top: 0,
          right: 1,
          bottom: 0.2,
        ),
      ],
      readingOrder: const ['b0'],
    );
  }
}

void main() {
  testWidgets('probe renders injected ocr text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: P0ProbePage(
          engine: _FakeOcrEngine(),
          samples: [
            OcrSample(
              label: 'zh',
              script: 'chinese',
              bytes: Uint8List.fromList(const [1, 2, 3]),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('今天下午三点不见，不是五点。'), findsOneWidget);
    expect(find.text('GPTAnywhere'), findsWidgets);
  });

  test('unsupported script is an app failure', () async {
    final engine = _RejectingEngine();
    expect(
      () => engine.recognize(Uint8List(0), 'arabic'),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.type,
          'type',
          AppErrorType.languageUnsupported,
        ),
      ),
    );
  });
}

class _RejectingEngine implements OcrEngine {
  @override
  Future<void> dispose() async {}

  @override
  Future<OcrDocument> recognize(Uint8List image, String script) async {
    throw AppFailure(AppErrorType.languageUnsupported, detail: script);
  }
}
