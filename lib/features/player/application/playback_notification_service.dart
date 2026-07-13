import 'dart:async';
import 'dart:io';

import 'native_playback_bridge.dart';
import '../../../core/platform/notifications_platform_service.dart';

class PlaybackNotificationService {
  final NotificationsPlatformService _notificationsPlatformService;
  bool _enabled = true;

  PlaybackNotificationService({
    NotificationsPlatformService? notificationsPlatformService,
  }) : _notificationsPlatformService =
           notificationsPlatformService ?? NotificationsPlatformService();

  bool get enabled => _enabled;

  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) return;
    if (!enabled) {
      await _clearUnifiedNotifications();
    }
    _enabled = enabled;
    if (enabled && Platform.isAndroid) {
      await NativePlaybackBridge.instance.setForegroundEnabled(true);
    }
  }

  Future<void> clearUnifiedNotifications() async {
    await _clearUnifiedNotifications();
  }

  Future<void> syncUnifiedNotifications(Map<String, dynamic> payload) async {
    if (!_enabled) return;
    await _notificationsPlatformService.syncUnifiedPlaybackNotifications(
      payload,
    );
  }

  Future<void> _clearUnifiedNotifications() async {
    await _notificationsPlatformService.clearUnifiedPlaybackNotifications();
  }
}
