import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptanywhere/services/model_transport.dart';

void main() {
  test(
    'a finished partial is kept when the server rejects the next byte',
    () async {
      final payload = List<int>.generate(32, (index) => index);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
      });
      final root = Directory.systemTemp.createTempSync('ta_http');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final partial = File('${root.path}/model.partial');
      await partial.writeAsBytes(payload);

      final result = await HttpModelTransport().fetch(
        url: Uri.parse('http://127.0.0.1:${server.port}/model'),
        partial: partial,
        shouldPause: () => false,
        onProgress: (_, {int? total}) {},
      );

      expect(result, TransportResult.completed);
      expect(partial.readAsBytesSync(), payload);
    },
  );

  test('a full file is not replaced when the server repeats it', () async {
    final payload = List<int>.generate(32, (index) => index);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.contentLength = payload.length;
      request.response.add(List<int>.filled(payload.length, 9));
      await request.response.close();
    });
    final root = Directory.systemTemp.createTempSync('ta_http_full');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final partial = File('${root.path}/model.partial');
    await partial.writeAsBytes(payload);

    final result = await HttpModelTransport().fetch(
      url: Uri.parse('http://127.0.0.1:${server.port}/model'),
      partial: partial,
      shouldPause: () => false,
      onProgress: (_, {int? total}) {},
    );

    expect(result, TransportResult.completed);
    expect(partial.readAsBytesSync(), payload);
  });
}
