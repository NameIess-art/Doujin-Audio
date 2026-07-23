import 'dart:async';

import '../../core/ui/warmup_scheduler.dart';
import '../../core/media/music_track.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/library/domain/library_node.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_subtitle_service.dart';

final class AudioUiWarmupCoordinator {
  AudioUiWarmupCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required NotificationFacade notifications,
    required PlaybackSubtitleService subtitles,
    WarmupScheduler? scheduler,
  }) : _library = library,
       _playback = playback,
       _notifications = notifications,
       _subtitles = subtitles,
       _scheduler = scheduler ?? WarmupScheduler();

  static const _libraryTabIndex = 1;
  static const _playbackTabIndex = 2;
  final LibraryFacade _library;
  final PlaybackFacade _playback;
  final NotificationFacade _notifications;
  final PlaybackSubtitleService _subtitles;
  final WarmupScheduler _scheduler;
  Timer? _deferredTimer;
  int _generation = 0;
  bool _pausedForLifecycle = false;
  bool _pausedForInteraction = false;
  bool _disposed = false;

  void setInteractionPaused(bool paused) {
    if (_pausedForInteraction == paused) return;
    _pausedForInteraction = paused;
    _syncPauseState();
  }

  Future<bool> waitForContinuousIdle(Duration quietWindow) async {
    while (!_disposed) {
      while (_pausedForInteraction && !_disposed) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      if (_disposed) return false;
      await Future<void>.delayed(quietWindow);
      if (!_pausedForInteraction) return true;
    }
    return false;
  }

  void schedule({required int currentPageIndex, bool immediate = false}) {
    if (_disposed) return;
    final generation = ++_generation;
    _deferredTimer?.cancel();
    if (immediate) {
      _run(
        generation: generation,
        currentPageIndex: currentPageIndex,
        navigationCooldown: Duration.zero,
      );
      return;
    }
    _deferredTimer = Timer(const Duration(milliseconds: 140), () {
      _deferredTimer = null;
      _run(
        generation: generation,
        currentPageIndex: currentPageIndex,
        navigationCooldown: const Duration(milliseconds: 120),
      );
    });
  }

  void warmupPlaybackCovers(Iterable<MusicTrack?> tracks) {
    final generation = _scheduler.currentGeneration;
    final scheduledKeys = <String>{};
    var priority = 40;
    for (final track in tracks) {
      if (track == null) continue;
      if (_library.resolvedPlaybackCoverPathForTrack(track) != null) continue;
      final coverSearchKey = _library.coverArtworkCacheService
          .coverSearchKeyForTrack(track);
      if (coverSearchKey == null || !scheduledKeys.add(coverSearchKey)) {
        continue;
      }
      _scheduler.schedule(
        key:
            'playlist_cover:$coverSearchKey:${_library.coverArtworkCacheService.generation}',
        priority: priority++,
        generation: generation,
        group: 'playlist_cover',
        task: () async {
          if (_library.resolvedPlaybackCoverPathForTrack(track) == null) {
            await _library.playbackCoverPathFutureForTrack(track);
          }
        },
      );
    }
  }

  void enterBackground() {
    _pausedForLifecycle = true;
    _deferredTimer?.cancel();
    _deferredTimer = null;
    _generation++;
    _scheduler.clear();
    _syncPauseState();
  }

  void resumeForeground() {
    _pausedForLifecycle = false;
    _syncPauseState();
  }

  Future<void> waitUntilIdle() => _scheduler.idle;

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    _deferredTimer?.cancel();
    _deferredTimer = null;
    _generation++;
    await _scheduler.shutdown();
  }

  void _syncPauseState() {
    _scheduler.setPaused(_pausedForLifecycle || _pausedForInteraction);
  }

  void _run({
    required int generation,
    required int currentPageIndex,
    required Duration navigationCooldown,
  }) {
    if (_disposed || generation != _generation) return;
    _scheduler.beginGeneration(generation, cooldown: navigationCooldown);
    _scheduleSessionWarmup(generation);
    if ((currentPageIndex - _libraryTabIndex).abs() <= 1) {
      _scheduleLibraryWarmup(generation);
    }
    if ((currentPageIndex - _playbackTabIndex).abs() <= 1) {
      _scheduleFocusedSessionWarmup(generation);
    }
  }

  void _scheduleLibraryWarmup(int generation) {
    if (_library.state.isScanning) return;
    final folders = _library.libraryCards.whereType<FolderNode>().take(4);
    var index = 0;
    for (final folder in folders) {
      _scheduler.schedule(
        key:
            'folder_cover:${folder.path}:${_library.coverArtworkCacheService.generation}',
        priority: 30 + index++,
        generation: generation,
        group: 'library_cover',
        task: () => _library.coverPathFutureForFolder(folder.path),
      );
    }
  }

  void _scheduleSessionWarmup(int generation) {
    final sessions = _playback.state.activeSessions;
    if (sessions.isEmpty) return;
    final focusedId = _notifications.state.focusedSessionId;
    var focusIndex = focusedId == null
        ? -1
        : sessions.indexWhere((session) => session.id == focusedId);
    if (focusIndex < 0) {
      focusIndex = sessions.indexWhere((session) => session.state.playing);
    }
    if (focusIndex < 0) focusIndex = 0;
    final indices = <int>{
      focusIndex,
      if (focusIndex > 0) focusIndex - 1,
      if (focusIndex + 1 < sessions.length) focusIndex + 1,
    };
    for (final index in indices) {
      _scheduleTrack(
        trackPath: sessions[index].currentTrackPath,
        generation: generation,
        coverPriority: index == focusIndex ? 0 : 8 + index,
        subtitlePriority: index == focusIndex ? 1 : 12 + index,
      );
    }
  }

  void _scheduleFocusedSessionWarmup(int generation) {
    final sessions = _playback.state.activeSessions;
    if (sessions.isEmpty) return;
    final focusedId = _notifications.state.focusedSessionId;
    final focused = focusedId == null ? null : _playback.sessionById(focusedId);
    final session =
        focused ??
        sessions.firstWhere(
          (candidate) => candidate.state.playing,
          orElse: () => sessions.first,
        );
    _scheduleTrack(
      trackPath: session.currentTrackPath,
      generation: generation,
      coverPriority: 0,
      subtitlePriority: 1,
    );
  }

  void _scheduleTrack({
    required String trackPath,
    required int generation,
    required int coverPriority,
    required int subtitlePriority,
  }) {
    final track = _library.trackByPath(trackPath);
    _scheduler.schedule(
      key:
          'track_cover:$trackPath:${_library.coverArtworkCacheService.generation}',
      priority: coverPriority,
      generation: generation,
      group: 'session_cover',
      task: () => _library.coverPathFutureForTrack(track),
    );
    _scheduler.schedule(
      key: 'subtitle:$trackPath',
      priority: subtitlePriority,
      generation: generation,
      group: 'subtitle',
      task: () => _subtitles.load(trackPath),
    );
  }
}
