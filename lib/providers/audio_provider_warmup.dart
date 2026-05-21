part of 'audio_provider.dart';

extension AudioProviderWarmup on AudioProvider {
  static const int _mainTabIndexLibrary = 1;
  static const int _mainTabIndexPlayback = 2;

  void scheduleUiWarmup({
    required int currentPageIndex,
    bool immediate = false,
  }) {
    final generation = _warmupGeneration + 1;
    _warmupGeneration = generation;
    _deferredWarmupTimer?.cancel();
    if (immediate) {
      _runUiWarmup(generation: generation, currentPageIndex: currentPageIndex);
      return;
    }
    _deferredWarmupTimer = Timer(const Duration(milliseconds: 140), () {
      _deferredWarmupTimer = null;
      _runUiWarmup(generation: generation, currentPageIndex: currentPageIndex);
    });
  }

  void _runUiWarmup({required int generation, required int currentPageIndex}) {
    if (generation != _warmupGeneration) return;
    _warmupScheduler.beginGeneration(generation);
    _scheduleSessionWarmup(generation: generation);
    if ((currentPageIndex - _mainTabIndexLibrary).abs() <= 1) {
      _scheduleLibraryWarmup(generation: generation);
    }
    if ((currentPageIndex - _mainTabIndexPlayback).abs() <= 1) {
      _scheduleFocusedSessionWarmup(generation: generation);
    }
  }

  void _scheduleLibraryWarmup({required int generation}) {
    if (_isScanning) return;
    final folders = libraryTree.whereType<FolderNode>().take(4).toList();
    for (var index = 0; index < folders.length; index++) {
      final folder = folders[index];
      final key = 'folder_cover:${folder.path}:$coverGeneration';
      _warmupScheduler.schedule(
        key: key,
        priority: 30 + index,
        generation: generation,
        task: () async {
          await coverPathFutureForFolder(folder.path);
        },
      );
    }
  }

  void _scheduleSessionWarmup({required int generation}) {
    final sessions = activeSessions;
    if (sessions.isEmpty) return;

    final focusIndex = (() {
      final focusedId = _notificationFocusSessionId;
      if (focusedId != null) {
        final index = sessions.indexWhere((session) => session.id == focusedId);
        if (index >= 0) return index;
      }
      final playingIndex = sessions.indexWhere(
        (session) => session.state.playing,
      );
      if (playingIndex >= 0) return playingIndex;
      return 0;
    })();

    final indices = <int>{
      focusIndex,
      if (focusIndex > 0) focusIndex - 1,
      if (focusIndex + 1 < sessions.length) focusIndex + 1,
    };

    for (final index in indices) {
      final session = sessions[index];
      final trackPath = session.currentTrackPath;
      final track = trackByPath(trackPath);
      _warmupScheduler.schedule(
        key: 'track_cover:$trackPath:$coverGeneration',
        priority: index == focusIndex ? 0 : 8 + index,
        generation: generation,
        task: () async {
          await coverPathFutureForTrack(track);
        },
      );
      _warmupScheduler.schedule(
        key: 'subtitle:$trackPath',
        priority: index == focusIndex ? 1 : 12 + index,
        generation: generation,
        task: () async {
          await subtitleTrackForPath(trackPath);
        },
      );
    }
  }

  void _scheduleFocusedSessionWarmup({required int generation}) {
    final focusedSession = _notificationFocusedSession;
    if (focusedSession == null) return;
    final trackPath = focusedSession.currentTrackPath;
    final track = trackByPath(trackPath);
    _warmupScheduler.schedule(
      key: 'track_cover:$trackPath:$coverGeneration',
      priority: 0,
      generation: generation,
      task: () async {
        await coverPathFutureForTrack(track);
      },
    );
    _warmupScheduler.schedule(
      key: 'subtitle:$trackPath',
      priority: 1,
      generation: generation,
      task: () async {
        await subtitleTrackForPath(trackPath);
      },
    );
  }
}
