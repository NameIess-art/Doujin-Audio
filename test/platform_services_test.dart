import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/platform/notifications_platform_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/core/platform/power_platform_service.dart';

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

    test('returns non-Android defaults without invoking the channel', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      final service = NotificationsPlatformService(
        channel: channel,
        isAndroidOverride: false,
      );

      expect(await service.areNotificationsEnabled(), isTrue);
      expect(await service.openNotificationSettings(), isFalse);
      expect(await service.consumePendingNotificationSessionId(), isNull);
      await service.syncUnifiedPlaybackNotifications(const <String, dynamic>{});
      await service.clearUnifiedPlaybackNotifications();
      expect(calls, isEmpty);
    });

    test('sync and clear call the typed methods', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return _success(null);
          });
      final service = NotificationsPlatformService(
        channel: channel,
        isAndroidOverride: true,
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

    test(
      'queries notification state and consumes pending session id',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return _success(switch (call.method) {
                NotificationsMethod.areNotificationsEnabled => true,
                NotificationsMethod.openNotificationSettings => true,
                NotificationsMethod.consumePendingNotificationSessionId =>
                  'session-3',
                _ => null,
              });
            });
        final service = NotificationsPlatformService(
          channel: channel,
          isAndroidOverride: true,
        );

        expect(await service.areNotificationsEnabled(), isTrue);
        expect(await service.openNotificationSettings(), isTrue);
        expect(
          await service.consumePendingNotificationSessionId(),
          'session-3',
        );
        expect(calls.map((call) => call.method), [
          NotificationsMethod.areNotificationsEnabled,
          NotificationsMethod.openNotificationSettings,
          NotificationsMethod.consumePendingNotificationSessionId,
        ]);
      },
    );

    test('timeout and exceptions do not throw', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            return Completer<void>().future;
          });
      final service = NotificationsPlatformService(
        channel: channel,
        isAndroidOverride: true,
        timeout: const Duration(milliseconds: 1),
      );

      await service.syncUnifiedPlaybackNotifications(const <String, dynamic>{});

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'boom');
          });
      await service.clearUnifiedPlaybackNotifications();
    });

    test('open-session handler only forwards matching session calls', () async {
      final service = NotificationsPlatformService(
        channel: channel,
        isAndroidOverride: true,
      );
      final openedSessions = <String>[];
      service.setOpenSessionHandler(openedSessions.add);

      await _sendPlatformMethodCall(
        channel,
        const MethodCall('ignored', <String, Object?>{'sessionId': 'x'}),
      );
      await _sendPlatformMethodCall(
        channel,
        const MethodCall(
          NotificationsMethod.openSessionFromNotification,
          <String, Object?>{'sessionId': 'session-1'},
        ),
      );
      await _sendPlatformMethodCall(
        channel,
        const MethodCall(
          NotificationsMethod.openSessionFromNotification,
          'session-2',
        ),
      );

      expect(openedSessions, ['session-1', 'session-2']);
    });
  });
}

Future<void> _sendPlatformMethodCall(MethodChannel channel, MethodCall call) {
  final completer = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(call),
        (ByteData? data) => completer.complete(),
      );
  return completer.future;
}

Map<String, Object?> _success(Object? value) => <String, Object?>{
  'ok': true,
  'value': value,
};
