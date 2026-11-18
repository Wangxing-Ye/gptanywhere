import 'dart:io';

enum TransportResult { completed, paused }

abstract class ModelTransport {
  Future<TransportResult> fetch({
    required Uri url,
    required File partial,
    required bool Function() shouldPause,
    required void Function(int received, {int? total}) onProgress,
  });
}

class HttpModelTransport implements ModelTransport {
  @override
  Future<TransportResult> fetch({
    required Uri url,
    required File partial,
    required bool Function() shouldPause,
    required void Function(int received, {int? total}) onProgress,
  }) async {
    final client = HttpClient();
    try {
      while (true) {
        if (shouldPause()) return TransportResult.paused;
        final existing = await partial.exists() ? await partial.length() : 0;
        final request = await client.getUrl(url);
        request.followRedirects = true;
        request.headers.set(HttpHeaders.userAgentHeader, 'GPTAnywhere');
        if (existing > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
        }
        final response = await request.close();
        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
            existing > 0) {
          // The byte we asked for is past the end, so the local file already
          // holds the whole object. Do not discard it.
          await response.drain<void>();
          onProgress(existing, total: existing);
          return TransportResult.completed;
        }
        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          throw HttpException('HTTP ${response.statusCode}', uri: url);
        }
        final append =
            existing > 0 && response.statusCode == HttpStatus.partialContent;
        final total = _downloadObjectLength(response);
        if (!append && existing > 0 && response.contentLength == existing) {
          await response.drain<void>();
          onProgress(existing, total: total ?? existing);
          return TransportResult.completed;
        }
        if (!append && existing > 0) {
          await partial.writeAsBytes(const []);
        }
        final sink = partial.openWrite(
          mode: append ? FileMode.append : FileMode.write,
        );
        var received = append ? existing : 0;
        try {
          await for (final chunk in response) {
            if (shouldPause()) {
              await sink.close();
              onProgress(received, total: total);
              return TransportResult.paused;
            }
            sink.add(chunk);
            received += chunk.length;
            onProgress(received, total: total);
          }
        } finally {
          await sink.close();
        }
        return TransportResult.completed;
      }
    } finally {
      client.close(force: true);
    }
  }
}

int? _downloadObjectLength(HttpClientResponse response) {
  final range = response.headers.value(HttpHeaders.contentRangeHeader);
  if (range != null) {
    final slash = range.lastIndexOf('/');
    if (slash >= 0) {
      final parsed = int.tryParse(range.substring(slash + 1).trim());
      if (parsed != null && parsed > 0) return parsed;
    }
  }
  if (response.statusCode == HttpStatus.ok && response.contentLength > 0) {
    return response.contentLength;
  }
  return null;
}

abstract class NetworkGate {
  /// [target] is the model URL for this download. False means do not start.
  Future<bool> isOnline({Uri? target});
}

class SocketNetworkGate implements NetworkGate {
  @override
  Future<bool> isOnline({Uri? target}) async {
    final host = target?.host;
    if (host == null || host.isEmpty) return false;
    final port = target!.hasPort
        ? target.port
        : (target.scheme == 'http' ? 80 : 443);
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
