import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/core/platform/subtitle_overlay_platform_service.dart';
import 'package:doujin_audio/core/platform/update_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdatePlatformService', () {
    const channel = MethodChannel('test/update_platform');
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('decodes version and install results', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return _success(switch (call.method) {
              UpdateMethod.getAppVersion => <String, Object?>{
                'versionName': '1.2.3',
                'buildNumber': 45,
                'androidAssetVariant': 'arm64',
              },
              UpdateMethod.installApk => <String, Object?>{
                'ok': false,
                'needsPermission': true,
                'message': 'permission_required',
              },
              _ => true,
            });
          });
      final service = UpdatePlatformService(channel: channel);

      final version = (await service.getAppVersion()).valueOrNull;
      final install = (await service.installApk('/tmp/update.apk')).valueOrNull;

      expect(version?.versionName, '1.2.3');
      expect(version?.buildNumber, 45);
      expect(version?.androidAssetVariant, 'arm64');
      expect(install?.ok, isFalse);
      expect(install?.needsPermission, isTrue);
      expect(install?.message, 'permission_required');
      expect(calls.last.arguments, <String, Object?>{
        'path': '/tmp/update.apk',
      });
    });

    test(
      'uses typed methods and preserves malformed envelope failures',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == UpdateMethod.openReleasePage) {
                return <String, Object?>{'value': true};
              }
              return _success(true);
            });
        final service = UpdatePlatformService(channel: channel);

        expect((await service.canInstallUnknownApps()).valueOrNull, isTrue);
        expect(
          await service.openReleasePage('https://example.com/release'),
          isA<NativeFailure<bool>>(),
        );
        expect(calls.map((call) => call.method), <String>[
          UpdateMethod.canInstallUnknownApps,
          UpdateMethod.openReleasePage,
        ]);
        expect(calls.last.arguments, <String, Object?>{
          'url': 'https://example.com/release',
        });
      },
    );
  });

  group('SubtitleOverlayPlatformService', () {
    const channel = MethodChannel('test/subtitle_overlay_platform');
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('sends subtitle and style payloads through the gateway', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return _success(
              call.method == SubtitleOverlayMethod.canDrawOverlays,
            );
          });
      final service = SubtitleOverlayPlatformService(channel: channel);

      expect(await service.canDrawOverlays(), isTrue);
      await service.updateSubtitle('line');
      await service.updateStyle(<String, Object?>{'fontSize': 18.0});

      expect(calls.map((call) => call.method), <String>[
        SubtitleOverlayMethod.canDrawOverlays,
        SubtitleOverlayMethod.updateSubtitle,
        SubtitleOverlayMethod.updateStyle,
      ]);
      expect(calls[1].arguments, <String, Object?>{'text': 'line'});
      expect(calls[2].arguments, <String, Object?>{'fontSize': 18.0});
    });

    test(
      'returns safe values and does not throw on platform failures',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw PlatformException(code: 'unavailable');
            });
        final service = SubtitleOverlayPlatformService(channel: channel);

        expect(await service.openOverlaySettings(), isFalse);
        await service.startOverlay();
        await service.stopOverlay();
      },
    );
  });
}

Map<String, Object?> _success(Object? value) => <String, Object?>{
  'ok': true,
  'value': value,
};
