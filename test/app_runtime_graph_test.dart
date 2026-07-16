import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/app_runtime_graph.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/features/player/application/timer_facade.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';

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
      final runtimeGraph = createAppRuntimeGraph(
        library: library,
        playback: playback,
        timer: timer,
        notifications: notification,
        settings: settings,
      );
      addTearDown(runtimeGraph.runtime.dispose);

      expect(runtimeGraph.library, same(library));
      expect(runtimeGraph.playback, same(playback));
      expect(runtimeGraph.timer, same(timer));
      expect(runtimeGraph.notifications, same(notification));
      expect(runtimeGraph.settings, same(settings));
    },
  );
}
