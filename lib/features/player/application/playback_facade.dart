import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/persistence/audio_database_repository.dart';
import '../../../core/platform/app_platform.dart';
import '../../asmr/application/asmr_playback_cache_service.dart';
import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../domain/playback_queue.dart';
import 'playback_session.dart';
import 'audio_state_services.dart';
import 'native_playback_repository.dart';
import 'native_playback_bridge.dart';
import 'playback_command_runner.dart';
import 'system_media_controls_service.dart';

/// Owns playback sessions and the platform playback runtime.
final class PlaybackFacade {
  PlaybackFacade({
    required this.databaseRepository,
    required this.nativeRepository,
    required this.commandRunner,
    required this.playbackCacheService,
    required this.service,
    required this.systemMediaControlsService,
  });

  factory PlaybackFacade.create({
    required AudioDatabaseRepository databaseRepository,
    NativePlaybackRepository? nativeRepository,
    PlaybackCommandRunner commandRunner = const PlaybackCommandRunner(),
    AsmrPlaybackCacheService playbackCacheService =
        const AsmrPlaybackCacheService(),
    PlaybackSessionService? service,
    SystemMediaControlsService? systemMediaControlsService,
  }) {
    return PlaybackFacade(
      databaseRepository: databaseRepository,
      nativeRepository: nativeRepository ?? NativePlaybackRepository(),
      commandRunner: commandRunner,
      playbackCacheService: playbackCacheService,
      service: service ?? PlaybackSessionService(),
      systemMediaControlsService:
          systemMediaControlsService ?? SystemMediaControlsService(),
    );
  }

