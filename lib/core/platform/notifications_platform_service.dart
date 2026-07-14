import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import 'app_platform.dart';
import '../logging/app_log_service.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

typedef NotificationSessionHandler = void Function(String sessionId);

class NotificationsPlatformService {
  NotificationsPlatformService({
    MethodChannel? channel,
    @visibleForTesting bool? isAndroidOverride,
    Duration timeout = const Duration(seconds: 5),
  }) : _channel = channel ?? const MethodChannel(NotificationsChannel.name),
       _client = PlatformMethodClient(
         channel ?? const MethodChannel(NotificationsChannel.name),
       ),
       _isAndroidOverride = isAndroidOverride,
       _timeout = timeout;

  final MethodChannel _channel;
  final PlatformMethodClient _client;
  final bool? _isAndroidOverride;
  final Duration _timeout;

  bool get _isAndroid => _isAndroidOverride ?? AppPlatform.isAndroid;

  Future<bool> areNotificationsEnabled() async {
    if (!_isAndroid) return true;
    final result = await _client.invoke<bool>(
      NotificationsMethod.areNotificationsEnabled,
      decode: (value) => value as bool,
    );
    _logFailure(NotificationsMethod.areNotificationsEnabled, result);
    return result.valueOrNull ?? true;
  }

  Future<bool> openNotificationSettings() async {
    if (!_isAndroid) return false;
    final result = await _client.invoke<bool>(
      NotificationsMethod.openNotificationSettings,
      decode: (value) => value as bool,
    );
    _logFailure(NotificationsMethod.openNotificationSettings, result);
    return result.valueOrNull ?? false;
  }

  Future<String?> consumePendingNotificationSessionId() async {
    if (!_isAndroid) return null;
    final result = await _client.invoke<String?>(
      NotificationsMethod.consumePendingNotificationSessionId,
      decode: (value) => value as String?,
    );
    _logFailure(
      NotificationsMethod.consumePendingNotificationSessionId,
      result,
    );
    final sessionId = result.valueOrNull;
    return sessionId == null || sessionId.isEmpty ? null : sessionId;
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
      final result = await _client
          .invoke<void>(
            NotificationsMethod.syncUnifiedPlaybackNotifications,
            arguments: payload,
            decode: (_) {},
          )
          .timeout(
            _timeout,
            onTimeout: () {
              AppLogService.warning('notification_sync_timed_out');
              throw TimeoutException('Notification sync timed out.');
            },
          );
      _logFailure(NotificationsMethod.syncUnifiedPlaybackNotifications, result);
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
      final result = await _client
          .invoke<void>(
            NotificationsMethod.clearUnifiedPlaybackNotifications,
            decode: (_) {},
          )
          .timeout(
            _timeout,
            onTimeout: () {
              AppLogService.warning('notification_clear_timed_out');
              throw TimeoutException('Notification clear timed out.');
            },
          );
      _logFailure(
        NotificationsMethod.clearUnifiedPlaybackNotifications,
        result,
      );
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

  void _logFailure<T>(String method, NativeResult<T> result) {
    if (result case NativeFailure<T>(
      :final code,
      :final message,
      :final details,
    )) {
      AppLogService.warning(
        'notifications_platform_method_failed method=$method code=$code',
        error: <String, Object?>{'message': message, 'details': details},
      );
    }
  }
}
