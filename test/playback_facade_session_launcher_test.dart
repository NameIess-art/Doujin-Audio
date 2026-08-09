import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_session_launcher.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('facade launcher forwards queues through the playback owner', () async {
    final facade = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
    );
    addTearDown(facade.dispose);
    final launcher = PlaybackFacadeSessionLauncher(facade);
    var prepared = false;

    facade.attachPlaybackCommands(
      prepareSession:
          (
            session, {
            required nextPath,
            autoPlay = true,
            forceStartAtZero = false,
            showLoading = true,
            targetQueueIndex,
          }) async {
            prepared = true;
            return true;
          },
      pauseSession: (_) async {},
      startSession: (_, {required shouldStartTriggerCountdown}) async => true,
      resolveAdvance: (_, {required forward}) => null,
      hasAdjacent: (_, {required forward}) => false,
    );

    await launcher.launchQueue(
      [
        MusicTrack(
          path: '/tracks/launcher.mp3',
          displayName: 'Launcher',
          groupKey: '/tracks',
          groupTitle: 'Tracks',
          groupSubtitle: '',
          isSingle: true,
        ),
      ],
      autoPlay: true,
      loopMode: SessionLoopMode.crossSequential,
    );
    await facade.pendingSessionPreparation;
    expect(prepared, isTrue);
    expect(
      facade.ordinarySessions.single.loopMode,
      SessionLoopMode.crossSequential,
    );
  });
}
