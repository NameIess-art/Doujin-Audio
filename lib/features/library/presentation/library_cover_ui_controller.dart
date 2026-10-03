import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/warmup_scheduler.dart';
import '../application/library_facade.dart';

final class LibraryCoverUiController {
  LibraryCoverUiController({
    required LibraryFacade library,
    WarmupScheduler? scheduler,
  }) : _library = library,
       _scheduler = scheduler ?? WarmupScheduler(),
       _interactionPaused = scheduler?.isPaused ?? false;

  final LibraryFacade _library;
  final WarmupScheduler _scheduler;
  final Map<String, _DeferredCoverLookup> _deferredLookups = {};
  bool _scheduleBatchPending = false;
  bool _waitingForCapacity = false;
  bool _interactionPaused;
  bool _disposed = false;

  Future<String?> deferredFolderCover(
    String folderPath, {
    BuildContext? context,
  }) {
    final normalizedPath = PathMatcher.normalize(folderPath);
    final revision = _library.coverArtworkCacheService.revisionForScope(
      normalizedPath,
    );
    return _deferredLookup(
      key: 'folder:$normalizedPath:$revision',
      context: context,
      lookup: () => _library.coverPathFutureForFolder(folderPath),
    );
  }

  Future<String?> deferredTrackCover(
    MusicTrack track, {
    BuildContext? context,
  }) {
    final coverKey =
        _library.coverArtworkCacheService.coverSearchKeyForTrack(track) ??
        track.path;
    final revision = _library.coverArtworkCacheService.revisionForScope(
      coverKey,
    );
    return _deferredLookup(
      key: 'track:$coverKey:$revision',
      context: context,
      lookup: () => _library.coverPathFutureForTrack(track),
    );
  }

  Future<String?> deferredRemoteCover(String url, {BuildContext? context}) {
    final normalizedUrl = url.trim();
    final revision = _library.coverArtworkCacheService.revisionForScope(
      normalizedUrl,
    );
    return _deferredLookup(
      key: 'remote:$normalizedUrl:$revision',
      context: context,
      lookup: () => _library.coverPathFutureForRemoteCover(normalizedUrl),
    );
  }

  Future<String?> _deferredLookup({
    required String key,
    required BuildContext? context,
    required Future<String?> Function() lookup,
  }) {
    if (_disposed) return Future<String?>.value();
    final request = _deferredLookups.putIfAbsent(
      key,
      () => _DeferredCoverLookup(lookup),
    );
    if (context == null) {
      request.hasUnscopedRequest = true;
    } else {
      request.contexts.add(context);
    }
    _schedulePendingLookups();
    return request.result.future;
  }

  void _schedulePendingLookups() {
    if (_scheduleBatchPending) return;
    _scheduleBatchPending = true;
    scheduleMicrotask(() {
      _scheduleBatchPending = false;
      if (_disposed) return;
      // Admit this frame's cards together after layout, so the first built
      // cache-extent item cannot start before the viewport's center is known.
      _scheduler.setPaused(true);
      final requests =
          _deferredLookups.entries
              .where((entry) => _canRunLookup(entry.value))
              .toList()
            ..sort(
              (left, right) => _priorityForRequest(
                left.value,
              ).compareTo(_priorityForRequest(right.value)),
            );
      for (final entry in requests) {
        final request = entry.value;
        if (request.submitted) continue;
        request.submitted = _scheduler.schedule(
          key: 'visible_library_cover:${entry.key}',
          priority: -1,
          priorityResolver: () => _priorityForRequest(request),
          generation: _scheduler.currentGeneration,
          group: 'visible_library_cover',
          onDiscard: () => request.submitted = false,
          task: () => _runLookup(entry.key, request),
        );
      }
      _scheduler.setPaused(_interactionPaused);
      if (_deferredLookups.values.any(
        (request) => !request.submitted && _canRunLookup(request),
      )) {
        unawaited(_waitForCapacity());
      }
    });
  }

  Future<void> _waitForCapacity() async {
    if (_waitingForCapacity) return;
    _waitingForCapacity = true;
    await _scheduler.capacityAvailable;
    _waitingForCapacity = false;
    if (!_disposed) _schedulePendingLookups();
  }

  Future<void> _runLookup(String key, _DeferredCoverLookup request) async {
    // A cached page can become hidden while its request is queued. Keep the
    // same future for its return, without starting invisible cover discovery.
    if (!_disposed && !_canRunLookup(request)) {
      request.submitted = false;
      return;
    }
    final completer = request.result;
    try {
      final hasMountedRequester =
          request.hasUnscopedRequest ||
          request.contexts.any((context) => context.mounted);
      final value = !_disposed && hasMountedRequester
          ? await request.lookup()
          : null;
      if (!completer.isCompleted) completer.complete(value);
    } catch (error, stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    } finally {
      if (identical(_deferredLookups[key], request)) {
        _deferredLookups.remove(key);
      }
    }
  }

  bool _canRunLookup(_DeferredCoverLookup request) =>
      request.hasUnscopedRequest ||
      !request.contexts.any((context) => context.mounted) ||
      request.contexts.any(
        (context) =>
            context.mounted &&
            TickerMode.getValuesNotifier(context).value.enabled,
      );

  int _priorityForRequest(_DeferredCoverLookup request) {
    var priority = request.hasUnscopedRequest ? -2000 : 1 << 30;
    for (final context in request.contexts) {
      if (!context.mounted ||
          !TickerMode.getValuesNotifier(context).value.enabled) {
        continue;
      }
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final ancestor = RenderAbstractViewport.maybeOf(box);
      final viewport = ancestor is RenderBox ? ancestor as RenderBox : null;
      if (viewport == null || !viewport.hasSize) {
        if (priority > -2000) priority = -2000;
        continue;
      }
      final bounds = MatrixUtils.transformRect(
        box.getTransformTo(viewport),
        Offset.zero & box.size,
      );
      final viewportBounds = viewport.paintBounds;
      final distance = (bounds.center - viewportBounds.center).distance;
      final extent = viewportBounds.longestSide;
      if (extent <= 0 || !distance.isFinite) continue;
      final candidate =
          (bounds.overlaps(viewportBounds) ? -2000 : 1000) +
          (distance * 1000 / extent).round();
      if (candidate < priority) priority = candidate;
    }
    return priority;
  }

  void setInteractionPaused(bool paused) {
    _interactionPaused = paused;
    if (!paused && _deferredLookups.isNotEmpty) _schedulePendingLookups();
    _scheduler.setPaused(paused || _scheduleBatchPending);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final request in _deferredLookups.values) {
      final completer = request.result;
      if (!completer.isCompleted) completer.complete(null);
    }
    _deferredLookups.clear();
    await _scheduler.shutdown();
  }
}

final class _DeferredCoverLookup {
  _DeferredCoverLookup(this.lookup);

  final Future<String?> Function() lookup;
  final result = Completer<String?>();
  final contexts = <BuildContext>{};
  bool hasUnscopedRequest = false;
  bool submitted = false;
}
