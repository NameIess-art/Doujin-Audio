import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/platform/notifications_platform_service.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PowerPlatformService', () {
    const channel = MethodChannel('test/power_platform');
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('returns non-Android defaults without invoking the channel', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      final service = PowerPlatformService(
        channel: channel,
        isAndroidOverride: false,
      );

      expect(await service.canManageAllFilesAccess(), isTrue);
      expect(await service.openManageAllFilesAccessSettings(), isFalse);
      expect(await service.isIgnoringBatteryOptimizations(), isTrue);
      expect(await service.openBackgroundRunSettings(), isFalse);
      expect(await service.canScheduleExactAlarms(), isTrue);
      expect(
        await service.executeTimerExpiredNow(7),
        TimerExecutionResult.failed,
      );
      expect(await service.getBackgroundRunDiagnostics(), isNull);
      expect(calls, isEmpty);
    });

    test('sends timer alarm payloads', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return _success(null);
          });
      final service = PowerPlatformService(
        channel: channel,
        isAndroidOverride: true,
      );

      await service.syncPlaybackTimerAlarms(
        timerMode: 1,
        timerDurationMs: 30,
        timerWaitingForPlayback: false,
        timerEndsAtWallClockMs: 40,
        autoResumeEnabled: true,
        autoResumeHour: 7,
        autoResumeMinute: 15,
        autoResumeAtMs: 50,
        pausedSessionIds: const <String>['s1'],
        generation: 2,
      );

      expect(calls.map((call) => call.method), [
        PowerMethod.syncPlaybackTimerAlarms,
      ]);
      expect(calls.last.arguments, containsPair('pausedSessionIds', ['s1']));
      expect(calls.last.arguments, containsPair('generation', 2));
    });

    test('returns conservative defaults on channel errors', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'boom');
          });
      final service = PowerPlatformService(
        channel: channel,
        isAndroidOverride: true,
      );

      expect(await service.canManageAllFilesAccess(), isTrue);
      expect(await service.isIgnoringBatteryOptimizations(), isFalse);
      expect(
        await service.isIgnoringBatteryOptimizations(errorDefault: true),
        isTrue,
      );
      expect(await service.canScheduleExactAlarms(), isTrue);
      expect(await service.openExactAlarmSettings(), isFalse);
      expect(
        await service.executeAutoResumeNow(3),
        TimerExecutionResult.failed,
      );
      expect(await service.getNativeTimerRuntimeState(), isNull);
    });

    test('decodes native timer runtime map', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, PowerMethod.getNativeTimerRuntimeState);
            return _success(<String, Object?>{'generation': 4});
          });
      final service = PowerPlatformService(
        channel: channel,
        isAndroidOverride: true,
      );

      final result = await service.getNativeTimerRuntimeState();

      expect(result, containsPair('generation', 4));
    });

    test('decodes background run diagnostics', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, PowerMethod.getBackgroundRunDiagnostics);
            return _success(<String, Object?>{
              'manufacturer': 'vivo',
              'batteryOptimizationExempt': true,
              'vendorBackgroundSettingsAvailable': true,
              'cleanerForceStopDetected': true,
              'lastExitReason': 10,
              'lastExitDescription': 'single-cleaner',
              'lastExitTimestampMs': 123,
            });
          });
      final service = PowerPlatformService(
        channel: channel,
        isAndroidOverride: true,
      );

      final diagnostics = await service.getBackgroundRunDiagnostics();

      expect(diagnostics?.isVivo, isTrue);
      expect(diagnostics?.batteryOptimizationExempt, isTrue);
      expect(diagnostics?.cleanerForceStopDetected, isTrue);
      expect(diagnostics?.lastExitTimestampMs, 123);
    });
  });

  group('NotificationsPlatformService', () {
    const channel = MethodChannel('test/notifications_platform');
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      channel.setMethodCallHandler(null);
    });

    test(
      'Android never invokes the removed playback notification channel',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return null;
            });
        final service = NotificationsPlatformService(channel: channel);

        await service.syncUnifiedPlaybackNotifications(
          const <String, dynamic>{},
        );
        await service.clearUnifiedPlaybackNotifications();
        expect(calls, isEmpty);
      },
    );

    test('sync and clear call the typed methods', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return _success(null);
          });
      final service = NotificationsPlatformService(
        channel: channel,
        isWindowsOverride: true,
      );

      await service.syncUnifiedPlaybackNotifications(<String, dynamic>{
        'items': const <Object?>[],
      });
      await service.clearUnifiedPlaybackNotifications();

      expect(calls.map((call) => call.method), [
        NotificationsMethod.syncUnifiedPlaybackNotifications,
        NotificationsMethod.clearUnifiedPlaybackNotifications,
      ]);
      expect(calls.first.arguments, containsPair('items', const <Object?>[]));
    });

    test('timeout and exceptions return failures without throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            return Completer<void>().future;
          });
      final service = NotificationsPlatformService(
        channel: channel,
        isWindowsOverride: true,
        timeout: const Duration(milliseconds: 1),
      );

      final syncTimeout = await service.syncUnifiedPlaybackNotifications(
        const <String, dynamic>{},
      );
      expect(syncTimeout.isFailure, isTrue);
      expect(syncTimeout.errorCodeOrNull, NativeErrorCode.platformError);
      final clearTimeout = await service.clearUnifiedPlaybackNotifications();
      expect(clearTimeout.isFailure, isTrue);
      expect(clearTimeout.errorCodeOrNull, NativeErrorCode.platformError);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'boom');
          });
      final syncError = await service.syncUnifiedPlaybackNotifications(
        const <String, dynamic>{},
      );
      expect(syncError.errorCodeOrNull, 'boom');
      final clearError = await service.clearUnifiedPlaybackNotifications();
      expect(clearError.errorCodeOrNull, 'boom');
    });

    test('sync and clear preserve native power request failures', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return <String, Object?>{
              'ok': false,
              'errorCode': 'platform_error',
              'error': 'Power request failed.',
              'details': <String, Object?>{'systemError': 5},
            };
          });
      final service = NotificationsPlatformService(
        channel: channel,
        isWindowsOverride: true,
      );

      final results = <NativeResult<void>>[
        await service.syncUnifiedPlaybackNotifications(
          const <String, dynamic>{},
        ),
        await service.clearUnifiedPlaybackNotifications(),
      ];
      for (final result in results) {
        expect(result.isFailure, isTrue);
        expect(result.errorCodeOrNull, NativeErrorCode.platformError);
        expect(result.errorOrNull, 'Power request failed.');
        expect(result.errorDetailsOrNull, <String, Object?>{'systemError': 5});
      }
    });
  });
}

Map<String, Object?> _success(Object? value) => <String, Object?>{
  'ok': true,
  'value': value,
};