  final AudioDatabaseRepository databaseRepository;
  final NativePlaybackRepository nativeRepository;
  final PlaybackCommandRunner commandRunner;
  final AsmrPlaybackCacheService playbackCacheService;
  final PlaybackSessionService service;
  final SystemMediaControlsService systemMediaControlsService;
  final StreamController<String> _sessionActivations =
      StreamController<String>.broadcast(sync: true);
  Future<void> Function(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  })?
  _launchQueue;
  Future<void> Function()? _persistSessionState;
  Future<void> Function()? _persistSessionOrder;
  void Function(PlaybackSession session)? _onSessionRegistered;
  void Function()? _onSessionsReordered;
  void Function()? _onSessionStateChanged;
  final Map<String, String> _retargetedPathAliases = <String, String>{};
  int _transportCommandSequence = 0;
  int _sessionSeed = 0;
  bool _persistenceEnabled = true;

  static const double maxSessionVolume = 2.0;

  Stream<String> get sessionActivations => _sessionActivations.stream;
  PlaybackStateSliceData get state => service.slice.state;
  Stream<PlaybackStateSliceData> get states => service.slice.stream;
  PlaybackSession? sessionById(String sessionId) =>
      service.sessionById(sessionId);
  List<PlaybackSession> get ordinarySessions => service.activeSessions
      .where((session) => !session.isPlaybackQueue)
      .toList(growable: false);

  int nextTransportCommandId() => ++_transportCommandSequence;

  void observeTransportCommandId(int? commandId) {
    if (commandId != null && commandId > _transportCommandSequence) {
      _transportCommandSequence = commandId;
    }
  }

  void applyNativeProgress(NativePlaybackProgressUpdate progress) {
    if (service.sessions[progress.sessionId]?.pendingNativeTrackPath != null) {
      return;
    }
    service.applyNativeProgress(progress);
  }

  PlaybackNativeSnapshotApplication applyNativeSnapshot(
    NativePlaybackSnapshot snapshot, {
    required bool Function(String path) hasLibraryTrack,
  }) {
    observeTransportCommandId(snapshot.transportCommandId);
    final normalized = _normalizeNativeSnapshot(
      snapshot,
      hasLibraryTrack: hasLibraryTrack,
    );
    final session = service.sessions[normalized.sessionId];
    if (session == null || session.pendingNativeTrackPath != null) {
      return PlaybackNativeSnapshotApplication.notApplied(normalized);
    }
    final previousTrackPath = session.currentTrackPath;
    final previousState = session.state;
    final previousIsPlaybackStarting = session.isPlaybackStarting;
    final previousPendingPlayingIntent = session.pendingPlayingIntent;
    if (!service.applyNativeSnapshot(normalized)) {
      return PlaybackNativeSnapshotApplication.notApplied(normalized);
    }
    return PlaybackNativeSnapshotApplication(
      snapshot: normalized,
      session: session,
      previousTrackPath: previousTrackPath,
      trackChanged: session.currentTrackPath != previousTrackPath,
      playbackIntentChanged:
          session.state == previousState &&
          (session.isPlaybackStarting != previousIsPlaybackStarting ||
              session.pendingPlayingIntent != previousPendingPlayingIntent),
    );
  }

  NativePlaybackSnapshot _normalizeNativeSnapshot(
    NativePlaybackSnapshot snapshot, {
    required bool Function(String path) hasLibraryTrack,
  }) {
    final rawPath = snapshot.path ?? _pathFromSnapshotUri(snapshot.uri);
    if (rawPath == null || rawPath.isEmpty) return snapshot;
    final resolvedPath = resolveRetargetedPath(rawPath);
    final currentSession = service.sessions[snapshot.sessionId];
    final currentSessionPath = currentSession?.currentTrackPath;
    if (currentSession != null &&
        currentSessionPath != null &&
        currentSessionPath.isNotEmpty &&
        PathMatcher.equalsNormalized(resolvedPath, rawPath)) {
      final originalTrack = _sessionTrackForResolvedPath(
        currentSession,
        resolvedPath,
      );
      if (originalTrack != null &&
          PathMatcher.equalsNormalized(
            resolveRetargetedPath(originalTrack.path),
            resolvedPath,
          )) {
        return snapshot.copyWith(
          path: originalTrack.path,
          uri: _snapshotUriForPath(originalTrack.path),
        );
      }
    }
    if (!PathMatcher.equalsNormalized(resolvedPath, rawPath)) {
      return snapshot.copyWith(
        path: resolvedPath,
        uri: _snapshotUriForPath(resolvedPath),
      );
    }
    if (currentSessionPath == null || currentSessionPath.isEmpty) {
      return snapshot;
    }
    final resolvedSessionPath = resolveRetargetedPath(currentSessionPath);
    if (PathMatcher.equalsNormalized(resolvedSessionPath, resolvedPath) ||
        hasLibraryTrack(resolvedPath) ||
        !hasLibraryTrack(resolvedSessionPath)) {
      return snapshot;
    }
    return snapshot.copyWith(
      path: resolvedSessionPath,
      uri: _snapshotUriForPath(resolvedSessionPath),
    );
  }

  MusicTrack? _sessionTrackForResolvedPath(
    PlaybackSession session,
    String resolvedPath,
  ) {
    for (final track in session.customQueueTracks ?? const <MusicTrack>[]) {
      if (PathMatcher.equalsNormalized(
        resolveRetargetedPath(track.path),
        resolvedPath,
      )) {
        return track;
      }
    }
    return null;
  }

  String _snapshotUriForPath(String value) {
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return value;
    }
    return Uri.file(value).toString();
  }

  String? _pathFromSnapshotUri(String? value) {
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    if (uri.scheme == 'file') {
      return uri.toFilePath(windows: isWindowsDriveFileUri(uri));
    }
    if (uri.scheme == 'content' ||
        uri.scheme == 'http' ||
        uri.scheme == 'https') {
      return value;
    }
    return null;
  }

  void publishSessionActivated(String sessionId) {
    if (sessionId.isEmpty || _sessionActivations.isClosed) return;
    _sessionActivations.add(sessionId);
  }

  void attachSessionLauncher(
    Future<void> Function(
      List<MusicTrack> tracks, {
      bool? autoPlay,
      required SessionLoopMode loopMode,
    })
    launchQueue,
  ) {
    _launchQueue ??= launchQueue;
  }

  void attachSessionStatePersistence(Future<void> Function() persist) {
    _persistSessionState ??= persist;
  }

  void attachSessionOrderPersistence(Future<void> Function() persist) {
    _persistSessionOrder ??= persist;
  }

  void configurePersistence({required bool enabled}) {
    _persistenceEnabled = enabled;
    if (!enabled) cancelScheduledPersistence();
  }

  void scheduleSessionStatePersistence({
    Duration delay = const Duration(milliseconds: 220),
  }) {
    if (!_persistenceEnabled) return;
    service.saveSessionStateTimer?.cancel();
    service.saveSessionStateTimer = Timer(delay, () {
      service.saveSessionStateTimer = null;
      unawaited(_persistSessionState?.call());
    });
  }

  void scheduleSessionOrderPersistence({
    Duration delay = const Duration(milliseconds: 180),
  }) {
    if (!_persistenceEnabled) return;
    service.saveSessionOrderTimer?.cancel();
    service.saveSessionOrderTimer = Timer(delay, () {
      service.saveSessionOrderTimer = null;
      unawaited(_persistSessionOrder?.call());
    });
  }

  Future<void> flushSessionStatePersistence() async {
    service.saveSessionStateTimer?.cancel();
    service.saveSessionStateTimer = null;
    await _persistSessionState?.call();
  }

  void cancelScheduledPersistence() {
    service.saveSessionStateTimer?.cancel();
    service.saveSessionStateTimer = null;
    service.saveSessionOrderTimer?.cancel();
    service.saveSessionOrderTimer = null;
  }

  void attachSessionRuntime({
    required void Function(PlaybackSession session) onSessionRegistered,
    required void Function() onSessionsReordered,
    required void Function() onSessionStateChanged,
  }) {
    _onSessionRegistered ??= onSessionRegistered;
    _onSessionsReordered ??= onSessionsReordered;
    _onSessionStateChanged ??= onSessionStateChanged;
  }

  void registerSession(PlaybackSession session) {
    service.registerSession(session);
    _onSessionRegistered?.call(session);
  }

  PlaybackSession createTrackSession(
    MusicTrack track, {
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
    double? volume,
    List<MusicTrack>? customQueueTracks,
  }) {
    final session =
        PlaybackSession(
            id: _nextSessionId(),
            currentTrackPath: track.path,
            loopMode: loopMode,
            nonSingleLoopMode: loopMode == SessionLoopMode.single
                ? SessionLoopMode.folderSequential
                : loopMode,
            volume: (volume ?? 1.0).clamp(0.0, maxSessionVolume).toDouble(),
            createdAt: DateTime.now(),
            state: PlayerState(false, ProcessingState.idle),
            customQueueTracks: customQueueTracks,
          )
          ..speed = 1.0
          ..channelSwapEnabled = false
          ..audioEffects = AudioEffectsState.flat;
    registerSession(session);
    _scheduleNewSessionPersistence();
    return session;
  }

  PlaybackSession createPlaybackQueue(String name) {
    final session = PlaybackSession(
      id: _nextSessionId(),
      currentTrackPath: '',
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime.now(),
      state: PlayerState(false, ProcessingState.idle),
      customQueueTracks: const <MusicTrack>[],
      playbackQueue: PlaybackQueueDefinition(name: name, entries: const []),
    );
    registerSession(session);
    _scheduleNewSessionPersistence();
    return session;
  }

  String _nextSessionId() {
    _sessionSeed += 1;
    return 'session_${DateTime.now().microsecondsSinceEpoch}_$_sessionSeed';
  }

  void _scheduleNewSessionPersistence() {
    scheduleSessionStatePersistence();
    scheduleSessionOrderPersistence();
  }

  void reorderSessions(int oldIndex, int newIndex) {
    final version = service.sessionStateVersion;
    service.reorderSessions(oldIndex, newIndex);
    if (service.sessionStateVersion == version) return;
    _onSessionsReordered?.call();
  }

  bool renamePlaybackQueue(String sessionId, String name) {
    final session = service.sessions[sessionId];
    final queue = session?.playbackQueue;
    final trimmed = name.trim();
    if (session == null || queue == null || trimmed.isEmpty) return false;
    session.playbackQueue = queue.copyWith(name: trimmed);
    service.markActiveSessionsDirty();
    scheduleSessionStatePersistence();
    _onSessionStateChanged?.call();
    return true;
  }

  bool setPlaybackQueueColorValue(String sessionId, int? colorValue) {
    final session = service.sessions[sessionId];
    final queue = session?.playbackQueue;
    if (session == null || queue == null) return false;
    session.playbackQueue = queue.copyWith(
      colorValue: colorValue,
      clearColor: colorValue == null,
    );
    service.markActiveSessionsDirty();
    scheduleSessionStatePersistence();
    _onSessionStateChanged?.call();
    return true;
  }

  bool replaceSessionTrackSnapshots(MusicTrack updatedTrack) {
    var changed = false;
    for (final session in service.sessions.values) {
      final customQueueTracks = session.customQueueTracks;
      if (customQueueTracks != null) {
        var customQueueChanged = false;
        final tracks = customQueueTracks
            .map((track) {
              if (!PathMatcher.equalsNormalized(
                track.path,
                updatedTrack.path,
              )) {
                return track;
              }
              customQueueChanged = true;
              return updatedTrack;
            })
            .toList(growable: false);
        if (customQueueChanged) {
          session.customQueueTracks = List<MusicTrack>.unmodifiable(tracks);
          changed = true;
        }
      }
      final queue = session.playbackQueue;
      if (queue == null) continue;
      var queueChanged = false;
      final entries = queue.entries
          .map((entry) {
            var entryChanged = false;
            final tracks = entry.tracks
                .map((track) {
                  if (!PathMatcher.equalsNormalized(
                    track.path,
                    updatedTrack.path,
                  )) {
                    return track;
                  }
                  entryChanged = true;
                  queueChanged = true;
                  return updatedTrack;
                })
                .toList(growable: false);
            if (!entryChanged) return entry;
            return PlaybackQueueEntry(
              id: entry.id,
              kind: entry.kind,
              title: entry.title,
              tracks: List<MusicTrack>.unmodifiable(tracks),
              workRootPath: entry.workRootPath,
            );
          })
          .toList(growable: false);
      if (!queueChanged) continue;
      session.playbackQueue = queue.copyWith(
        entries: List.unmodifiable(entries),
      );
      changed = true;
    }
    return changed;
  }

  void rememberRetargetedPath(String oldPath, String newPath) {
    final normalizedOldPath = PathMatcher.normalize(oldPath);
    final normalizedNewPath = PathMatcher.normalize(newPath);
    if (PathMatcher.equalsNormalized(normalizedOldPath, normalizedNewPath)) {
      return;
    }
    _retargetedPathAliases[normalizedOldPath] = normalizedNewPath;
  }

  String resolveRetargetedPath(String value) {
    if (value.isEmpty || _retargetedPathAliases.isEmpty) {
      return PathMatcher.normalize(value);
    }
    var current = PathMatcher.normalize(value);
    final seen = <String>{current};
    while (true) {
      String? bestMatch;
      String? nextValue;
      for (final entry in _retargetedPathAliases.entries) {
        if (!PathMatcher.isWithinOrEqual(current, entry.key)) continue;
        if (bestMatch == null || entry.key.length > bestMatch.length) {
          bestMatch = entry.key;
          nextValue = entry.value;
        }
      }
      if (bestMatch == null || nextValue == null) return current;
      final resolved = PathMatcher.normalize(
        PathMatcher.replaceWithinOrEqual(current, bestMatch, nextValue),
      );
      if (PathMatcher.equalsNormalized(resolved, current) ||
          !seen.add(resolved)) {
        return resolved;
      }
      current = resolved;
    }
  }

  void clearRetargetedPaths() => _retargetedPathAliases.clear();

  Future<void> retargetPath(String oldPath, String newPath) async {
    rememberRetargetedPath(oldPath, newPath);
    var changed = false;
    for (final session in service.sessions.values) {
      if (PathMatcher.isWithinOrEqual(session.currentTrackPath, oldPath)) {
        session.currentTrackPath = PathMatcher.replaceWithinOrEqual(
          session.currentTrackPath,
          oldPath,
          newPath,
        );
        changed = true;
      }
      final loadedPath = session.loadedPath;
      if (loadedPath != null &&
          PathMatcher.isWithinOrEqual(loadedPath, oldPath)) {
        session.loadedPath = PathMatcher.replaceWithinOrEqual(
          loadedPath,
          oldPath,
          newPath,
        );
        changed = true;
      }
    }
    if (!changed) return;
    service.markActiveSessionsDirty();
    final current = service.slice.state;
    service.syncSlice(
      activeSessions: service.activeSessions,
      playingSessionCount: service.playingSessionCount,
      focusedSessionId: current.focusedSessionId,
      multiThreadPlaybackEnabled: current.multiThreadPlaybackEnabled,
      coverGeneration: current.coverGeneration,
      isInitialized: current.isInitialized,
    );
    await _persistSessionState?.call();
  }

  Future<void> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) {
    final launch = _launchQueue;
    if (launch == null) {
      throw StateError('PlaybackFacade session launcher is not attached.');
    }
    return launch(tracks, autoPlay: autoPlay, loopMode: loopMode);
  }

  Future<void> dispose() async {
    cancelScheduledPersistence();
    await _sessionActivations.close();
    await nativeRepository.dispose();
    await service.dispose();
    await systemMediaControlsService.dispose();
  }
}

final class PlaybackNativeSnapshotApplication {
  const PlaybackNativeSnapshotApplication({
    required this.snapshot,
    required this.session,
    required this.previousTrackPath,
    required this.trackChanged,
    required this.playbackIntentChanged,
  });

  const PlaybackNativeSnapshotApplication.notApplied(this.snapshot)
    : session = null,
      previousTrackPath = null,
      trackChanged = false,
      playbackIntentChanged = false;

  final NativePlaybackSnapshot snapshot;
  final PlaybackSession? session;
  final String? previousTrackPath;
  final bool trackChanged;
  final bool playbackIntentChanged;

  bool get applied => session != null;
}
