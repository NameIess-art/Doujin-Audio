import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
import 'platform_channels.dart';

class BackgroundRunDiagnostics {
  const BackgroundRunDiagnostics({
    required this.manufacturer,
    required this.batteryOptimizationExempt,
    required this.vendorBackgroundSettingsAvailable,
    required this.cleanerForceStopDetected,
    this.lastExitReason,
    this.lastExitSubReason,
    this.lastExitDescription,
    this.lastExitTimestampMs,
  });

  final String manufacturer;
  final bool batteryOptimizationExempt;
  final bool vendorBackgroundSettingsAvailable;
  final bool cleanerForceStopDetected;
  final int? lastExitReason;
  final int? lastExitSubReason;
  final String? lastExitDescription;
  final int? lastExitTimestampMs;

  bool get isVivo => manufacturer.toLowerCase() == 'vivo';

  Map<String, Object?> toJson() => <String, Object?>{
    'manufacturer': manufacturer,
    'batteryOptimizationExempt': batteryOptimizationExempt,
    'vendorBackgroundSettingsAvailable': vendorBackgroundSettingsAvailable,
    'cleanerForceStopDetected': cleanerForceStopDetected,
    'lastExitReason': lastExitReason,
    'lastExitSubReason': lastExitSubReason,
    'lastExitDescription': lastExitDescription,
    'lastExitTimestampMs': lastExitTimestampMs,
  };

  factory BackgroundRunDiagnostics.fromMap(Map<dynamic, dynamic> map) {
    return BackgroundRunDiagnostics(
      manufacturer: map['manufacturer'] as String? ?? '',
      batteryOptimizationExempt:
          map['batteryOptimizationExempt'] as bool? ?? false,
      vendorBackgroundSettingsAvailable:
          map['vendorBackgroundSettingsAvailable'] as bool? ?? false,
      cleanerForceStopDetected:
          map['cleanerForceStopDetected'] as bool? ?? false,
      lastExitReason: (map['lastExitReason'] as num?)?.toInt(),
      lastExitSubReason: (map['lastExitSubReason'] as num?)?.toInt(),
      lastExitDescription: map['lastExitDescription'] as String?,
      lastExitTimestampMs: (map['lastExitTimestampMs'] as num?)?.toInt(),
    );
  }
}

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

  Future<BackgroundRunDiagnostics?> getBackgroundRunDiagnostics() async {
    if (!_isAndroid) return null;
    try {
      final map = await _channel.invokeMapMethod<dynamic, dynamic>(
        PowerMethod.getBackgroundRunDiagnostics,
      );
      return map == null ? null : BackgroundRunDiagnostics.fromMap(map);
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<TimerExecutionResult> executeTimerExpiredNow(int generation) {
    return _executeTimerAction(PowerMethod.executeTimerExpiredNow, generation);
  }

  Future<TimerExecutionResult> executeAutoResumeNow(int generation) {
    return _executeTimerAction(PowerMethod.executeAutoResumeNow, generation);
  }

  Future<TimerExecutionResult> _executeTimerAction(
    String method,
    int generation,
  ) async {
    if (!_isAndroid) return TimerExecutionResult.failed;
    try {
      final result = await _channel.invokeMethod<String>(method, {
        'generation': generation,
      });
      return TimerExecutionResult.values.firstWhere(
        (value) => value.name == result,
        orElse: () => TimerExecutionResult.failed,
      );
    } on MissingPluginException {
      return TimerExecutionResult.failed;
    } catch (_) {
      return TimerExecutionResult.failed;
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

enum TimerExecutionResult { executed, stale, failed }
