import '../../../core/platform/notifications_platform_service.dart';

class PlaybackNotificationService {
  final NotificationsPlatformService _notificationsPlatformService;

  PlaybackNotificationService({
    NotificationsPlatformService? notificationsPlatformService,
  }) : _notificationsPlatformService =
           notificationsPlatformService ?? NotificationsPlatformService();

  Future<void> clearUnifiedNotifications() =>
      _notificationsPlatformService.clearUnifiedPlaybackNotifications();

  Future<void> syncUnifiedNotifications(Map<String, dynamic> payload) async {
    await _notificationsPlatformService.syncUnifiedPlaybackNotifications(
      payload,
    );
  }
}
