import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/presentation/app_orientation_controller.dart';
import 'package:nameless_audio/core/errors/native_result.dart';
import 'package:nameless_audio/core/platform/video_display_platform_service.dart';

void main() {
  test(
    'fullscreen overrides portrait lock and restores it on release',
    () async {
      final orientationCalls = <List<DeviceOrientation>>[];
      final uiModeCalls = <SystemUiMode>[];
      final controller = AppOrientationController(
        setPreferredOrientations: (orientations) async {
          orientationCalls.add(List<DeviceOrientation>.of(orientations));
        },
        setSystemUiMode: (mode) async => uiModeCalls.add(mode),
      );

      await controller.setPortraitLockEnabled(true);
      final lease = await controller.enterVideoFullscreen();
      await controller.setPortraitLockEnabled(false);

      expect(orientationCalls, <List<DeviceOrientation>>[
        AppOrientationPolicy.portrait.allowedOrientations,
        AppOrientationPolicy.videoFullscreen.allowedOrientations,
      ]);
      expect(uiModeCalls, <SystemUiMode>[SystemUiMode.immersiveSticky]);

      await lease.release();

      expect(
        orientationCalls.last,
        AppOrientationPolicy.current.allowedOrientations,
      );
      expect(uiModeCalls.last, SystemUiMode.edgeToEdge);
    },
  );

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
