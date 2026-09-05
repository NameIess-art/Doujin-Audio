import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/playback_keep_alive_coordinator.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';

void main() {
  test(
    'reports retained playback without mirroring Android power state',
    () async {
      final playback = PlaybackFacade.create(
        databaseRepository: TestPersistenceRepository(),
        nativeRepository: _SuccessfulClearNativePlaybackRepository(),
      );
      final settings = SettingsRepository();
      final coordinator = PlaybackKeepAliveCoordinator(
        playback: playback,
        settings: settings,
        enterBackgroundWarmup: () {},
        resumeForegroundWarmup: () {},
      );
      addTearDown(playback.dispose);
      addTearDown(settings.dispose);

      final session = PlaybackSession(
        id: 'session-a',
        currentTrackPath: 'track.mp3',
        loopMode: SessionLoopMode.folderSequential,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.ready),
      )..loadedPath = 'track.mp3';
      playback.registerSession(session);

      expect(coordinator.hasPlaybackToKeepAlive, isTrue);
      expect(coordinator.hasRetainedPlaybackSession, isTrue);

      await playback.clearAllSessions();
      expect(coordinator.hasPlaybackToKeepAlive, isFalse);
      expect(coordinator.hasRetainedPlaybackSession, isFalse);
    },
  );
}

final class _SuccessfulClearNativePlaybackRepository
    extends NativePlaybackRepository {
  @override
  Future<NativeResult<void>> clearAll() async => const NativeSuccess<void>();
}
