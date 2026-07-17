import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/app/application/playback_keep_alive_coordinator.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_session.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';

void main() {
  test('reports retained playback without mirroring Android power state', () {
    final playback = PlaybackFacade.create(
      databaseRepository: AudioDatabaseRepository(),
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

    playback.service.sessions.clear();
    expect(coordinator.hasPlaybackToKeepAlive, isFalse);
    expect(coordinator.hasRetainedPlaybackSession, isFalse);
  });
}
