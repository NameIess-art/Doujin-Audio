import 'dart:async';

import 'audio_state_services.dart';
import 'playback_notification_service.dart';

/// Owns notification synchronization state and the notification gateway.
final class NotificationFacade {
  NotificationFacade({required this.service, required this.stateService});

  factory NotificationFacade.create({
    required PlaybackNotificationService service,
    NotificationCoordinatorService? stateService,
  }) {
    return NotificationFacade(
      service: service,
      stateService: stateService ?? NotificationCoordinatorService(),
    );
  }

  final PlaybackNotificationService service;
  final NotificationCoordinatorService stateService;
  Future<void> Function() _undismissNotifications = _noopAsync;
  void Function() _onNotificationsRestored = _noop;

  NotificationState get state => stateService.slice.state;
  Stream<NotificationState> get states => stateService.slice.stream;

  void attachRuntime({
    required Future<void> Function() undismissNotifications,
    required void Function() onNotificationsRestored,
  }) {
    _undismissNotifications = undismissNotifications;
    _onNotificationsRestored = onNotificationsRestored;
  }

  Future<void> restoreAfterSystemClear() async {
    stateService.notificationsDismissedWhilePaused = false;
    stateService.unifiedNotificationSyncKey = null;
    await _undismissNotifications();
    _onNotificationsRestored();
  }

  void resyncAfterForegroundResume() {
    if (!stateService.notificationsDismissedWhilePaused) return;
    stateService.notificationsDismissedWhilePaused = false;
    stateService.unifiedNotificationSyncKey = null;
    unawaited(_undismissNotifications());
    _onNotificationsRestored();
  }

  Future<void> dispose() => stateService.dispose();
}

void _noop() {}
Future<void> _noopAsync() async {}
