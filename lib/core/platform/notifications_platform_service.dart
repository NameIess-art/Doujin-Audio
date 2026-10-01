import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import '../logging/app_log_service.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

class NotificationsPlatformService {
  NotificationsPlatformService({
    MethodChannel? channel,
    @visibleForTesting bool? isWindowsOverride,
    Duration timeout = const Duration(seconds: 5),
  }) : _client = PlatformMethodClient(
         channel ?? const MethodChannel(NotificationsChannel.name),
       ),
       _isWindowsOverride = isWindowsOverride,
       _timeout = timeout;

  final PlatformMethodClient _client;
  final bool? _isWindowsOverride;
  final Duration _timeout;

  bool get _isWindows =>
      _isWindowsOverride ?? defaultTargetPlatform == TargetPlatform.windows;

  Future<void> syncUnifiedPlaybackNotifications(
    Map<String, dynamic> payload,
  ) async {
    if (!_isWindows) return;
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
    if (!_isWindows) return;
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
