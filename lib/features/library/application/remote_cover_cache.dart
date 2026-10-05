import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/media/path_matcher.dart';
import 'cover_artwork_store.dart';
import 'remote_cover_downloader.dart';

const int _resolvedRemoteCoverLimit = 300;

/// Owns remote lookup deduplication, results and retry cooldowns.
final class RemoteCoverCache {
  RemoteCoverCache({
    required CoverArtworkStore artworkStore,
    required bool Function() isClearingPersistentCache,
    required Duration requestTimeout,
    required Duration downloadIdleTimeout,
    Future<String?> Function(String remoteUrl)? download,
    DateTime Function()? now,
    bool Function(String key)? isActiveCoverKey,
    VoidCallback? onActiveCoverChanged,
    void Function(String key)? onCoverRepaired,
  }) : _artworkStore = artworkStore,
       _isClearing = isClearingPersistentCache,
       _download = download,
       _now = now ?? DateTime.now,
       _isActiveCoverKey = isActiveCoverKey,
       _onActiveCoverChanged = onActiveCoverChanged,
       _onCoverRepaired = onCoverRepaired,
       _downloader = RemoteCoverDownloader(
         requestTimeout: requestTimeout,
         downloadIdleTimeout: downloadIdleTimeout,
       );

  final CoverArtworkStore _artworkStore;
  final RemoteCoverDownloader _downloader;
  final bool Function() _isClearing;
  final Future<String?> Function(String remoteUrl)? _download;
  final DateTime Function() _now;
  final bool Function(String key)? _isActiveCoverKey;
  final VoidCallback? _onActiveCoverChanged;
  final void Function(String key)? _onCoverRepaired;
  final Map<String, Future<String?>> _pending = {};
  final Map<String, _ResolvedRemoteCover> _resolved = {};
  final Map<String, _RemoteCoverFailure> _failures = {};
  bool _disposed = false;

  Iterable<Future<String?>> get pending => _pending.values;

  String? resolvedFor(String url) {
    final key = remoteCoverSearchKey(url);
    if (key == null) return null;
    return _resolved[key]?.path ?? _artworkStore.resolvedPath(key);
  }

  Future<String?> resolve(String url) {
    final key = remoteCoverSearchKey(url);
    if (_disposed || key == null) return Future<String?>.value();
    final warm = _resolved[key];
    if (warm != null) return warm.future;
    final inFlight = _pending[key];
    if (inFlight != null) return inFlight;
    final failure = _failures[key];
    if (failure != null && _now().isBefore(failure.retryAt)) {
      return Future<String?>.value();
    }
    final remoteUrl = normalizedRemoteUrlFromKey(key);
    Future<String?>? lookup;
    bool isCurrent() => !_disposed && identical(_pending[key], lookup);
    final task = lookup = () async {
      try {
        final previous = _resolved[key]?.path;
        var coverPath = previous;
        if (coverPath == null && _download == null) {
          await _artworkStore.initialize();
          coverPath =
              await _artworkStore.validatedPath(key) ??
              await _artworkStore.validatedArtifact(
                CoverArtworkNamespace.remote,
                '${_remoteCoverFileStem(remoteUrl)}.image',
              );
        }
        final usable =
            coverPath != null && await _downloader.isUsablePath(coverPath);
        if (!isCurrent()) return null;
        if (!usable) {
          _resolved.remove(key);
          coverPath = await _downloader.run(
            () => _fetchCover(remoteUrl, key, isCurrent: isCurrent),
          );
        }
        if (!isCurrent()) return null;
        if (coverPath == null) {
          _resolved.remove(key);
          _recordFailure(key);
        } else {
          _failures.remove(key);
          _resolved.remove(key);
          _resolved[key] = _ResolvedRemoteCover(coverPath);
          if (!_isClearing() && _artworkStore.isInitialized) {
            await _artworkStore.bind(key, coverPath);
          }
          if (!isCurrent()) return null;
          _trim(_resolvedRemoteCoverLimit);
        }
        if (previous != coverPath && (_isActiveCoverKey?.call(key) ?? false)) {
          _onActiveCoverChanged?.call();
        }
        return coverPath;
      } finally {
        // A lookup retired by invalidation must not remove its replacement.
        if (identical(_pending[key], lookup)) unawaited(_pending.remove(key));
      }
    }();
    _pending[key] = task;
    return task;
  }

