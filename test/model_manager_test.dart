import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptanywhere/domain/app_error.dart';
import 'package:gptanywhere/services/model_catalog.dart';
import 'package:gptanywhere/services/model_manager.dart';
import 'package:gptanywhere/services/model_transport.dart';

void main() {
  test('failed download keeps the active model', () async {
    final harness = await _Harness.create();
    await harness.writeActive('good-model');
    harness.transport.failAfter = 4;

    await expectLater(
      harness.models.download(ModelCatalog.primaryTextModelId),
      throwsA(isA<AppFailure>()),
    );

    expect(await harness.active.readAsString(), 'good-model');
    expect(harness.transport.calls, 1);
  });

  test('offline download does not start and keeps the active model', () async {
    final harness = await _Harness.create(online: false);
    await harness.writeActive('good-model');

    await expectLater(
      harness.models.download(ModelCatalog.primaryTextModelId),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.detail,
          'detail',
          '当前没有网络，没有开始下载。',
        ),
      ),
    );

    expect(harness.transport.calls, 0);
    expect(harness.models.downloadWasStarted, isFalse);
    expect(await harness.active.readAsString(), 'good-model');
  });

  test('import with the wrong bytes keeps the active model', () async {
    final harness = await _Harness.create();
    await harness.writeActive('good-model');
    final wrong = File('${harness.root.path}/wrong.gguf');
    await wrong.writeAsString('not-the-model');

    await expectLater(
      harness.models.importFile(
        id: ModelCatalog.primaryTextModelId,
        sourcePath: wrong.path,
      ),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.type,
          'type',
          AppErrorType.fileCorrupt,
        ),
      ),
    );

    expect(await harness.active.readAsString(), 'good-model');
  });

  test('a path-like id is rejected before any file is written', () async {
    final harness = await _Harness.create();
    await expectLater(
      harness.models.importFile(
        id: '../escape',
        sourcePath: harness.active.path,
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(harness.root.listSync(), isEmpty);
  });

  test('a matching download replaces only after the hash matches', () async {
    final harness = await _Harness.create();
    final installed = await harness.models.download(
      ModelCatalog.primaryTextModelId,
    );
    expect(await File(installed.path).readAsBytes(), harness.payload);
    expect(
      await harness.models.installed(ModelCatalog.primaryTextModelId),
      isNotNull,
    );
  });

  test('the catalog pairs a vision file only where one is published', () {
    final catalog = ModelCatalog.parse(
      File('models/manifest.json').readAsStringSync(),
    );
    expect(catalog[ModelCatalog.primaryTextModelId]!.vision, isNull);
    expect(catalog['gemma-3-1b-it-q4-k-m']!.vision, isNull);
    final gemma = catalog['gemma-3-4b-it-q4-k-m']!.vision!;
    expect(gemma.fileName, 'gemma-3-4b-it-q4-k-m.mmproj.gguf');
    expect(gemma.sizeBytes, 851251104);
    expect(gemma.downloadUrl, contains('mmproj-model-f16.gguf'));
    expect(
      catalog['gemma-4-e2b-it-q4-0']!.vision!.downloadUrl,
      contains('Q8_0'),
    );
    expect(
      catalog['gemma-4-e4b-it-q4-0']!.vision!.downloadUrl,
      isNot(contains('mtp')),
    );
    expect(catalog['lfm2.5-1.2b-instruct-q4-k-m']!.vision, isNull);
    expect(catalog['lfm3-1.7b-q4-k-m']!.vision, isNull);
    final lfmVision = catalog['lfm2.5-vl-1.6b-q4-k-m']!.vision!;
    expect(lfmVision.fileName, 'lfm2.5-vl-1.6b-q4-k-m.mmproj.gguf');
    expect(lfmVision.sizeBytes, 583109888);
    expect(lfmVision.downloadUrl, contains('mmproj-LFM2.5-VL-1.6b-Q8_0.gguf'));
    final minicpm = catalog['minicpm-v-4.7-1b-q4-k-m']!;
    expect(minicpm.sizeBytes, 672003680);
    final minicpmVision = minicpm.vision!;
    expect(minicpmVision.fileName, 'minicpm-v-4.7-1b-q4-k-m.mmproj.gguf');
    expect(minicpmVision.sizeBytes, 1110117984);
    expect(minicpmVision.downloadUrl, contains('mmproj-model-f16.gguf'));
    expect(minicpmVision.downloadUrl, isNot(contains('4x')));
    expect(catalog['minicpm5-1b-q4-k-m']!.vision, isNull);
    expect(catalog['minicpm5-1b-q4-k-m']!.sizeBytes, 688065920);
    expect(catalog['minicpm5-2b-q4-k-m']!.vision, isNull);
    expect(catalog['minicpm5-2b-q4-k-m']!.sizeBytes, 1561318368);
  });

  test('a download continues into that model\'s vision file', () async {
    final harness = await _VisionHarness.create();
    final seen = <int>[];
    await harness.models.download(
      'gemma-3-4b-it-q4-k-m',
      onProgress: (received, total) => seen.add(total),
    );
    expect(harness.transport.urls, [
      'http://127.0.0.1/language.gguf',
      'http://127.0.0.1/vision.gguf',
    ]);
    expect(seen.last, harness.language.length + harness.vision.length);
    expect(
      await File(
        '${harness.root.path}/gemma-3-4b-it-q4-k-m.gguf',
      ).readAsBytes(),
      harness.language,
    );
    expect(
      await File(
        '${harness.root.path}/gemma-3-4b-it-q4-k-m.mmproj.gguf',
      ).readAsBytes(),
      harness.vision,
    );
    expect(
      await harness.models.isFullyInstalled('gemma-3-4b-it-q4-k-m'),
      isTrue,
    );
  });

  test('an installed language model downloads only the vision file', () async {
    final harness = await _VisionHarness.create();
    await harness.writeLanguage();
    await harness.models.download('gemma-3-4b-it-q4-k-m');
    expect(harness.transport.urls, ['http://127.0.0.1/vision.gguf']);
    expect(
      await File(
        '${harness.root.path}/gemma-3-4b-it-q4-k-m.gguf',
      ).readAsBytes(),
      harness.language,
    );
  });

  test('a failed vision download keeps the language model', () async {
    final harness = await _VisionHarness.create(failVision: true);
    await expectLater(
      harness.models.download('gemma-3-4b-it-q4-k-m'),
      throwsA(isA<AppFailure>()),
    );
    expect(
      await File(
        '${harness.root.path}/gemma-3-4b-it-q4-k-m.gguf',
      ).readAsBytes(),
      harness.language,
    );
    expect(
      File(
        '${harness.root.path}/gemma-3-4b-it-q4-k-m.mmproj.gguf',
      ).existsSync(),
      isFalse,
    );
    expect(
      await harness.models.isFullyInstalled('gemma-3-4b-it-q4-k-m'),
      isFalse,
    );
  });

  test(
    'offline vision download does not start after the language file',
    () async {
      final harness = await _VisionHarness.create(onlineCalls: 1);
      await expectLater(
        harness.models.download('gemma-3-4b-it-q4-k-m'),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.detail,
            'detail',
            '当前没有网络，没有开始下载。',
          ),
        ),
      );
      expect(harness.transport.urls, ['http://127.0.0.1/language.gguf']);
      expect(
        await File(
          '${harness.root.path}/gemma-3-4b-it-q4-k-m.gguf',
        ).readAsBytes(),
        harness.language,
      );
    },
  );
}

