import '../../../core/errors/native_result.dart';
import '../../../core/platform/notifications_platform_service.dart';

class PlaybackNotificationService {
  final NotificationsPlatformService _notificationsPlatformService;

  PlaybackNotificationService({
    NotificationsPlatformService? notificationsPlatformService,
  }) : _notificationsPlatformService =
           notificationsPlatformService ?? NotificationsPlatformService();

  Future<NativeResult<void>> clearUnifiedNotifications() =>
      _notificationsPlatformService.clearUnifiedPlaybackNotifications();

  Future<NativeResult<void>> syncUnifiedNotifications(
    Map<String, dynamic> payload,
  ) => _notificationsPlatformService.syncUnifiedPlaybackNotifications(payload);
}
