import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gptanywhere/main.dart' as app;

/// On-device text translation. Before launching, place the verified Qwen file at
/// /sdcard/Android/data/dev.local.gptanywhere/files/qwen3-1.7b-q4-k-m.gguf.
/// The test copies it into the app support directory and then uses the real engine.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'zh en both ways, traditional prompt, and cancel',
    (tester) async {
      await _stageModel();
      await app.main();
      await _until(
        tester,
        const Duration(minutes: 4),
        () {
          return _status(tester).contains('当前模型:');
        },
        () => 'model did not become ready: ${_status(tester)}',
      );

      const zh = '今天下午三点不见，不是五点。';
      final zhEn = await _translate(tester, zh);
      _log('zh-en', zhEn);
      expect(zhEn, isNotEmpty);
      expect(RegExp('[A-Za-z]').hasMatch(zhEn), isTrue);

      await tester.tap(find.byTooltip('交换语言'));
      await tester.pump(const Duration(milliseconds: 300));

      const en = 'The train does not leave at 15:00.';
      final enZh = await _translate(tester, en);
      _log('en-zh', enZh);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(enZh), isTrue);

      await tester.tap(find.text('简体中文'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('繁体中文').last);
      await tester.pump(const Duration(milliseconds: 300));
      final hant = await _translate(tester, en);
      _log('en-hant', hant);
      expect(hant, isNotEmpty);

      await tester.tap(find.byTooltip('交换语言'));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.byType(TextField),
        '请翻译并保留标记 CANCELCHECK。今天下午三点在车站见面。',
      );
      await tester.tap(find.widgetWithText(FilledButton, '翻译'));
      await _until(
        tester,
        const Duration(seconds: 45),
        () {
          return _status(tester) == '翻译中';
        },
        () => 'translation did not start: ${_status(tester)}',
      );
      await tester.tap(find.text('取消'));
      await _until(
        tester,
        const Duration(seconds: 20),
        () {
          return _status(tester) == '已取消';
        },
        () => 'cancel did not settle: ${_status(tester)}',
      );

      final after = await _translate(tester, zh);
      _log('after-cancel', after);
      expect(after.contains('CANCELCHECK'), isFalse);
      expect(RegExp('[A-Za-z]').hasMatch(after), isTrue);

      final again = await _translate(tester, '你好');
      _log('again', again);
      expect(RegExp('[A-Za-z]').hasMatch(again), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

const _modelBytes = 1282439264;
const _modelName = 'qwen3-1.7b-q4-k-m.gguf';

Future<void> _stageModel() async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory('${support.path}/models');
  await dir.create(recursive: true);
  final dest = File('${dir.path}/$_modelName');
  if (await dest.exists() && await dest.length() == _modelBytes) return;
  final external = File(
    '/storage/emulated/0/Android/data/dev.local.gptanywhere/files/$_modelName',
  );
  if (!await external.exists()) {
    fail('model file is missing at ${external.path}');
  }
  final size = await external.length();
  if (size != _modelBytes) {
    fail('model file size is $size');
  }
  await external.copy(dest.path);
}

void _log(String label, String text) {
  // ignore: avoid_print
  print('P1_TEXT $label $text');
}

String _status(WidgetTester tester) {
  final widget = tester.widget<Text>(find.byKey(const Key('translate-status')));
  return widget.data ?? '';
}

String _output(WidgetTester tester) {
  final widget = tester.widget<Text>(
    find.byKey(const Key('translation-output')),
  );
  return widget.data ?? '';
}

Future<String> _translate(WidgetTester tester, String source) async {
  await tester.enterText(find.byType(TextField), source);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.widgetWithText(FilledButton, '翻译'));
  var sawRunning = false;
  await _until(
    tester,
    const Duration(minutes: 4),
    () {
      final status = _status(tester);
      if (status == '翻译中') sawRunning = true;
      return sawRunning && status != '翻译中';
    },
    () =>
        'translation did not finish: ${_status(tester)} output=${_output(tester)}',
  );
  final status = _status(tester);
  final output = _output(tester);
  expect(status, isNot(contains('没有')));
  expect(output, isNot('尚无译文'));
  return output;
}

Future<void> _until(
  WidgetTester tester,
  Duration timeout,
  bool Function() ready,
  String Function() message,
) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 400));
    if (ready()) return;
  }
  fail(message());
}
