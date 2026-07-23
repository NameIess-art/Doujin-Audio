import 'dart:async';

import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/warmup_scheduler.dart';
import '../application/library_facade.dart';

final class LibraryCoverUiController {
  LibraryCoverUiController({
    required LibraryFacade library,
    WarmupScheduler? scheduler,
  }) : _library = library,
       _scheduler = scheduler ?? WarmupScheduler();

  final LibraryFacade _library;
  final WarmupScheduler _scheduler;
  final Map<String, Completer<String?>> _deferredLookups =
      <String, Completer<String?>>{};
  bool _disposed = false;

  Future<String?> deferredFolderCover(String folderPath) {
    final normalizedPath = PathMatcher.normalize(folderPath);
    final generation = _library.coverArtworkCacheService.generation;
    return _deferredLookup(
      key: 'folder:$normalizedPath:$generation',
      lookup: () => _library.coverPathFutureForFolder(folderPath),
    );
  }

  Future<String?> deferredTrackCover(MusicTrack track) {
    final coverKey =
        _library.coverArtworkCacheService.coverSearchKeyForTrack(track) ??
        track.path;
    final generation = _library.coverArtworkCacheService.generation;
    return _deferredLookup(
      key: 'track:$coverKey:$generation',
      lookup: () => _library.coverPathFutureForTrack(track),
    );
  }

  Future<String?> _deferredLookup({
    required String key,
    required Future<String?> Function() lookup,
  }) {
    if (_disposed) return Future<String?>.value();
    final existing = _deferredLookups[key];
    if (existing != null) return existing.future;

    final completer = Completer<String?>();
    _deferredLookups[key] = completer;
    Future<void> run() async {
      try {
        final value = await lookup();
        if (!completer.isCompleted) completer.complete(value);
      } catch (error, stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      } finally {
        if (identical(_deferredLookups[key], completer)) {
          _deferredLookups.remove(key);
        }
      }
    }

    Future<void> scheduleWhenAvailable() async {
      while (!_disposed && !completer.isCompleted) {
        final scheduled = _scheduler.schedule(
          key: 'visible_library_cover:$key',
          priority: -1,
          generation: _scheduler.currentGeneration,
          group: 'visible_library_cover',
          task: run,
        );
        if (scheduled) return;
        await _scheduler.idle;
      }
    }

    unawaited(scheduleWhenAvailable());
    return completer.future;
  }

  void warmupTracks(Iterable<MusicTrack?> tracks) {
    final generation = _scheduler.currentGeneration;
    final scheduledKeys = <String>{};
    var priority = 0;
    for (final track in tracks) {
      if (track == null || track.isVideo) continue;
      if (_library.resolvedCoverPathForTrack(track) != null) continue;
      final coverSearchKey = _library.coverArtworkCacheService
          .coverSearchKeyForTrack(track);
      if (coverSearchKey == null || !scheduledKeys.add(coverSearchKey)) {
        continue;
      }
      _scheduler.schedule(
        key: 'library_track_cover:$coverSearchKey',
        priority: priority++,
        generation: generation,
        group: 'library_cover',
        task: () async {
          if (_library.resolvedCoverPathForTrack(track) == null) {
            await _library.coverPathFutureForTrack(track);
          }
        },
      );
    }
  }

  void setInteractionPaused(bool paused) => _scheduler.setPaused(paused);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final completer in _deferredLookups.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _deferredLookups.clear();
    await _scheduler.shutdown();
  }
}
