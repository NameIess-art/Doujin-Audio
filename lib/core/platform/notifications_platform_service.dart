import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_platform.dart';
import '../logging/app_log_service.dart';
import 'platform_channels.dart';

typedef NotificationSessionHandler = void Function(String sessionId);

class NotificationsPlatformService {
  NotificationsPlatformService({
    MethodChannel? channel,
    @visibleForTesting bool? isAndroidOverride,
    Duration timeout = const Duration(seconds: 5),
  }) : _channel = channel ?? const MethodChannel(NotificationsChannel.name),
       _isAndroidOverride = isAndroidOverride,
       _timeout = timeout;

  final MethodChannel _channel;
  final bool? _isAndroidOverride;
  final Duration _timeout;

  bool get _isAndroid => _isAndroidOverride ?? AppPlatform.isAndroid;

  Future<bool> areNotificationsEnabled() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>(
            NotificationsMethod.areNotificationsEnabled,
          ) ??
          true;
    } on MissingPluginException {
      return true;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'notification_permission_check_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return true;
    }
  }

  Future<bool> openNotificationSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            NotificationsMethod.openNotificationSettings,
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'open_notification_settings_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<String?> consumePendingNotificationSessionId() async {
    if (!_isAndroid) return null;
    try {
      final sessionId = await _channel.invokeMethod<String>(
        NotificationsMethod.consumePendingNotificationSessionId,
      );
      return sessionId == null || sessionId.isEmpty ? null : sessionId;
    } on MissingPluginException {
      return null;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'consume_pending_notification_session_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  void setOpenSessionHandler(NotificationSessionHandler? handler) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method != NotificationsMethod.openSessionFromNotification) {
        return null;
      }
      final sessionId = _sessionIdFromArguments(call.arguments);
      if (sessionId != null && sessionId.isNotEmpty) {
        handler(sessionId);
      }
      return null;
    });
  }

  Future<void> syncUnifiedPlaybackNotifications(
    Map<String, dynamic> payload,
  ) async {
    if (!_isAndroid) return;
    try {
      await _channel
          .invokeMethod<void>(
            NotificationsMethod.syncUnifiedPlaybackNotifications,
            payload,
          )
          .timeout(
            _timeout,
            onTimeout: () =>
                AppLogService.warning('notification_sync_timed_out'),
          );
    } on MissingPluginException {
      // Channel not available on this platform.
    } catch (error, stackTrace) {
      AppLogService.error(
        'notification_sync_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> clearUnifiedPlaybackNotifications() async {
    if (!_isAndroid) return;
    try {
      await _channel
          .invokeMethod<void>(
            NotificationsMethod.clearUnifiedPlaybackNotifications,
          )
          .timeout(
            _timeout,
            onTimeout: () =>
                AppLogService.warning('notification_clear_timed_out'),
          );
    } on MissingPluginException {
      // Channel not available on this platform.
    } catch (error, stackTrace) {
      AppLogService.error(
        'notification_clear_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String? _sessionIdFromArguments(Object? arguments) {
    if (arguments is Map) {
      return arguments['sessionId'] as String?;
    }
    if (arguments is String) {
      return arguments;
    }
    return null;
  }
}
