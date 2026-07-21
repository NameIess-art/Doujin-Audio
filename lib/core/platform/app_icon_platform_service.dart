import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import '../logging/app_log_service.dart';
import '../ui/app_icon_color_group.dart';
import 'app_platform.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

class AppIconPlatformService {
  AppIconPlatformService({
    MethodChannel? channel,
    @visibleForTesting bool? isAndroidOverride,
  }) : _client = PlatformMethodClient(
         channel ?? const MethodChannel(AppIconChannel.name),
       ),
       _isAndroidOverride = isAndroidOverride;

  final PlatformMethodClient _client;
  final bool? _isAndroidOverride;

  bool get _isAndroid => _isAndroidOverride ?? AppPlatform.isAndroid;

  Future<void> syncThemeMode(
    ThemeMode mode,
    AppIconColorGroup colorGroup,
  ) async {
    if (!_isAndroid) return;
    final result = await _client.invoke<void>(
      AppIconMethod.syncThemeMode,
      arguments: <String, Object?>{
        'mode': mode.name,
        'colorGroup': colorGroup.name,
      },
      decode: (_) {},
    );
    if (result case NativeFailure<void>(
      :final code,
      :final message,
      :final details,
    )) {
      AppLogService.warning(
        'app_icon_theme_sync_failed code=$code',
        error: <String, Object?>{
          'message': message,
          'details': details,
          'themeMode': mode.name,
          'colorGroup': colorGroup.name,
        },
      );
    }
  }
}
