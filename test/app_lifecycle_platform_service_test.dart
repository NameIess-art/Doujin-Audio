import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/platform/app_lifecycle_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/app_lifecycle');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'pending restore termination uses the native lifecycle method',
    () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return <String, Object?>{'ok': true, 'value': null};
      });
      final service = AppLifecyclePlatformService(
        channel: channel,
        isAndroidOverride: true,
      );

      expect(await service.terminateForPendingRestore(), isTrue);
      expect(received?.method, 'terminateForPendingRestore');
      expect(received?.arguments, isNull);
    },
  );

  test('pending restore termination reports native failure', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return <String, Object?>{
        'ok': false,
        'errorCode': 'platform_error',
        'error': 'failed',
      };
    });
    final service = AppLifecyclePlatformService(
      channel: channel,
      isAndroidOverride: true,
    );

    expect(await service.terminateForPendingRestore(), isFalse);
  });

  test('app theme sync sends preset, theme mode, and pureBlack to Android', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <String, Object?>{'ok': true, 'value': null};
    });
    final service = AppLifecyclePlatformService(
      channel: channel,
      isAndroidOverride: true,
    );

    expect(
      await service.syncAppTheme(
        preset: 'mint',
        themeMode: 'dark',
        pureBlack: true,
      ),
      isTrue,
    );
    expect(received?.method, 'syncAppTheme');
    expect(received?.arguments, <String, Object>{
      'preset': 'mint',
      'themeMode': 'dark',
      'pureBlack': true,
    });
  });

  test('getSystemAccentColor returns native ARGB accent when available', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getSystemAccentColor') {
        return <String, Object?>{'ok': true, 'value': 0xFF3366CC};
      }
      return null;
    });
    final service = AppLifecyclePlatformService(
      channel: channel,
      isAndroidOverride: true,
    );

    expect(await service.getSystemAccentColor(), 0xFF3366CC);
  });
}
