import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/warmup_scheduler.dart';
import '../../../core/widgets/async_cover_image.dart';
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
  final Map<Object, _BrowseCoverPrefetch> _browsePrefetches = {};
  bool _scheduleBatchPending = false;
  bool _scrollUpdateScheduled = false;
  bool _waitingForCapacity = false;
  bool _interactionPaused;
  bool _disposed = false;

  /// The list supplies source snapshots; no offscreen card needs to be mounted.
  void updateBrowsePrefetch({
    required Object owner,
    required BuildContext context,
    required ScrollController scrollController,
    required Object source,
    required int itemCount,
    required int columnCount,
    required double topPadding,
    required double rowExtent,
    List<double>? rowOffsets,
    required int cacheWidth,
    required Future<String?>? Function(int index) coverAt,
    required bool Function() isActive,
  }) {
    if (_disposed) return;
    final request = _browsePrefetches.putIfAbsent(
      owner,
      _BrowseCoverPrefetch.new,
    );
    final changed =
        !identical(request.source, source) ||
        request.itemCount != itemCount ||
        request.columnCount != columnCount ||
        request.rowExtent != rowExtent ||
        request.cacheWidth != cacheWidth ||
        request.topPadding != topPadding ||
        !identical(request.rowOffsets, rowOffsets);
    request
      ..context = context
      ..scrollController = scrollController
      ..source = source
      ..itemCount = itemCount
      ..columnCount = columnCount
      ..topPadding = topPadding
      ..rowExtent = rowExtent
      ..rowOffsets = rowOffsets
      ..cacheWidth = cacheWidth
      ..coverAt = coverAt
      ..isActive = isActive;
    if (changed) _invalidateBrowsePrefetch(request);
    if (request.attachScheduled) return;
    request.attachScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      request.attachScheduled = false;
      if (_disposed || !identical(_browsePrefetches[owner], request)) return;
      if (!request.context.mounted || !request.scrollController.hasClients) {
        return;
      }
      final position = request.scrollController.position;
      if (!identical(request.position, position)) {
        request.detach();
        request.position = position;
        request.offset = position.pixels;
        request.listener = () {
          final delta = position.pixels - request.offset;
          if (delta != 0) request.direction = delta.sign.toInt();
          request.offset = position.pixels;
          _invalidateBrowsePrefetch(request);
          _scheduleBrowsePrefetch(owner, request);
        };
        position.addListener(request.listener!);
        position.isScrollingNotifier.addListener(request.listener!);
      }
      _scheduleBrowsePrefetch(owner, request);
    });
  }

  void cancelBrowsePrefetch(Object owner) {
    final request = _browsePrefetches.remove(owner);
    if (request == null) return;
    _invalidateBrowsePrefetch(request);
    request.detach();
  }

  void refreshBrowsePrefetch(Object owner) {
    final request = _browsePrefetches[owner];
    if (request == null) return;
    if (!_canPrefetch(owner, request)) {
      _invalidateBrowsePrefetch(request);
      request.suspended = true;
      return;
    }
    if (request.suspended) {
      request.suspended = false;
      _invalidateBrowsePrefetch(request);
    }
    _scheduleBrowsePrefetch(owner, request);
  }

  void _invalidateBrowsePrefetch(_BrowseCoverPrefetch request) {
    request.generation++;
    request.timer?.cancel();
    request.timer = null;
  }

  bool _canPrefetch(Object owner, _BrowseCoverPrefetch request) {
    if (_disposed ||
        !identical(_browsePrefetches[owner], request) ||
        !request.context.mounted ||
        !request.isActive()) {
      return false;
    }
    try {
      if (!TickerMode.getValuesNotifier(request.context).value.enabled) {
        return false;
      }
    } catch (_) {
      return false;
    }
    return !_interactionPaused &&
        request.position?.hasContentDimensions == true &&
        request.position?.isScrollingNotifier.value == false;
  }

  void _scheduleBrowsePrefetch(Object owner, _BrowseCoverPrefetch request) {
    if (!_canPrefetch(owner, request) ||
        request.timer != null ||
        request.completedGeneration == request.generation) {
      return;
    }
    request.timer = Timer(const Duration(milliseconds: 160), () {
      request.timer = null;
      if (!request.running) unawaited(_runBrowsePrefetch(owner, request));
    });
  }

  Future<void> _runBrowsePrefetch(
    Object owner,
    _BrowseCoverPrefetch request,
  ) async {
    if (!_canPrefetch(owner, request)) return;
    final generation = request.generation;
    bool isCurrent() =>
        generation == request.generation && _canPrefetch(owner, request);
    final position = request.position!;
    final viewport = position.viewportDimension;
    if (viewport <= 0 || request.itemCount == 0) return;
    final rowCount = (request.itemCount / request.columnCount).ceil();
    int rowAt(double offset) {
      final offsets = request.rowOffsets;
      if (offsets == null) {
        return (offset / request.rowExtent).floor().clamp(0, rowCount - 1);
      }
      var low = 0;
      var high = offsets.length - 1;
      while (low < high) {
        final middle = (low + high + 1) ~/ 2;
        if (offsets[middle] <= offset) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      return low.clamp(0, rowCount - 1);
    }

    final first = rowAt(position.pixels - request.topPadding);
    final last = rowAt(position.pixels + viewport - request.topPadding - 0.01);
    final rowsAhead = last - first + 1;
    final start = request.direction > 0
        ? (last + 1) * request.columnCount
        : first * request.columnCount - 1;
    final count = (rowsAhead * request.columnCount).clamp(0, 24);
    final configuration = createLocalImageConfiguration(request.context);
    final cacheWidth = request.cacheWidth;
    final coverAt = request.coverAt;
    request.running = true;
    try {
      for (var step = 0; step < count && isCurrent(); step++) {
        final index = start + step * request.direction;
        if (index < 0 || index >= request.itemCount) break;
        try {
          final future = coverAt(index);
          if (future == null) continue;
          final path = await future;
          if (!isCurrent()) break;
          if (path == null || path.isEmpty) continue;
          await warmBrowseThumbnail(
            resizeFileImageIfNeeded(
              path: path,
              cacheWidth: cacheWidth,
              useDefaultCacheWidth: false,
            ),
            configuration,
            isActive: isCurrent,
          );
        } catch (error, stackTrace) {
          // Optional lookahead must never turn a missing/corrupt cover into a
          // list error; ordinary visible requests retain their own retry path.
          AppLogService.warning(
            'Browse cover prefetch failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    } finally {
      request.running = false;
      if (generation == request.generation) {
        request.completedGeneration = generation;
      } else {
        _scheduleBrowsePrefetch(owner, request);
      }
    }
  }

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
    for (final entry in _browsePrefetches.entries) {
      final request = entry.value;
      final position = request.position;
      if (position == null || !position.hasContentDimensions) continue;
      final dimensions = (position.viewportDimension, position.maxScrollExtent);
      if (dimensions == request.dimensions) continue;
      request.dimensions = dimensions;
      _invalidateBrowsePrefetch(request);
      _scheduleBrowsePrefetch(entry.key, request);
    }
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
                (entry) =>
                    !entry.value.submitted &&
                    (entry.value.hasUnscopedRequest || !_scrollUpdateScheduled),
              )
              .map(
                (entry) => (
                  key: entry.key,
                  request: entry.value,
                  priority: _priorityForRequest(entry.value),
                ),
              )
              .where((entry) => entry.priority < 0)
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
    for (final entry in _browsePrefetches.entries) {
      if (paused) {
        _invalidateBrowsePrefetch(entry.value);
      } else {
        _scheduleBrowsePrefetch(entry.key, entry.value);
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final owner in _browsePrefetches.keys.toList()) {
      cancelBrowsePrefetch(owner);
    }
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

final class _BrowseCoverPrefetch {
  late BuildContext context;
  late ScrollController scrollController;
  Object? source;
  int itemCount = 0;
  int columnCount = 1;
  double topPadding = 0;
  double rowExtent = 1;
  List<double>? rowOffsets;
  int cacheWidth = 0;
  late Future<String?>? Function(int) coverAt;
  late bool Function() isActive;
  ScrollPosition? position;
  VoidCallback? listener;
  double offset = 0;
  (double, double)? dimensions;
  int direction = 1;
  int generation = 0;
  int completedGeneration = -1;
  bool running = false;
  bool attachScheduled = false;
  bool suspended = false;
  Timer? timer;

  void detach() {
    final callback = listener;
    if (callback != null) {
      position?.removeListener(callback);
      position?.isScrollingNotifier.removeListener(callback);
    }
    position = null;
    listener = null;
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
