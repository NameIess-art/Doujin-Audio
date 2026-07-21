import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/platform/app_icon_platform_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('syncs the selected theme mode to Android', () async {
    const channel = MethodChannel(AppIconChannel.name);
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return <String, Object?>{'ok': true, 'value': null};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await AppIconPlatformService(
      channel: channel,
      isAndroidOverride: true,
    ).syncThemeMode(ThemeMode.dark);

    expect(receivedCall?.method, AppIconMethod.syncThemeMode);
    expect(receivedCall?.arguments, <String, Object?>{'mode': 'dark'});
  });

  test('does not invoke a platform channel outside Android', () async {
    const channel = MethodChannel(AppIconChannel.name);
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invoked = true;
          return <String, Object?>{'ok': true, 'value': null};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await AppIconPlatformService(
      channel: channel,
      isAndroidOverride: false,
    ).syncThemeMode(ThemeMode.light);

    expect(invoked, isFalse);
  });
}
