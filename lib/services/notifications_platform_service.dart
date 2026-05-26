import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
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
    } catch (_) {
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
    } catch (_) {
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
    } catch (_) {
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
            onTimeout: () => debugPrint(
              'NotificationsPlatformService.syncUnifiedPlaybackNotifications timed out',
            ),
          );
    } on MissingPluginException {
      // Channel not available on this platform.
    } catch (e) {
      debugPrint(
        'NotificationsPlatformService.syncUnifiedPlaybackNotifications error: $e',
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
            onTimeout: () => debugPrint(
              'NotificationsPlatformService.clearUnifiedPlaybackNotifications timed out',
            ),
          );
    } on MissingPluginException {
      // Channel not available on this platform.
    } catch (e) {
      debugPrint(
        'NotificationsPlatformService.clearUnifiedPlaybackNotifications error: $e',
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
