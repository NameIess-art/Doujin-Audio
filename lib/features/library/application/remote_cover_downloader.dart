import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../../core/logging/app_log_service.dart';
import 'cover_image_cache_policy.dart';
import '../../../core/media/path_matcher.dart';

const String _asmrOneAcceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

/// Owns remote artwork transport and its bounded request lifetime.
final class RemoteCoverDownloader {
  RemoteCoverDownloader({
    required Duration requestTimeout,
    required Duration downloadIdleTimeout,
  }) : _requestTimeout = requestTimeout,
       _downloadIdleTimeout = downloadIdleTimeout;
  final Duration _requestTimeout;
  final Duration _downloadIdleTimeout;
  final Queue<Completer<void>> _remoteDownloadWaiters = Queue();
  HttpClient? _remoteHttpClient;
  int _activeRemoteDownloads = 0;
  bool _disposed = false;

  Future<String?> run(Future<String?> Function() download) async {
    if (_disposed) return null;
    if (_activeRemoteDownloads >= 4) {
      final waiter = Completer<void>();
      _remoteDownloadWaiters.add(waiter);
      await waiter.future;
      if (_disposed) return null;
    } else {
      _activeRemoteDownloads++;
    }
    try {
      return await download();
    } finally {
      if (_remoteDownloadWaiters.isNotEmpty) {
        _remoteDownloadWaiters.removeFirst().complete();
      } else {
        _activeRemoteDownloads--;
      }
    }
  }

  Future<Uint8List?> fetch(String remoteUrl) async {
    HttpClientRequest? request;
    try {
      final client = _remoteHttpClient ??= HttpClient();
      client.connectionTimeout = _requestTimeout;
      request = await client
          .getUrl(Uri.parse(remoteUrl))
          .timeout(_requestTimeout);
      for (final header in remoteCoverRequestHeadersForUrl(remoteUrl).entries) {
        request.headers.set(header.key, header.value);
      }
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      if (response.contentLength > maxCoverFileBytes) return null;

      final bytes = BytesBuilder(copy: false);
      final headerBytes = <int>[];
      var totalBytes = 0;
      await for (final chunk in response.timeout(_downloadIdleTimeout)) {
        totalBytes += chunk.length;
        if (totalBytes > maxCoverFileBytes) {
          throw const _RemoteCoverTooLargeException();
        }
        if (headerBytes.length < 64) {
          final remaining = 64 - headerBytes.length;
          headerBytes.addAll(chunk.take(remaining));
        }
        bytes.add(chunk);
      }
      if (totalBytes <= 0 || detectCoverMimeType('', headerBytes) == null) {
        return null;
      }
      return bytes.takeBytes();
    } catch (error, stackTrace) {
      request?.abort(error, stackTrace);
      AppLogService.warning(
        'Unable to cache remote artwork.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<bool> isUsablePath(String? coverPath) async {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return false;
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return true;
    }
    try {
      final file = File(value);
      if (!await file.exists() || await file.length() <= 0) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _remoteHttpClient?.close(force: true);
    _remoteHttpClient = null;
    while (_remoteDownloadWaiters.isNotEmpty) {
      _remoteDownloadWaiters.removeFirst().complete();
    }
  }
}

final class _RemoteCoverTooLargeException implements Exception {
  const _RemoteCoverTooLargeException();
}

@visibleForTesting
Map<String, String> remoteCoverRequestHeadersForUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  final isAsmrOne =
      host == 'api.asmr.one' ||
      host == 'api.asmr-100.com' ||
      host == 'api.asmr-200.com' ||
      host == 'api.asmr-300.com';
  return isAsmrOne
      ? const <String, String>{
          HttpHeaders.acceptLanguageHeader: _asmrOneAcceptLanguage,
        }
      : const <String, String>{};
}
