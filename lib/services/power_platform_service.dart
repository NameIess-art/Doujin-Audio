import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
import 'platform_channels.dart';

class PowerPlatformService {
  PowerPlatformService({
    MethodChannel? channel,
    @visibleForTesting bool? isAndroidOverride,
  }) : _channel = channel ?? const MethodChannel(PowerChannel.name),
       _isAndroidOverride = isAndroidOverride;

  final MethodChannel _channel;
  final bool? _isAndroidOverride;

  bool get _isAndroid => _isAndroidOverride ?? AppPlatform.isAndroid;

  Future<void> setKeepCpuAwake({
    required bool enabled,
    required bool hasActivePlayback,
    required bool hasActiveTimer,
    required bool usesUnifiedPlaybackNotifications,
    required bool keepForegroundServiceAlive,
  }) async {
    await _invokeBestEffort<void>(PowerMethod.setKeepCpuAwake, {
      'enabled': enabled,
      'hasActivePlayback': hasActivePlayback,
      'hasActiveTimer': hasActiveTimer,
      'usesUnifiedPlaybackNotifications': usesUnifiedPlaybackNotifications,
      'keepForegroundServiceAlive': keepForegroundServiceAlive,
    });
  }

  Future<void> stopPlaybackKeepAlive() async {
    await _invokeBestEffort<void>(PowerMethod.stopPlaybackKeepAlive);
  }

  Future<void> syncPlaybackTimerAlarms({
    required int? timerMode,
    required int? timerDurationMs,
    required bool timerWaitingForPlayback,
    required int? timerEndsAtWallClockMs,
    required bool autoResumeEnabled,
    required int autoResumeHour,
    required int autoResumeMinute,
    required int? autoResumeAtMs,
    required List<String> pausedSessionIds,
    required int generation,
  }) async {
    await _invokeBestEffort<void>(PowerMethod.syncPlaybackTimerAlarms, {
      'timerMode': timerMode,
      'timerDurationMs': timerDurationMs,
      'timerWaitingForPlayback': timerWaitingForPlayback,
      'timerEndsAtWallClockMs': timerEndsAtWallClockMs,
      'autoResumeEnabled': autoResumeEnabled,
      'autoResumeHour': autoResumeHour,
      'autoResumeMinute': autoResumeMinute,
      'autoResumeAtMs': autoResumeAtMs,
      'pausedSessionIds': pausedSessionIds,
      'generation': generation,
    });
  }

  Future<bool> canManageAllFilesAccess() async {
    if (!_isAndroid) return true;
    return _invokeBool(
      PowerMethod.canManageAllFilesAccess,
      missingPluginDefault: true,
      errorDefault: true,
    );
  }

  Future<bool> openManageAllFilesAccessSettings() async {
    if (!_isAndroid) return false;
    return _invokeBool(
      PowerMethod.openManageAllFilesAccessSettings,
      missingPluginDefault: false,
      errorDefault: false,
    );
  }

  Future<bool> isIgnoringBatteryOptimizations({
    bool errorDefault = false,
  }) async {
    if (!_isAndroid) return true;
    return _invokeBool(
      PowerMethod.isIgnoringBatteryOptimizations,
      missingPluginDefault: true,
      errorDefault: errorDefault,
    );
  }

  Future<bool> openBatteryOptimizationSettings() async {
    if (!_isAndroid) return false;
    return _invokeBool(
      PowerMethod.openBatteryOptimizationSettings,
      missingPluginDefault: false,
      errorDefault: false,
    );
  }

  Future<bool> openBackgroundRunSettings() async {
    if (!_isAndroid) return false;
    return _invokeBool(
      PowerMethod.openBackgroundRunSettings,
      missingPluginDefault: false,
      errorDefault: false,
    );
  }

  Future<bool> canScheduleExactAlarms() async {
    if (!_isAndroid) return true;
    return _invokeBool(
      PowerMethod.canScheduleExactAlarms,
      missingPluginDefault: true,
      errorDefault: true,
    );
  }

  Future<bool> openExactAlarmSettings() async {
    if (!_isAndroid) return false;
    return _invokeBool(
      PowerMethod.openExactAlarmSettings,
      missingPluginDefault: false,
      errorDefault: false,
    );
  }

  Future<Map<dynamic, dynamic>?> getNativeTimerRuntimeState() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMapMethod<dynamic, dynamic>(
        PowerMethod.getNativeTimerRuntimeState,
      );
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> executeTimerExpiredNow(int generation) {
    return _executeTimerAction(PowerMethod.executeTimerExpiredNow, generation);
  }

  Future<bool> executeAutoResumeNow(int generation) {
    return _executeTimerAction(PowerMethod.executeAutoResumeNow, generation);
  }

  Future<bool> _executeTimerAction(String method, int generation) async {
    if (!_isAndroid) return false;
    try {
      await _channel.invokeMethod<bool>(method, {'generation': generation});
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<T?> _invokeBestEffort<T>(String method, [Object? arguments]) async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _invokeBool(
    String method, {
    required bool missingPluginDefault,
    required bool errorDefault,
  }) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? errorDefault;
    } on MissingPluginException {
      return missingPluginDefault;
    } catch (_) {
      return errorDefault;
    }
  }
}
