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
import '../../../core/media/playback_media_reference.dart';
import 'asmr_download_media_transfer.dart';

class AsmrPlaybackCacheService implements PlaybackTrackCache {
  AsmrPlaybackCacheService({
    HttpClient Function()? httpClientFactory,
    Future<Directory> Function()? temporaryDirectory,
    this.requestTimeout = const Duration(seconds: 15),
    this.downloadIdleTimeout = const Duration(seconds: 30),
    AsmrHlsAudioTransfer? hlsAudioTransfer,
  }) : _httpClientFactory = httpClientFactory,
       _hlsAudioTransfer = hlsAudioTransfer ?? AsmrHlsAudioTransfer(),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static const String cacheDirectoryName = 'asmr_playback_cache';
  static final RegExp _safeExtensionPattern = RegExp(r'^\.[A-Za-z0-9]+$');

  final HttpClient Function()? _httpClientFactory;
  HttpClient? _sharedHttpClient;
  final AsmrHlsAudioTransfer _hlsAudioTransfer;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration requestTimeout;
  final Duration downloadIdleTimeout;
  final Map<String, _PlaybackCacheTransfer> _inFlight = {};
  final Map<String, _PlaybackCacheTransfer> _owners = {};
  final Queue<_PlaybackCacheTransfer> _waitingTransfers = Queue();
  int _activeTransfers = 0;
  bool _disposed = false;

  @override
  Future<String?> cacheTrack(
    MusicTrack track, {
    String? playedPath,
    String? ownerId,
  }) async {
    try {
      if (_disposed) return null;
      if (!const {'asmr.one', 'jp-asmr'}.contains(track.remoteMetadataKind)) {
        if (ownerId != null) releaseOwner(ownerId);
        return null;
      }
      final source = _cacheableSource(track, playedPath: playedPath);
      if (source == null) {
        if (ownerId != null) releaseOwner(ownerId);
        return null;
      }
      final key = _fileNameFor(source, track);
      final previous = _inFlight[key];
      if (ownerId != null && !identical(_owners[ownerId], previous)) {
        releaseOwner(ownerId);
      }
      final transfer = previous != null && !previous.cancelled
          ? previous
          : _PlaybackCacheTransfer();
      if (ownerId == null) {
        transfer.unowned = true;
      } else {
        transfer.owners.add(ownerId);
        _owners[ownerId] = transfer;
      }
      if (identical(transfer, previous)) return transfer.result;

      // A replacement for the same file must wait for cancelled .part cleanup.
      final pendingCleanup = previous?.result;
      _inFlight[key] = transfer;
      transfer.result = () async {
        try {
          await pendingCleanup;
          if (transfer.cancelled) return null;
          final root = await _cacheRoot();
          if (transfer.cancelled) return null;
          return await _cacheTarget(
            transfer: transfer,
            root: root,
            target: File(path.join(root.path, key)),
            source: source,
            expectedBytes: _expectedBytes(track, source),
          );
        } catch (error, stackTrace) {
          if (!transfer.cancelled) _logFailure(error, stackTrace);
          return null;
        } finally {
          if (identical(_inFlight[key], transfer)) _inFlight.remove(key);
          for (final owner in transfer.owners) {
            if (identical(_owners[owner], transfer)) _owners.remove(owner);
          }
        }
      }();
      return transfer.result;
    } catch (error, stackTrace) {
      if (ownerId != null) releaseOwner(ownerId);
      _logFailure(error, stackTrace);
      return null;
    }
  }

  @override
  void releaseOwner(String ownerId) {
    final transfer = _owners.remove(ownerId);
    if (transfer == null) return;
    transfer.owners.remove(ownerId);
    if (transfer.owners.isEmpty && !transfer.unowned) _cancel(transfer);
  }

  void _cancel(_PlaybackCacheTransfer transfer) {
    transfer.cancelled = true;
    final waiting = transfer.waiting;
    if (waiting != null && _waitingTransfers.remove(transfer)) {
      transfer.waiting = null;
      waiting.complete(false);
    }
    transfer.cancelStream?.call();
    try {
      transfer.request?.abort();
    } catch (_) {
      // Some injected test requests do not implement abort.
    }
    transfer.ownedClient?.close(force: true);
  }

