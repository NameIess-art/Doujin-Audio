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

  Future<NativeResult<void>> syncUnifiedPlaybackNotifications(
    Map<String, dynamic> payload,
  ) => _invoke(
    NotificationsMethod.syncUnifiedPlaybackNotifications,
    arguments: payload,
    timeoutMessage: 'Notification sync timed out.',
  );

  Future<NativeResult<void>> clearUnifiedPlaybackNotifications() => _invoke(
    NotificationsMethod.clearUnifiedPlaybackNotifications,
    timeoutMessage: 'Notification clear timed out.',
  );

  Future<NativeResult<void>> _invoke(
    String method, {
    Map<String, dynamic>? arguments,
    required String timeoutMessage,
  }) async {
    if (!_isWindows) return const NativeSuccess<void>();
    final result = await _client
        .invoke<void>(method, arguments: arguments, decode: (_) {})
        .timeout(
          _timeout,
          onTimeout: () => NativeFailure<void>(
            timeoutMessage,
            code: NativeErrorCode.platformError,
          ),
        );
    if (result case NativeFailure<void>(
      :final code,
      :final message,
      :final details,
    )) {
      AppLogService.warning(
        'notifications_platform_method_failed method=$method code=$code',
        error: <String, Object?>{'message': message, 'details': details},
      );
    }
    return result;
  }
}
