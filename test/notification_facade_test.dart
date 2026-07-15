import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';

void main() {
  test('NotificationFacade owns foreground notification recovery', () async {
    final facade = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    addTearDown(facade.dispose);
    var undismissCount = 0;
    var restoredCount = 0;
    facade.attachRuntime(
      undismissNotifications: () async => undismissCount++,
      onNotificationsRestored: () => restoredCount++,
    );
    facade.stateService
      ..notificationsDismissedWhilePaused = true
      ..unifiedNotificationSyncKey = 'stale';

    facade.resyncAfterForegroundResume();
    await Future<void>.delayed(Duration.zero);

    expect(facade.stateService.notificationsDismissedWhilePaused, isFalse);
    expect(facade.stateService.unifiedNotificationSyncKey, isNull);
    expect(undismissCount, 1);
    expect(restoredCount, 1);

    facade.resyncAfterForegroundResume();
    await Future<void>.delayed(Duration.zero);
    expect(undismissCount, 1);
    expect(restoredCount, 1);
  });
}
