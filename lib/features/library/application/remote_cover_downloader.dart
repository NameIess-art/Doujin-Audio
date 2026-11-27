import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/playback_media_reference.dart';
import 'cover_artwork_store.dart';
import 'cover_image_cache_policy.dart';

const String _asmrOneAcceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

/// Owns remote artwork transport and its bounded request lifetime.
final class RemoteCoverDownloader {
  RemoteCoverDownloader({
    required Duration requestTimeout,
    required Duration downloadIdleTimeout,
    int maxFileBytes = maxRemoteCoverFileBytes,
  }) : _requestTimeout = requestTimeout,
       _downloadIdleTimeout = downloadIdleTimeout,
       _maxFileBytes = maxFileBytes;

  static const int _maxInMemoryBytes = 2 * 1024 * 1024;
  static const int _stagingFlushBytes = 4 * 1024 * 1024;
  static const int _maxRedirects = 5;

  final Duration _requestTimeout;
  final Duration _downloadIdleTimeout;
  final int _maxFileBytes;
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

  Future<HttpClientResponse?> _openResponseFollowingRedirects(
    String remoteUrl, {
    required void Function(HttpClientRequest request) onRequest,
    required bool Function() isCurrent,
  }) async {
    final client = _remoteHttpClient ??= HttpClient();
    client.connectionTimeout = _requestTimeout;
    var currentUri = Uri.parse(remoteUrl);
    for (var redirectCount = 0; redirectCount <= _maxRedirects; redirectCount++) {
      if (!isCurrent()) return null;
      final request = await client
          .getUrl(currentUri)
          .timeout(_requestTimeout);
      onRequest(request);
      // Resolve redirects explicitly so per-origin auth headers are only
      // attached to matching hosts and never leaked across 302 targets.
      request.followRedirects = false;
      for (final header
          in remoteCoverRequestHeadersForUrl(currentUri.toString()).entries) {
        request.headers.set(header.key, header.value);
      }
      final response = await request.close().timeout(_requestTimeout);
      if (!response.isRedirect) {
        return response;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.listen(null).cancel();
      if (location == null || location.trim().isEmpty) {
        return null;
      }
      currentUri = currentUri.resolve(location.trim());
    }
    return null;
  }

  Future<Uint8List?> fetch(String remoteUrl) async {
    HttpClientRequest? activeRequest;
    try {
      final response = await _openResponseFollowingRedirects(
        remoteUrl,
        onRequest: (request) => activeRequest = request,
        isCurrent: () => !_disposed,
      );
      if (response == null) return null;
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.contentLength > _maxFileBytes) {
        // Unread response bodies retain their connections. Cancel rather than
        // drain a rejected body, which may be oversized or never finish.
        await response.listen(null).cancel();
        return null;
      }

      final bytes = BytesBuilder(copy: false);
      final headerBytes = <int>[];
      var totalBytes = 0;
      await for (final chunk in response.timeout(_downloadIdleTimeout)) {
        totalBytes += chunk.length;
        if (totalBytes > _maxFileBytes) {
          throw const _RemoteCoverTooLargeException();
        }
        if (headerBytes.length < 64) {
          final remaining = 64 - headerBytes.length;
          headerBytes.addAll(chunk.take(remaining));
          if (headerBytes.length >= 64 &&
              detectCoverMimeType('', headerBytes) == null) {
            throw const _RemoteCoverInvalidFormatException();
          }
        }
        bytes.add(chunk);
      }
      if (totalBytes <= 0 || detectCoverMimeType('', headerBytes) == null) {
        return null;
      }
      return bytes.takeBytes();
    } catch (error, stackTrace) {
      activeRequest?.abort(error, stackTrace);
      AppLogService.warning(
        'Unable to cache remote artwork.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<String?> fetchAndStore(
    String remoteUrl, {
    required String logicalKey,
    required CoverArtworkStore artworkStore,
    required bool Function() isCurrent,
  }) async {
    HttpClientRequest? activeRequest;
    ({File file, IOSink sink, void Function() release})? staging;
    var stagingClosed = false;
    var stagingCommitted = false;
    try {
      final response = await _openResponseFollowingRedirects(
        remoteUrl,
        onRequest: (request) => activeRequest = request,
        isCurrent: isCurrent,
      );
      if (response == null) return null;
      if (!isCurrent() ||
          response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.contentLength > _maxFileBytes) {
        await response.listen(null).cancel();
        return null;
      }

      final headerBytes = <int>[];
      var headerValidated = false;
      BytesBuilder? inMemoryBytes = BytesBuilder(copy: false);
      _DigestSink? digestSink;
      ByteConversionSink? hashSink;
      var totalBytes = 0;
      var unflushedBytes = 0;

      Future<void> switchToStaging() async {
        final opened = await artworkStore.openStagingWrite();
        staging = opened;
        if (opened == null || !isCurrent()) {
          throw const _RemoteCoverCancelledException();
        }
        digestSink = _DigestSink();
        hashSink = sha256.startChunkedConversion(digestSink!);
        final buffered = inMemoryBytes?.takeBytes();
        inMemoryBytes = null;
        if (buffered != null && buffered.isNotEmpty) {
          hashSink!.add(buffered);
          opened.sink.add(buffered);
          unflushedBytes += buffered.length;
        }
      }

      await for (final chunk in response.timeout(_downloadIdleTimeout)) {
        if (!isCurrent()) {
          throw const _RemoteCoverCancelledException();
        }
        if (chunk.isEmpty) continue;
        totalBytes += chunk.length;
        if (totalBytes > _maxFileBytes) {
          throw const _RemoteCoverTooLargeException();
        }
        if (headerBytes.length < 64) {
          final remaining = 64 - headerBytes.length;
          headerBytes.addAll(chunk.take(remaining));
          if (headerBytes.length >= 64) {
            if (detectCoverMimeType('', headerBytes) == null) {
              throw const _RemoteCoverInvalidFormatException();
            }
            headerValidated = true;
          }
        }
        final preferStaging =
            totalBytes > _maxInMemoryBytes ||
            (headerValidated && response.contentLength > _maxInMemoryBytes);
        if (staging == null && preferStaging) {
          await switchToStaging();
        }
        if (staging != null) {
          hashSink!.add(chunk);
          staging!.sink.add(chunk);
          unflushedBytes += chunk.length;
          if (unflushedBytes >= _stagingFlushBytes) {
            await staging!.sink.flush();
            unflushedBytes = 0;
          }
        } else {
          inMemoryBytes!.add(chunk);
        }
      }

      if (!isCurrent() ||
          totalBytes <= 0 ||
          detectCoverMimeType('', headerBytes) == null) {
        return null;
      }

      if (staging != null) {
        hashSink!.close();
        await staging!.sink.flush();
        await staging!.sink.close();
        stagingClosed = true;
        final digest = digestSink!.digest.toString();
        final committedPath = await artworkStore.commitStagedFile(
          logicalKey: logicalKey,
          stagedFile: staging!.file,
          fileStem: digest,
        );
        stagingCommitted = true;
        return committedPath;
      }

      final bytes = inMemoryBytes!.takeBytes();
      return await artworkStore.putBytes(
        logicalKey: logicalKey,
        bytes: bytes,
        namespace: CoverArtworkNamespace.remote,
      );
    } on _RemoteCoverCancelledException {
      return null;
    } catch (error, stackTrace) {
      activeRequest?.abort(error, stackTrace);
      AppLogService.warning(
        'Unable to cache remote artwork.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    } finally {
      final activeStaging = staging;
      if (activeStaging != null) {
        try {
          if (!stagingClosed) {
            try {
              await activeStaging.sink.close();
            } catch (error, stackTrace) {
              AppLogService.warning(
                'Unable to close staged remote artwork.',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
          if (!stagingCommitted && await activeStaging.file.exists()) {
            await activeStaging.file.delete();
          }
        } catch (error, stackTrace) {
          AppLogService.warning(
            'Unable to remove staged remote artwork.',
            error: error,
            stackTrace: stackTrace,
          );
        } finally {
          activeStaging.release();
        }
      }
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

final class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest => _digest!;

  @override
  void add(Digest data) {
    _digest = data;
  }

  @override
  void close() {}
}

final class _RemoteCoverTooLargeException implements Exception {
  const _RemoteCoverTooLargeException();
}

final class _RemoteCoverInvalidFormatException implements Exception {
  const _RemoteCoverInvalidFormatException();
}

final class _RemoteCoverCancelledException implements Exception {
  const _RemoteCoverCancelledException();
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
      : PlaybackMediaReference.requestHeadersForUri(Uri.parse(url));
}