  Future<void> reportArtworkReadFailure(
    String path, {
    Iterable<String> keys = const [],
  }) async {
    final affected = <String>{
      ...keys.where((key) => key.startsWith('remote-cover:')),
      ..._resolved.entries
          .where((entry) => entry.value.path == path)
          .map((entry) => entry.key),
    };
    for (final key in affected) {
      if (_disposed || _isClearing()) return;
      invalidate(key, clearFailure: true);
      await _artworkStore.invalidate([key]);
      if (_disposed || _isClearing()) return;
      await resolve(normalizedRemoteUrlFromKey(key));
      // Replacing damaged bytes can restore the same content-addressed path.
      if (!_disposed && !_isClearing()) _onCoverRepaired?.call(key);
    }
  }

  Future<String?> _fetchCover(
    String url,
    String key, {
    required bool Function() isCurrent,
  }) async {
    if (_download != null) return _download(url);
    final bytes = await _downloader.fetch(url);
    if (bytes == null || !isCurrent() || _isClearing()) return null;
    return _artworkStore.putBytes(
      logicalKey: key,
      bytes: bytes,
      namespace: CoverArtworkNamespace.remote,
    );
  }

  void invalidate(String key, {bool clearFailure = false}) {
    unawaited(_pending.remove(key));
    _resolved.remove(key);
    if (clearFailure) _failures.remove(key);
  }

  void invalidateAll() {
    _pending.clear();
    _resolved.clear();
    _failures.clear();
  }

  void trimMemory() => _trim(_resolvedRemoteCoverLimit ~/ 4);

  void _trim(int maxEntries) {
    while (_resolved.length > maxEntries) {
      final key = _resolved.keys.firstWhere(
        (key) => !(_isActiveCoverKey?.call(key) ?? false),
        orElse: () => '',
      );
      if (key.isEmpty) return;
      _resolved.remove(key);
    }
  }

  void _recordFailure(String key) {
    final count = (_failures[key]?.count ?? 0) + 1;
    var delaySeconds = 10;
    for (var attempt = 1; attempt < count; attempt++) {
      delaySeconds = (delaySeconds * 2).clamp(10, 300).toInt();
    }
    _failures.remove(key);
    _failures[key] = _RemoteCoverFailure(
      count: count,
      retryAt: _now().add(Duration(seconds: delaySeconds)),
    );
    while (_failures.length > _resolvedRemoteCoverLimit) {
      _failures.remove(_failures.keys.first);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _downloader.dispose();
    invalidateAll();
  }
}

final class _ResolvedRemoteCover {
  _ResolvedRemoteCover(this.path) : future = SynchronousFuture(path);
  final String path;
  final Future<String?> future;
}

final class _RemoteCoverFailure {
  const _RemoteCoverFailure({required this.count, required this.retryAt});
  final int count;
  final DateTime retryAt;
}

String? remoteCoverSearchKey(String url) {
  final normalized = normalizeRemoteCoverUrl(url);
  return normalized == null ? null : 'remote-cover:$normalized';
}

String? normalizeRemoteCoverUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty || !PathMatcher.isRemoteUri(trimmed)) return null;
  return PathMatcher.normalize(trimmed);
}

String normalizedRemoteUrlFromKey(String remoteKey) {
  const prefix = 'remote-cover:';
  return remoteKey.startsWith(prefix)
      ? remoteKey.substring(prefix.length)
      : remoteKey;
}

String _remoteCoverFileStem(String remoteUrl) {
  final normalized = normalizeRemoteCoverUrl(remoteUrl) ?? remoteUrl.trim();
  return sha1.convert(utf8.encode(normalized)).toString();
}