class _Harness {
  _Harness(this.root, this.models, this.transport, this.payload);

  final Directory root;
  final ModelManager models;
  final _MemoryTransport transport;
  final List<int> payload;

  File get active =>
      File('${root.path}/${ModelCatalog.primaryTextModelId}.gguf');

  static Future<_Harness> create({bool online = true}) async {
    final root = await Directory.systemTemp.createTemp('ta_models');
    final payload = [1, 2, 3, 4, 5, 6, 7, 8];
    final digest = sha256.convert(payload).toString();
    final transport = _MemoryTransport(payload);
    final models = ModelManager(
      catalog: ModelCatalog({
        ModelCatalog.primaryTextModelId: CatalogPackage(
          id: ModelCatalog.primaryTextModelId,
          sizeBytes: payload.length,
          sha256: digest,
          downloadUrl: 'http://127.0.0.1/model.gguf',
          capabilities: const ['text_translation'],
        ),
      }),
      root: root,
      transport: transport,
      network: _Gate(online),
    );
    return _Harness(root, models, transport, payload);
  }

  Future<void> writeActive(String contents) async {
    await root.create(recursive: true);
    await active.writeAsString(contents);
  }
}

class _Gate implements NetworkGate {
  _Gate(this.online);
  final bool online;

  @override
  Future<bool> isOnline({Uri? target}) async => online;
}

