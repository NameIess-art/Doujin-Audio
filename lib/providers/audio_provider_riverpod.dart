import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_database_repository.dart';
import '../services/audio_state_services.dart';
import '../services/native_playback_repository.dart';
import '../services/playback_command_runner.dart';
import '../screens/screen_view_models.dart';
import 'audio_provider.dart';
import 'subtitle_settings_provider.dart';

final audioProviderFacadeProvider = Provider<AudioProvider>((ref) {
  throw UnimplementedError(
    'audioProviderFacadeProvider must be overridden in ProviderScope.',
  );
});

final audioDatabaseRepositoryProvider = Provider<AudioDatabaseRepository>((
  ref,
) {
  throw UnimplementedError(
    'audioDatabaseRepositoryProvider must be overridden in ProviderScope.',
  );
});

final nativePlaybackRepositoryProvider = Provider<NativePlaybackRepository>((
  ref,
) {
  throw UnimplementedError(
    'nativePlaybackRepositoryProvider must be overridden in ProviderScope.',
  );
});

final playbackCommandRunnerProvider = Provider<PlaybackCommandRunner>((ref) {
  throw UnimplementedError(
    'playbackCommandRunnerProvider must be overridden in ProviderScope.',
  );
});

final libraryServiceProvider = Provider<LibraryService>((ref) {
  throw UnimplementedError(
    'libraryServiceProvider must be overridden in ProviderScope.',
  );
});

final playbackSessionServiceProvider = Provider<PlaybackSessionService>((ref) {
  throw UnimplementedError(
    'playbackSessionServiceProvider must be overridden in ProviderScope.',
  );
});

final timerServiceProvider = Provider<TimerService>((ref) {
  throw UnimplementedError(
    'timerServiceProvider must be overridden in ProviderScope.',
  );
});

final notificationCoordinatorServiceProvider =
    Provider<NotificationCoordinatorService>((ref) {
      throw UnimplementedError(
        'notificationCoordinatorServiceProvider must be overridden in ProviderScope.',
      );
    });

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw UnimplementedError(
    'settingsRepositoryProvider must be overridden in ProviderScope.',
  );
});

final libraryStateProvider = StreamProvider<LibraryState>((ref) {
  return ref.watch(libraryServiceProvider).slice.stream;
});

final playbackStateProvider = StreamProvider<PlaybackStateSliceData>((ref) {
  return ref.watch(playbackSessionServiceProvider).slice.stream;
});

final timerStateProvider = StreamProvider<TimerStateSliceData>((ref) {
  return ref.watch(timerServiceProvider).slice.stream;
});

final settingsStateProvider = StreamProvider<SettingsState>((ref) {
  return ref.watch(settingsRepositoryProvider).slice.stream;
});

final notificationStateProvider = StreamProvider<NotificationState>((ref) {
  return ref.watch(notificationCoordinatorServiceProvider).slice.stream;
});

final libraryUiProvider = Provider<LibraryUiState>((ref) {
  final libraryState = ref.watch(
    libraryStateProvider.select((value) {
      final state = value.valueOrNull ?? const LibraryState();
      final showForegroundScan =
          state.isScanning && !state.isBackgroundScanning;
      return LibraryState(
        libraryTrackCount: state.libraryTrackCount,
        watchedFolderCount: state.watchedFolderCount,
        watchedLibraryCount: state.watchedLibraryCount,
        isScanning: showForegroundScan,
        scanCurrentFolder: showForegroundScan ? state.scanCurrentFolder : '',
        scanFoundCount: showForegroundScan ? state.scanFoundCount : 0,
        scanDuplicateCount: showForegroundScan ? state.scanDuplicateCount : 0,
        scanFailureCount: showForegroundScan ? state.scanFailureCount : 0,
        structureRevision: state.structureRevision,
        contentRevision: state.contentRevision,
        detailRevision: state.detailRevision,
        isInitialized: state.isInitialized,
      );
    }),
  );
  final provider = ref.watch(audioProviderFacadeProvider);
  final header = libraryHeaderStateFromSlice(libraryState);
  return LibraryUiState(
    header: header,
    list: LibraryListState(
      rawTree: provider.libraryTree,
      watchedFolders: provider.watchedFolders,
      watchedLibraries: provider.watchedLibraries,
      watchedFolderCount: libraryState.watchedFolderCount,
      watchedLibraryCount: libraryState.watchedLibraryCount,
      isScanning: libraryState.isScanning,
      isBackgroundScanning: libraryState.isBackgroundScanning,
      scanCurrentFolder: libraryState.scanCurrentFolder,
      scanFoundCount: libraryState.scanFoundCount,
      scanDuplicateCount: libraryState.scanDuplicateCount,
      scanFailureCount: libraryState.scanFailureCount,
      structureRevision: libraryState.contentRevision,
      isInitialized: libraryState.isInitialized,
    ),
    detailRevision: libraryState.detailRevision,
  );
});

