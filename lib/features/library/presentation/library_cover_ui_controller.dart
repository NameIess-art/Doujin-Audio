import 'dart:async';

import 'package:flutter/foundation.dart';
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
       _scheduler =
           scheduler ??
           WarmupScheduler(
             maxConcurrent: defaultTargetPlatform == TargetPlatform.windows
                 ? 4
                 : 1,
           ),
       _interactionPaused = scheduler?.isPaused ?? false;

  final LibraryFacade _library;
  final WarmupScheduler _scheduler;
  final Map<String, _DeferredCoverLookup> _deferredLookups = {};
  final Set<ScrollPosition> _scrollPositions = {};
  bool _scheduleBatchPending = false;
  bool _scrollUpdateScheduled = false;
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
      cached: _library.coverArtworkCacheService.cachedFutureForFolder(
        folderPath,
      ),
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
      cached: _library.coverArtworkCacheService.cachedFutureForTrack(track),
      context: context,
      lookup: () => _library.coverPathFutureForTrack(track),
    );
  }

  Future<String?> deferredPlaybackCover(
    MusicTrack? track, {
    BuildContext? context,
  }) {
    if (track == null) return SynchronousFuture(null);
    final cache = _library.coverArtworkCacheService;
    final coverKey = cache.coverSearchKeyForTrack(track) ?? track.path;
    final revision = cache.revisionForScope(coverKey);
    return _deferredLookup(
      key: 'playback:$coverKey:$revision',
      cached: cache.cachedFutureForPlaybackTrack(track),
      context: context,
      lookup: () => _library.playbackCoverPathFutureForTrack(track),
    );
  }

  Future<String?> deferredRemoteCover(String url, {BuildContext? context}) {
    final normalizedUrl = url.trim();
    final revision = _library.coverArtworkCacheService.revisionForScope(
      normalizedUrl,
    );
    return _deferredLookup(
      key: 'remote:$normalizedUrl:$revision',
      cached: _library.coverArtworkCacheService.cachedFutureForRemoteCover(
        normalizedUrl,
      ),
      context: context,
      lookup: () => _library.coverPathFutureForRemoteCover(normalizedUrl),
    );
  }

  Future<String?> _deferredLookup({
    required String key,
    required Future<String?>? cached,
    required BuildContext? context,
    required Future<String?> Function() lookup,
  }) {
    if (_disposed) return Future<String?>.value();
    if (cached != null) return cached;
    final request = _deferredLookups.putIfAbsent(
      key,
      () => _DeferredCoverLookup(lookup),
    );
    if (context == null) {
      request.hasUnscopedRequest = true;
    } else {
      request.contexts.add(context);
      final position = Scrollable.maybeOf(context)?.position;
      if (position != null && _scrollPositions.add(position)) {
        position.addListener(viewportChanged);
      }
    }
    _schedulePendingLookups();
    return request.result.future;
  }

  void viewportChanged() {
    if (_disposed || _scrollUpdateScheduled || _deferredLookups.isEmpty) return;
    _scrollUpdateScheduled = true;
    // Scroll offsets change before rows lay out. Admit requests once the new
    // viewport is known, sharing one listener/frame across all its cards.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollUpdateScheduled = false;
      _schedulePendingLookups();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _pruneScrollPositions() {
    final active = <ScrollPosition>{
      for (final request in _deferredLookups.values)
        for (final context in request.contexts)
          if (context.mounted) ?Scrollable.maybeOf(context)?.position,
    };
    _scrollPositions.removeWhere((position) {
      if (active.contains(position)) return false;
      position.removeListener(viewportChanged);
      return true;
    });
  }

  void _schedulePendingLookups() {
    if (_disposed || _interactionPaused || _scheduleBatchPending) return;
    _scheduleBatchPending = true;
    scheduleMicrotask(() {
      _scheduleBatchPending = false;
      if (_disposed || _interactionPaused) return;
      // A fling can recycle many rows while slow artwork occupies every slot.
      // Retire unsubmitted requests before sorting the next viewport's candidates.
      _deferredLookups.removeWhere((_, request) {
        request.contexts.removeWhere((context) => !context.mounted);
        // Queued keys still belong to the scheduler. Keep their request so a
        // returning row reuses it instead of retrying a duplicate key forever.
        if (request.submitted ||
            request.started ||
            request.hasUnscopedRequest ||
            request.contexts.isNotEmpty) {
          return false;
        }
        request.result.complete(null);
        return true;
      });
      _pruneScrollPositions();
      // Admit this frame's cards together after layout, so the first built
      // cache-extent item cannot start before the viewport's center is known.
      _scheduler.setPaused(true);
      final requests =
          _deferredLookups.entries
              .where(
                (entry) => !entry.value.submitted && _canRunLookup(entry.value),
              )
              .map(
                (entry) => (
                  key: entry.key,
                  request: entry.value,
                  priority: _priorityForRequest(entry.value),
                ),
              )
              .toList()
            ..sort((left, right) => left.priority.compareTo(right.priority));
      for (final entry in requests) {
        final request = entry.request;
        request.submitted = _scheduler.schedule(
          key: 'visible_library_cover:${entry.key}',
          priority: -1,
          priorityResolver: () => _priorityForRequest(request),
          generation: _scheduler.currentGeneration,
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
    if (request.result.isCompleted) return;
    // A cached page can become hidden while its request is queued. Keep the
    // same future for its return, without starting invisible cover discovery.
    if (!_disposed && !_canRunLookup(request)) {
      request.submitted = false;
      return;
    }
    final completer = request.result;
    request.started = true;
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
      _pruneScrollPositions();
    }
  }

  bool _canRunLookup(_DeferredCoverLookup request) =>
      request.hasUnscopedRequest ||
      !request.contexts.any((context) => context.mounted) ||
      (!_scrollUpdateScheduled && _priorityForRequest(request) < 0);

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
          (distance * 1000 / extent).round().clamp(0, 999);
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
    for (final position in _scrollPositions) {
      position.removeListener(viewportChanged);
    }
    _scrollPositions.clear();
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
  bool started = false;
}
