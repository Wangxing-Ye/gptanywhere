import 'dart:convert';

class CatalogVision {
  const CatalogVision({
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.downloadUrl,
  });

  final String fileName;
  final int sizeBytes;
  final String sha256;
  final String downloadUrl;
}

class CatalogPackage {
  const CatalogPackage({
    required this.id,
    required this.sizeBytes,
    required this.sha256,
    required this.downloadUrl,
    required this.capabilities,
    this.vision,
  });

  final String id;
  final int sizeBytes;
  final String sha256;
  final String downloadUrl;
  final List<String> capabilities;
  final CatalogVision? vision;

  String get fileName => '$id.gguf';
}

class ModelCatalog {
  const ModelCatalog(this.packages);

  static const primaryTextModelId = 'qwen3-1.7b-q4-k-m';

  final Map<String, CatalogPackage> packages;

  CatalogPackage? operator [](String id) => packages[id];

  static ModelCatalog parse(String jsonText) {
    final root = jsonDecode(jsonText) as Map<String, Object?>;
    final listed = root['packages'] as List<Object?>? ?? const [];
    final packages = <String, CatalogPackage>{};
    for (final item in listed) {
      final map = item as Map<String, Object?>;
      final capabilities = (map['capabilities'] as List<Object?>? ?? const [])
          .map((value) => value.toString())
          .toList();
      if (!capabilities.contains('text_translation')) continue;
      final id = map['id'] as String;
      packages[id] = CatalogPackage(
        id: id,
        sizeBytes: map['sizeBytes'] as int,
        sha256: map['sha256'] as String,
        downloadUrl: map['downloadUrl'] as String,
        capabilities: capabilities,
        vision: _vision(id, map['vision']),
      );
    }
    return ModelCatalog(packages);
  }
}

CatalogVision? _vision(String id, Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  return CatalogVision(
    fileName: '$id.mmproj.gguf',
    sizeBytes: raw['sizeBytes'] as int,
    sha256: raw['sha256'] as String,
    downloadUrl: raw['downloadUrl'] as String,
  );
}
