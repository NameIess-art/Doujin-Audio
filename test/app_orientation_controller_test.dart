import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/presentation/app_orientation_controller.dart';

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
}
