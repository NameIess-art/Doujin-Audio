import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum NetworkProbeStatus { untested, testing, success, failed }

class NetworkProbeResult {
  const NetworkProbeResult(this.status, {this.milliseconds});
  final NetworkProbeStatus status;
  final int? milliseconds;
}

/// Page-scoped diagnostics; every run owns its connection and cancellation.
class NetworkServiceProbe extends ChangeNotifier {
  NetworkServiceProbe({
    HttpClient Function()? createClient,
    this.timeout = const Duration(seconds: 10),
  }) : _createClient = createClient ?? HttpClient.new;

  final HttpClient Function() _createClient;
  final Duration timeout;
  final _clients = <String, HttpClient>{};
  final _results = <String, NetworkProbeResult>{};
  bool _disposed = false;

  NetworkProbeResult result(String key) =>
      _results[key] ?? const NetworkProbeResult(NetworkProbeStatus.untested);

  Future<void> test(String key, Uri uri) async {
    _clients.remove(key)?.close(force: true);
    final client = _createClient()..connectionTimeout = timeout;
    _clients[key] = client;
    _results[key] = const NetworkProbeResult(NetworkProbeStatus.testing);
    notifyListeners();
    final watch = Stopwatch()..start();
    try {
      final status = await (() async {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.userAgentHeader, 'DoujinAudio/1.0');
        final response = await request.close();
        return response.statusCode;
      })().timeout(timeout);
      if (_disposed || !identical(_clients[key], client)) return;
      _results[key] = status >= 200 && status < 300
          ? NetworkProbeResult(
              NetworkProbeStatus.success,
              milliseconds: watch.elapsedMilliseconds,
            )
          : const NetworkProbeResult(NetworkProbeStatus.failed);
    } catch (_) {
      if (_disposed || !identical(_clients[key], client)) return;
      _results[key] = const NetworkProbeResult(NetworkProbeStatus.failed);
    } finally {
      client.close(force: true);
      if (!_disposed && identical(_clients[key], client)) {
        _clients.remove(key);
        notifyListeners();
      }
    }
  }

  void reset() {
    for (final client in _clients.values) {
      client.close(force: true);
    }
    _clients.clear();
    _results.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    reset();
    super.dispose();
  }
}
