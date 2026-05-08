import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_database_repository.dart';
import '../services/audio_state_services.dart';
import '../services/native_playback_repository.dart';
import '../services/playback_command_runner.dart';
import 'audio_provider.dart';

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
