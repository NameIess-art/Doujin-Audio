import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/music_track.dart';
import '../../../core/cache/app_cache_service.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';
import '../../player/domain/playback_track_cache.dart';
import '../domain/asmr_media_sources.dart';

class AsmrPlaybackCacheService implements PlaybackTrackCache {
  AsmrPlaybackCacheService({
    HttpClient Function()? httpClientFactory,
    Future<Directory> Function()? temporaryDirectory,
    this.requestTimeout = const Duration(seconds: 15),
    this.downloadIdleTimeout = const Duration(seconds: 30),
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static const String cacheDirectoryName = 'asmr_playback_cache';

  final HttpClient Function() _httpClientFactory;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration requestTimeout;
  final Duration downloadIdleTimeout;
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};
  final Set<HttpClient> _activeClients = <HttpClient>{};
  final Queue<Completer<bool>> _waitingTransfers = Queue<Completer<bool>>();
  int _activeTransfers = 0;
  bool _disposed = false;

  @override
  Future<String?> cacheTrack(MusicTrack track, {String? playedPath}) async {
    if (_disposed) return null;
    if (track.remoteMetadataKind != 'asmr.one') return null;

    final source = _cacheableSource(track, playedPath: playedPath);
    if (source == null) return null;

    try {
      final root = await _cacheRoot();
      if (_disposed) return null;
      final target = File(path.join(root.path, _fileNameFor(source, track)));
      final existing = _inFlight[target.path];
      if (existing != null) return existing;

      late final Future<String?> task;
      task =
          _cacheTarget(
            root: root,
            target: target,
            source: source,
            expectedBytes: _expectedBytes(track, source),
          ).whenComplete(() {
            if (identical(_inFlight[target.path], task)) {
              _inFlight.remove(target.path);
            }
          });
      _inFlight[target.path] = task;
      return task;
    } catch (error, stackTrace) {
      _logFailure(error, stackTrace);
      return null;
    }
  }

  Future<String?> _cacheTarget({
    required Directory root,
    required File target,
    required String source,
    required int? expectedBytes,
  }) async {
    final temp = File('${target.path}.part');
    final lease = AppCacheService.protectPaths(<String>[temp.path]);
    try {
      if (_disposed) return null;
      await root.create(recursive: true);
      final legacy = File(
        path.join(root.path, path.basename(target.path).substring(3)),
      );
      if (await legacy.exists()) await legacy.delete();
      if (await target.exists()) {
        final length = await target.length();
        if (length > 0 && (expectedBytes == null || length == expectedBytes)) {
          await target.setLastModified(DateTime.now());
          return target.path;
        }
        await target.delete();
      }

      if (await temp.exists()) {
        await temp.delete();
      }
      await _download(source, temp, expectedBytes: expectedBytes);
      if (_disposed) return null;
      final length = await temp.length();
      if (length <= 0 || (expectedBytes != null && length != expectedBytes)) {
        throw const HttpException('ASMR playback cache length mismatch.');
      }
      await temp.rename(target.path);
      AppCacheService.scheduleEnforce();
      return target.path;
    } catch (error, stackTrace) {
      _logFailure(error, stackTrace);
      return null;
    } finally {
      lease.release();
      if (await temp.exists()) {
        await temp.delete();
      }
    }
  }

  static String? _cacheableSource(MusicTrack track, {String? playedPath}) {
    final candidates = <String>[
      ?playedPath,
      track.path,
      ..._playbackUrls(track),
    ];
    for (final candidate in candidates) {
      final value = candidate.trim();
      if (PathMatcher.isRemoteUri(value)) return value;
    }
    return null;
  }

  static Iterable<String> _playbackUrls(MusicTrack track) sync* {
    final raw = track.remoteMetadata?['playbackUrls'];
    if (raw is! List) return;
    for (final value in raw.whereType<String>()) {
      yield value;
    }
  }

  static int? _expectedBytes(MusicTrack track, String source) {
    final size = track.fileSizeBytes;
    if (size == null || size <= 0) return null;
    final raw = track.remoteMetadata?['fullQualityPlaybackUrls'];
    if (raw is! List) return null;
    final uri = Uri.tryParse(source);
    for (final candidate in raw.whereType<String>()) {
      if (candidate == source) return size;
      final original = Uri.tryParse(candidate);
      if (uri != null &&
          original != null &&
          isAsmrApiHost(uri.host) &&
          isAsmrApiHost(original.host) &&
          uri.path == original.path &&
          uri.query == original.query) {
        return size;
      }
    }
    return null;
  }

  Future<Directory> _cacheRoot() async {
    final temp = await _temporaryDirectory();
    return Directory(path.join(temp.path, cacheDirectoryName));
  }

  static String _fileNameFor(String source, MusicTrack track) {
    final hash = sha1.convert(utf8.encode(source)).toString();
    final extension = _extensionFor(source, track.displayName);
    return 'v2-$hash$extension';
  }

  static String _extensionFor(String source, String displayName) {
    final uri = Uri.tryParse(source);
    final uriExtension = uri == null ? '' : path.extension(uri.path);
    if (_isSafeExtension(uriExtension)) return uriExtension.toLowerCase();
    final nameExtension = path.extension(displayName);
    return _isSafeExtension(nameExtension) ? nameExtension.toLowerCase() : '';
  }

  static bool _isSafeExtension(String value) {
    return value.length > 1 &&
        value.length <= 10 &&
        RegExp(r'^\.[A-Za-z0-9]+$').hasMatch(value);
  }

  Future<void> _download(
    String source,
    File target, {
    required int? expectedBytes,
  }) async {
    if (!await _acquireTransfer()) return;
    HttpClient? client;
    HttpClientRequest? request;
    IOSink? sink;
    try {
      if (_disposed) return;
      client = _httpClientFactory();
      client.autoUncompress = false;
      _activeClients.add(client);
      try {
        client.connectionTimeout = requestTimeout;
      } catch (_) {
        // Some injected clients do not expose socket options.
      }
      request = await client.getUrl(Uri.parse(source)).timeout(requestTimeout);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Unexpected ASMR playback cache status ${response.statusCode}',
          uri: Uri.parse(source),
        );
      }
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        throw const HttpException('Unsupported ASMR playback cache encoding.');
      }
      final responseBytes = response.contentLength;
      if (expectedBytes != null &&
          responseBytes >= 0 &&
          responseBytes != expectedBytes) {
        throw const HttpException(
          'ASMR playback cache response length mismatch.',
        );
      }
      var receivedBytes = 0;
      sink = target.openWrite();
      await sink.addStream(
        response.timeout(downloadIdleTimeout).map((chunk) {
          if (_disposed) throw StateError('ASMR playback cache was disposed.');
          receivedBytes += chunk.length;
          if ((responseBytes >= 0 && receivedBytes > responseBytes) ||
              (expectedBytes != null && receivedBytes > expectedBytes)) {
            throw const HttpException(
              'ASMR playback cache exceeded expected length.',
            );
          }
          return chunk;
        }),
      );
      await sink.flush();
      if (receivedBytes == 0 ||
          (responseBytes >= 0 && receivedBytes != responseBytes) ||
          (expectedBytes != null && receivedBytes != expectedBytes)) {
        throw const HttpException('ASMR playback cache incomplete response.');
      }
    } catch (error) {
      request?.abort(error);
      rethrow;
    } finally {
      try {
        await sink?.close();
      } finally {
        client?.close(force: true);
        _activeClients.remove(client);
        _releaseTransfer();
      }
    }
  }

  Future<bool> _acquireTransfer() {
    if (_disposed) return Future<bool>.value(false);
    if (_activeTransfers < 2) {
      _activeTransfers++;
      return Future<bool>.value(true);
    }
    final waiting = Completer<bool>();
    _waitingTransfers.addLast(waiting);
    return waiting.future;
  }

  void _releaseTransfer() {
    if (_waitingTransfers.isNotEmpty && !_disposed) {
      _waitingTransfers.removeFirst().complete(true);
    } else {
      _activeTransfers--;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    while (_waitingTransfers.isNotEmpty) {
      _waitingTransfers.removeFirst().complete(false);
    }
    for (final client in _activeClients.toList(growable: false)) {
      client.close(force: true);
    }
    await Future.wait(_inFlight.values.toList(growable: false));
    _activeClients.clear();
    _inFlight.clear();
  }

  static void _logFailure(Object error, StackTrace stackTrace) {
    AppLogService.error(
      'asmr_playback_cache_failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
