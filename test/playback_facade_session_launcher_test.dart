import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_session_launcher.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'facade launcher forwards queues without depending on AudioProvider',
    () async {
      final facade = PlaybackFacade.create(
        databaseRepository: AudioDatabaseRepository(),
      );
      addTearDown(facade.dispose);
      final launcher = PlaybackFacadeSessionLauncher(facade);
      SessionLoopMode? receivedLoopMode;

      facade.attachSessionLauncher((
        tracks, {
        autoPlay,
        required loopMode,
      }) async {
        receivedLoopMode = loopMode;
        expect(tracks, isEmpty);
        expect(autoPlay, isTrue);
      });

      await launcher.launchQueue(
        const [],
        autoPlay: true,
        loopMode: SessionLoopMode.crossSequential,
      );
      expect(receivedLoopMode, SessionLoopMode.crossSequential);
    },
  );
}