  Future<String?> _cacheTarget({
    required _PlaybackCacheTransfer transfer,
    required Directory root,
    required File target,
    required String source,
    required int? expectedBytes,
  }) async {
    final temp = File('${target.path}.part');
    final lease = AppCacheService.protectPaths(<String>[
      temp.path,
      target.path,
    ]);
    try {
      final reference = PlaybackMediaReference.parse(source);
      if (transfer.cancelled) return null;
      await root.create(recursive: true);
      final legacy = File(
        path.join(root.path, path.basename(target.path).substring(3)),
      );
      if (await legacy.exists()) await legacy.delete();
      if (await target.exists()) {
        final length = await target.length();
        if (length > 0 && (expectedBytes == null || length == expectedBytes)) {
          var valid = true;
          if (reference.isHls) {
            try {
              await validateAsmrAudioFile(target);
            } on FormatException {
              valid = false;
            }
          }
          if (valid) {
            await target.setLastModified(DateTime.now());
            return target.path;
          }
        }
        await target.delete();
      }

      if (await temp.exists()) {
        await temp.delete();
      }
      if (reference.isHls) {
        if (!await _acquireTransfer(transfer)) return null;
        try {
          await _hlsAudioTransfer.save(
            reference: reference,
            output: temp,
            isCancelled: () => transfer.cancelled,
          );
        } finally {
          _releaseTransfer();
        }
      } else {
        await _download(transfer, source, temp, expectedBytes: expectedBytes);
      }
      if (transfer.cancelled) return null;
      final length = await temp.length();
      if (length <= 0 || (expectedBytes != null && length != expectedBytes)) {
        throw const HttpException('ASMR playback cache length mismatch.');
      }
      if (transfer.cancelled) return null;
      await temp.rename(target.path);
      AppCacheService.scheduleEnforce();
      return target.path;
    } catch (error, stackTrace) {
      if (!transfer.cancelled) _logFailure(error, stackTrace);
      return null;
    } finally {
      lease.release();
      if (await temp.exists()) {
        await temp.delete();
      }
    }
  }

  static String? _cacheableSource(MusicTrack track, {String? playedPath}) {
    if (PathMatcher.isRemoteUri(track.path)) {
      final reference = PlaybackMediaReference.parse(track.path);
      // A native player can report the transport URI without its chapter
      // fragment. Caching must keep the track's logical chapter identity.
      if (reference.isHls && reference.isChapter) return track.path;
    }
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
    if (PlaybackMediaReference.parse(source).isHls) return null;
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
    final reference = PlaybackMediaReference.parse(source);
    final extension = reference.isHls
        ? '.m4a'
        : _extensionFor(source, track.displayName);
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
        _safeExtensionPattern.hasMatch(value);
  }

  HttpClient _httpClientForDownload() {
    final factory = _httpClientFactory;
    if (factory != null) {
      final client = factory();
      client.autoUncompress = false;
      try {
        client.connectionTimeout = requestTimeout;
      } catch (_) {
        // Some injected clients do not expose socket options.
      }
      return client;
    }
    final existing = _sharedHttpClient;
    if (existing != null) return existing;
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = requestTimeout;
    return _sharedHttpClient = client;
  }

