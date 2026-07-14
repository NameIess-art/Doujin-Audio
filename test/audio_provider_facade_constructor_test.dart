import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/player/application/audio_state_services.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/features/player/application/timer_facade.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production facade constructor requires only five high-level owners',
    () {
      final library = LibraryFacade.create();
      final playback = PlaybackFacade.create(
        databaseRepository: library.databaseRepository,
      );
      final timer = TimerFacade.create();
      final notification = NotificationFacade.create(
        service: PlaybackNotificationService(),
      );
      final settings = SettingsRepository();
      final provider = AudioProvider(
        library: library,
        playback: playback,
        timer: timer,
        notification: notification,
        settings: settings,
        deferRuntimeStart: true,
      );
      addTearDown(provider.dispose);

      expect(provider.libraryFacade, same(library));
      expect(provider.playbackFacade, same(playback));
      expect(provider.timerFacade, same(timer));
      expect(provider.notificationFacade, same(notification));
      expect(provider.settingsRepository, same(settings));
    },
  );
}