final playlistUiProvider = Provider<PlaylistUiState>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).valueOrNull ??
      const PlaybackStateSliceData();
  final timerState =
      ref.watch(timerStateProvider).valueOrNull ?? const TimerStateSliceData();
  return PlaylistUiState(
    header: playlistHeaderStateFromSlices(playbackState, timerState),
    list: PlaylistListState(
      sessions: playbackState.activeSessions,
      isInitialized: playbackState.isInitialized,
    ),
    coverGeneration: playbackState.coverGeneration,
  );
});

final mainOverlayUiProvider = Provider<MainOverlayUiState>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).valueOrNull ??
      const PlaybackStateSliceData();
  final settingsState =
      ref.watch(settingsStateProvider).valueOrNull ?? const SettingsState();
  final subtitleSettings = ref.watch(subtitleSettingsProvider);
  final overlaySessions = overlaySessionsFromPlaybackState(playbackState);
  final visibleSessions = settingsState.showPlaybackCard
      ? overlaySessions
      : const <PlaybackSession>[];
  final subtitleSessions = overlaySessions
      .where((session) => subtitleSettings.isGlobalEnabled(session.id))
      .toList(growable: false);
  return MainOverlayUiState(
    overlaySessions: overlaySessions,
    visibleSessions: visibleSessions,
    subtitleSessions: subtitleSessions,
    playingSessionCount: playbackState.playingSessionCount,
    activeSessionCount: playbackState.activeSessions.length,
    showPlaybackCard: settingsState.showPlaybackCard,
    isInitialized: playbackState.isInitialized,
  );
});

final sessionDetailUiProvider = Provider.family<SessionDetailUiState, String>((
  ref,
  sessionId,
) {
  final playbackState =
      ref.watch(playbackStateProvider).valueOrNull ??
      const PlaybackStateSliceData();
  return SessionDetailUiState(
    sessionOrder: sessionOrderStateFromPlaybackState(playbackState),
    detail: sessionDetailViewStateFromPlaybackState(playbackState, sessionId),
    coverGeneration: playbackState.coverGeneration,
  );
});

List<Override> createAudioProviderOverrides({
  required AudioProvider audioProvider,
  required AudioDatabaseRepository audioDatabaseRepository,
  required NativePlaybackRepository nativePlaybackRepository,
  required PlaybackCommandRunner playbackCommandRunner,
  required LibraryService libraryService,
  required PlaybackSessionService playbackService,
  required TimerService timerService,
  required NotificationCoordinatorService notificationCoordinatorService,
  required SettingsRepository settingsRepository,
}) {
  return <Override>[
    audioProviderFacadeProvider.overrideWithValue(audioProvider),
    audioDatabaseRepositoryProvider.overrideWithValue(audioDatabaseRepository),
    nativePlaybackRepositoryProvider.overrideWithValue(
      nativePlaybackRepository,
    ),
    playbackCommandRunnerProvider.overrideWithValue(playbackCommandRunner),
    libraryServiceProvider.overrideWithValue(libraryService),
    playbackSessionServiceProvider.overrideWithValue(playbackService),
    timerServiceProvider.overrideWithValue(timerService),
    notificationCoordinatorServiceProvider.overrideWithValue(
      notificationCoordinatorService,
    ),
    settingsRepositoryProvider.overrideWithValue(settingsRepository),
  ];
}