  Future<void> _download(
    _PlaybackCacheTransfer transfer,
    String source,
    File target, {
    required int? expectedBytes,
  }) async {
    if (!await _acquireTransfer(transfer)) return;
    final ownsClient = _httpClientFactory != null;
    HttpClient? client;
    HttpClientRequest? request;
    IOSink? sink;
    StreamSubscription<List<int>>? subscription;
    try {
      if (transfer.cancelled) return;
      client = _httpClientForDownload();
      if (ownsClient) transfer.ownedClient = client;
      final uri = Uri.parse(source);
      request = await client.getUrl(uri).timeout(requestTimeout);
      transfer.request = request;
      if (transfer.cancelled) {
        request.abort();
        return;
      }
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      for (final header
          in PlaybackMediaReference.requestHeadersForUri(uri).entries) {
        request.headers.set(header.key, header.value);
      }
      final response = await request.close().timeout(requestTimeout);
      if (transfer.cancelled) {
        await response.listen(null).cancel();
        return;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.listen(null).cancel();
        throw HttpException(
          'Unexpected ASMR playback cache status ${response.statusCode}',
          uri: uri,
        );
      }
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        await response.listen(null).cancel();
        throw const HttpException('Unsupported ASMR playback cache encoding.');
      }
      final responseBytes = response.contentLength;
      if (expectedBytes != null &&
          responseBytes >= 0 &&
          responseBytes != expectedBytes) {
        await response.listen(null).cancel();
        throw const HttpException(
          'ASMR playback cache response length mismatch.',
        );
      }
      var receivedBytes = 0;
      sink = target.openWrite();
      final controller = StreamController<List<int>>(sync: true);
      void cancelStreamWithError(Object error) {
        final active = subscription;
        subscription = null;
        if (active != null) unawaited(active.cancel());
        if (!controller.isClosed) {
          controller.addError(error);
          unawaited(controller.close());
        }
      }

      controller
        ..onListen = () {
          if (transfer.cancelled) {
            cancelStreamWithError(StateError('ASMR playback cache cancelled.'));
            return;
          }
          subscription = response
              .timeout(downloadIdleTimeout)
              .listen(
                (chunk) {
                  if (transfer.cancelled) {
                    cancelStreamWithError(
                      StateError('ASMR playback cache cancelled.'),
                    );
                    return;
                  }
                  receivedBytes += chunk.length;
                  if ((responseBytes >= 0 && receivedBytes > responseBytes) ||
                      (expectedBytes != null &&
                          receivedBytes > expectedBytes)) {
                    cancelStreamWithError(
                      const HttpException(
                        'ASMR playback cache exceeded expected length.',
                      ),
                    );
                    return;
                  }
                  controller.add(chunk);
                },
                onError: (Object error, StackTrace stackTrace) {
                  if (!controller.isClosed) {
                    controller.addError(error, stackTrace);
                    unawaited(controller.close());
                  }
                },
                onDone: () {
                  if (!controller.isClosed) {
                    unawaited(controller.close());
                  }
                },
                cancelOnError: true,
              );
        }
        ..onPause = () {
          subscription?.pause();
        }
        ..onResume = () {
          subscription?.resume();
        }
        ..onCancel = () {
          final active = subscription;
          subscription = null;
          return active?.cancel();
        };
      transfer.cancelStream = () => cancelStreamWithError(
        StateError('ASMR playback cache cancelled.'),
      );
      await sink.addStream(controller.stream);
      await sink.flush();
      if (receivedBytes == 0 ||
          (responseBytes >= 0 && receivedBytes != responseBytes) ||
          (expectedBytes != null && receivedBytes != expectedBytes)) {
        throw const HttpException('ASMR playback cache incomplete response.');
      }
    } catch (error) {
      try {
        request?.abort(error);
      } catch (_) {
        // Some injected test requests do not implement abort.
      }
      rethrow;
    } finally {
      try {
        await subscription?.cancel();
        subscription = null;
        await sink?.close();
      } finally {
        if (ownsClient) {
          client?.close(force: true);
        }
        transfer.ownedClient = null;
        transfer.request = null;
        transfer.cancelStream = null;
        _releaseTransfer();
      }
    }
  }

  Future<bool> _acquireTransfer(_PlaybackCacheTransfer transfer) {
    if (transfer.cancelled) return Future<bool>.value(false);
    if (_activeTransfers < 2) {
      _activeTransfers++;
      return Future<bool>.value(true);
    }
    final waiting = Completer<bool>();
    transfer.waiting = waiting;
    _waitingTransfers.addLast(transfer);
    return waiting.future;
  }

  void _releaseTransfer() {
    if (_waitingTransfers.isNotEmpty && !_disposed) {
      final next = _waitingTransfers.removeFirst();
      final waiting = next.waiting!;
      next.waiting = null;
      waiting.complete(true);
    } else {
      _activeTransfers--;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final transfers = _inFlight.values.toList(growable: false);
    for (final transfer in transfers) {
      _cancel(transfer);
    }
    _sharedHttpClient?.close(force: true);
    _sharedHttpClient = null;
    await Future.wait(transfers.map((transfer) => transfer.result));
    _owners.clear();
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

final class _PlaybackCacheTransfer {
  final Set<String> owners = {};
  bool unowned = false;
  bool cancelled = false;
  late final Future<String?> result;
  Completer<bool>? waiting;
  HttpClient? ownedClient;
  HttpClientRequest? request;
  void Function()? cancelStream;
}
