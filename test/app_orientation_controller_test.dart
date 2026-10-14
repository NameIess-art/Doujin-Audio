import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/presentation/app_orientation_controller.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/platform/video_display_platform_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows fullscreen uses in-window fullscreen without Android or window fullscreen calls',
    (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('doujin_audio/windows_desktop');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final controller = AppOrientationController(
        setPreferredOrientations: (value) async =>
            calls.add(MethodCall('orientation', value)),
        setSystemUiMode: (value) async =>
            calls.add(MethodCall('system_ui', value)),
      );
      await controller.updateDisplay(360);
      await controller.setPlaybackDetailVisible(true);
      final first = await controller.enterVideoFullscreen();
      final second = await controller.enterVideoFullscreen();
      expect(first.initialBrightness, isNull);
      expect(controller.isVideoFullscreen, isTrue);
      await first.release();
      expect(controller.isVideoFullscreen, isTrue);
      await second.release();
      expect(controller.isVideoFullscreen, isFalse);
      expect(calls, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  test(
    'fullscreen allows rotation and restores the current phone page on release',
    () async {
      final orientationCalls = <List<DeviceOrientation>>[];
      final uiModeCalls = <SystemUiMode>[];
      final controller = AppOrientationController(
        setPreferredOrientations: (orientations) async {
          orientationCalls.add(List<DeviceOrientation>.of(orientations));
        },
        setSystemUiMode: (mode) async => uiModeCalls.add(mode),
      );

      await controller.updateDisplay(360);
      final lease = await controller.enterVideoFullscreen();
      await controller.setPlaybackDetailVisible(true);

      expect(orientationCalls, <List<DeviceOrientation>>[
        AppOrientationPolicy.portrait.allowedOrientations,
        AppOrientationPolicy.rotatable.allowedOrientations,
      ]);
      expect(uiModeCalls, <SystemUiMode>[SystemUiMode.immersiveSticky]);

      await lease.release();

      expect(
        orientationCalls.last,
        AppOrientationPolicy.rotatable.allowedOrientations,
      );
      expect(uiModeCalls.last, SystemUiMode.edgeToEdge);
    },
  );

  test('device policy distinguishes phones, tablets and Windows', () {
    for (final side in [360.0, 599.0, 600.0, 800.0]) {
      expect(
        AppOrientationPolicy.forDisplay(
          platform: TargetPlatform.android,
          shortestSide: side,
        ),
        side < 600
            ? AppOrientationPolicy.portrait
            : AppOrientationPolicy.rotatable,
      );
      expect(
        AppOrientationPolicy.forDisplay(
          platform: TargetPlatform.android,
          shortestSide: side,
          playbackDetailVisible: true,
        ),
        AppOrientationPolicy.rotatable,
      );
      expect(
        AppOrientationPolicy.forDisplay(
          platform: TargetPlatform.windows,
          shortestSide: side,
          playbackDetailVisible: true,
        ),
        AppOrientationPolicy.landscape,
      );
    }
  });

  test(
    'phone rotation is scoped to the visible playback detail page',
    () async {
      final calls = <List<DeviceOrientation>>[];
      final controller = AppOrientationController(
        setPreferredOrientations: (value) async => calls.add(value),
      );
      await controller.updateDisplay(390);
      await controller.updateDisplay(390);
      await controller.setPlaybackDetailVisible(true);
      await controller.setPlaybackDetailVisible(true);
      await controller.setPlaybackDetailVisible(false);
      expect(calls, [
        AppOrientationPolicy.portrait.allowedOrientations,
        AppOrientationPolicy.rotatable.allowedOrientations,
        AppOrientationPolicy.portrait.allowedOrientations,
      ]);
    },
  );

  test('display class changes reapply the visible page policy', () async {
    final calls = <List<DeviceOrientation>>[];
    final controller = AppOrientationController(
      setPreferredOrientations: (value) async => calls.add(value),
    );
    await controller.updateDisplay(800);
    await controller.updateDisplay(700);
    await controller.updateDisplay(500);
    await controller.setPlaybackDetailVisible(true);
    await controller.updateDisplay(800);
    await controller.setPlaybackDetailVisible(false);
    await controller.updateDisplay(500);
    expect(calls, [
      AppOrientationPolicy.rotatable.allowedOrientations,
      AppOrientationPolicy.portrait.allowedOrientations,
      AppOrientationPolicy.rotatable.allowedOrientations,
      AppOrientationPolicy.rotatable.allowedOrientations,
      AppOrientationPolicy.rotatable.allowedOrientations,
      AppOrientationPolicy.portrait.allowedOrientations,
    ]);
  });

  test('fullscreen restores tablet policy after a display change', () async {
    final calls = <List<DeviceOrientation>>[];
    final controller = AppOrientationController(
      setPreferredOrientations: (value) async => calls.add(value),
      setSystemUiMode: (_) async {},
    );
    await controller.updateDisplay(360);
    final lease = await controller.enterVideoFullscreen();
    await controller.updateDisplay(800);
    await lease.release();
    expect(calls, [
      AppOrientationPolicy.portrait.allowedOrientations,
      AppOrientationPolicy.rotatable.allowedOrientations,
      AppOrientationPolicy.rotatable.allowedOrientations,
    ]);
  });

  test(
    'nested fullscreen leases restore only after the final release',
    () async {
      final orientationCalls = <List<DeviceOrientation>>[];
      final uiModeCalls = <SystemUiMode>[];
      final controller = AppOrientationController(
        setPreferredOrientations: (orientations) async {
          orientationCalls.add(List<DeviceOrientation>.of(orientations));
        },
        setSystemUiMode: (mode) async => uiModeCalls.add(mode),
      );

      final first = await controller.enterVideoFullscreen();
      final second = await controller.enterVideoFullscreen();
      await first.release();

      expect(controller.isVideoFullscreen, isTrue);
      expect(orientationCalls, hasLength(1));
      expect(uiModeCalls, <SystemUiMode>[SystemUiMode.immersiveSticky]);

      await second.release();
      await second.release();

      expect(controller.isVideoFullscreen, isFalse);
      expect(orientationCalls, hasLength(2));
      expect(uiModeCalls.last, SystemUiMode.edgeToEdge);
    },
  );

  test('fullscreen lease owns brightness until the final release', () async {
    final display = _RecordingVideoDisplayGateway();
    final controller = AppOrientationController(
      setPreferredOrientations: (_) async {},
      setSystemUiMode: (_) async {},
      videoDisplay: display,
    );

    final first = await controller.enterVideoFullscreen();
    final second = await controller.enterVideoFullscreen();

    expect(first.initialBrightness, 0.65);
    expect(second.initialBrightness, 0.65);
    expect(display.beginCalls, 1);
    expect(await first.setBrightness(0.8), isTrue);
    expect(display.brightnessValues, <double>[0.8]);

    await first.release();
    expect(display.endTokens, isEmpty);
    expect(await first.setBrightness(0.4), isFalse);

    await second.release();
    expect(display.endTokens, <String>['brightness-token']);
    expect(await second.setBrightness(0.4), isFalse);
  });

  test(
    'failed brightness restoration is retried before the next lease',
    () async {
      final display = _RecordingVideoDisplayGateway(endFailuresRemaining: 1);
      final controller = AppOrientationController(
        setPreferredOrientations: (_) async {},
        setSystemUiMode: (_) async {},
        videoDisplay: display,
      );

      final first = await controller.enterVideoFullscreen();
      await first.release();
      expect(display.endTokens, <String>['brightness-token']);

      final second = await controller.enterVideoFullscreen();
      expect(display.endTokens, <String>[
        'brightness-token',
        'brightness-token',
      ]);
      expect(display.beginCalls, 2);
      await second.release();
    },
  );
}

final class _RecordingVideoDisplayGateway
    implements VideoDisplayPlatformGateway {
  _RecordingVideoDisplayGateway({this.endFailuresRemaining = 0});

  int endFailuresRemaining;
  int beginCalls = 0;
  final brightnessValues = <double>[];
  final endTokens = <String>[];

  @override
  Future<NativeResult<PlatformBrightnessLease>> beginBrightnessControl() async {
    beginCalls++;
    return const NativeSuccess<PlatformBrightnessLease>(
      PlatformBrightnessLease(token: 'brightness-token', brightness: 0.65),
    );
  }

  @override
  Future<NativeResult<void>> setBrightness(
    String token,
    double brightness,
  ) async {
    expect(token, 'brightness-token');
    brightnessValues.add(brightness);
    return const NativeSuccess<void>();
  }

  @override
  Future<NativeResult<void>> endBrightnessControl(String token) async {
    endTokens.add(token);
    if (endFailuresRemaining > 0) {
      endFailuresRemaining--;
      return const NativeFailure<void>(
        'restore failed',
        code: NativeErrorCode.platformError,
      );
    }
    return const NativeSuccess<void>();
  }
}