class _VisionHarness {
  _VisionHarness(
    this.root,
    this.models,
    this.transport,
    this.language,
    this.vision,
  );

  final Directory root;
  final ModelManager models;
  final _UrlTransport transport;
  final List<int> language;
  final List<int> vision;

  static Future<_VisionHarness> create({
    bool failVision = false,
    int? onlineCalls,
  }) async {
    final root = await Directory.systemTemp.createTemp('ta_vision');
    const language = [1, 2, 3];
    const vision = [4, 5];
    final transport = _UrlTransport({
      'http://127.0.0.1/language.gguf': language,
      'http://127.0.0.1/vision.gguf': vision,
    }, failUrl: failVision ? 'http://127.0.0.1/vision.gguf' : null);
    final models = ModelManager(
      catalog: ModelCatalog({
        'gemma-3-4b-it-q4-k-m': CatalogPackage(
          id: 'gemma-3-4b-it-q4-k-m',
          sizeBytes: language.length,
          sha256: sha256.convert(language).toString(),
          downloadUrl: 'http://127.0.0.1/language.gguf',
          capabilities: const ['text_translation'],
          vision: CatalogVision(
            fileName: 'gemma-3-4b-it-q4-k-m.mmproj.gguf',
            sizeBytes: vision.length,
            sha256: sha256.convert(vision).toString(),
            downloadUrl: 'http://127.0.0.1/vision.gguf',
          ),
        ),
      }),
      root: root,
      transport: transport,
      network: _LimitedGate(onlineCalls),
    );
    return _VisionHarness(root, models, transport, language, vision);
  }

  Future<void> writeLanguage() async {
    final file = File('${root.path}/gemma-3-4b-it-q4-k-m.gguf');
    await file.writeAsBytes(language);
    await File(
      '${file.path}.sha256',
    ).writeAsString(sha256.convert(language).toString());
  }
}

class _LimitedGate implements NetworkGate {
  _LimitedGate(this.onlineCalls);
  final int? onlineCalls;
  var calls = 0;

  @override
  Future<bool> isOnline({Uri? target}) async {
    calls += 1;
    final limit = onlineCalls;
    if (limit == null) return true;
    return calls <= limit;
  }
}

class _UrlTransport implements ModelTransport {
  _UrlTransport(this.files, {this.failUrl});

  final Map<String, List<int>> files;
  final String? failUrl;
  final urls = <String>[];

  @override
  Future<TransportResult> fetch({
    required Uri url,
    required File partial,
    required bool Function() shouldPause,
    required void Function(int received, {int? total}) onProgress,
  }) async {
    final key = url.toString();
    urls.add(key);
    if (key == failUrl) throw const SocketException('reset');
    final payload = files[key]!;
    await partial.writeAsBytes(payload);
    onProgress(payload.length);
    return TransportResult.completed;
  }
}

class _MemoryTransport implements ModelTransport {
  _MemoryTransport(this.payload);

  final List<int> payload;
  var calls = 0;
  var failAfter = -1;

  @override
  Future<TransportResult> fetch({
    required Uri url,
    required File partial,
    required bool Function() shouldPause,
    required void Function(int received, {int? total}) onProgress,
  }) async {
    calls += 1;
    final existing = await partial.exists() ? await partial.length() : 0;
    final slice = payload.sublist(existing.clamp(0, payload.length));
    var received = existing;
    for (final byte in slice) {
      if (shouldPause()) return TransportResult.paused;
      await partial.writeAsBytes([byte], mode: FileMode.append);
      received += 1;
      onProgress(received);
      if (failAfter >= 0 && received >= failAfter) {
        throw const SocketException('reset');
      }
    }
    return TransportResult.completed;
  }
}
