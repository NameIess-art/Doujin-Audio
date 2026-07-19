import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/music_track.dart';
import '../../settings/application/app_cache_service.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';

class AsmrPlaybackCacheService {
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
  bool _disposed = false;

  Future<String?> cacheTrack(MusicTrack track, {String? playedPath}) async {
    if (_disposed) return null;
    if (track.remoteMetadataKind != 'asmr.one') return null;

    final source = _cacheableSource(track, playedPath: playedPath);
    if (source == null) return null;

    try {
      final root = await _cacheRoot();
      final target = File(path.join(root.path, _fileNameFor(source, track)));
      final existing = _inFlight[target.path];
      if (existing != null) return existing;

      late final Future<String?> task;
      task = _cacheTarget(root: root, target: target, source: source)
          .whenComplete(() {
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
  }) async {
    final temp = File('${target.path}.part');
    try {
      if (_disposed) return null;
      await root.create(recursive: true);
      if (await target.exists() && await target.length() > 0) {
        await target.setLastModified(DateTime.now());
        return target.path;
      }

      if (await temp.exists()) {
        await temp.delete();
      }
      await _download(source, temp);
      if (_disposed) return null;
      if (await temp.length() <= 0) {
        return null;
      }
      await temp.rename(target.path);
      AppCacheService.scheduleEnforce();
      return target.path;
    } catch (error, stackTrace) {
      _logFailure(error, stackTrace);
      return null;
    } finally {
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

  Future<Directory> _cacheRoot() async {
    final temp = await _temporaryDirectory();
    return Directory(path.join(temp.path, cacheDirectoryName));
  }

  static String _fileNameFor(String source, MusicTrack track) {
    final hash = sha1.convert(utf8.encode(source)).toString();
    final extension = _extensionFor(source, track.displayName);
    return extension.isEmpty ? hash : '$hash$extension';
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

  Future<void> _download(String source, File target) async {
    final client = _httpClientFactory();
    _activeClients.add(client);
    HttpClientRequest? request;
    IOSink? sink;
    try {
      try {
        client.connectionTimeout = requestTimeout;
      } catch (_) {
        // Some injected clients do not expose socket options.
      }
      request = await client.getUrl(Uri.parse(source)).timeout(requestTimeout);
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Unexpected ASMR playback cache status ${response.statusCode}',
          uri: Uri.parse(source),
        );
      }
      sink = target.openWrite();
      await for (final chunk in response.timeout(downloadIdleTimeout)) {
        if (_disposed) throw StateError('ASMR playback cache was disposed.');
        sink.add(chunk);
      }
      await sink.flush();
    } catch (error) {
      request?.abort(error);
      rethrow;
    } finally {
      await sink?.close();
      client.close(force: true);
      _activeClients.remove(client);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
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
