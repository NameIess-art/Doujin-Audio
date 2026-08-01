import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/platform/subtitle_overlay_platform_service.dart';
import 'package:nameless_audio/features/player/application/subtitle_overlay_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('overlay permission is only requested on Android', () {
    expect(shouldRequestSubtitleOverlayPermission(isAndroid: true), isTrue);
    expect(shouldRequestSubtitleOverlayPermission(isAndroid: false), isFalse);
  });

  test(
    'delayed stop is cancellable and uses the injected platform gateway',
    () async {
      const channel = MethodChannel('test.subtitle.overlay');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return <String, Object?>{'ok': true, 'value': true};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      void Function()? delayedStop;
      final controller = SubtitleOverlayController(
        platform: SubtitleOverlayPlatformService(channel: channel),
        stopTimerFactory: (duration, callback) {
          final timer = _TestTimer(callback);
          delayedStop = timer.fire;
          return timer;
        },
      );
      addTearDown(controller.dispose);

      expect(await controller.canDrawOverlays(), isTrue);
      await controller.stopOverlay();
      expect(delayedStop, isNotNull);
      expect(await controller.startOverlay(), isTrue);
      delayedStop!();
      await Future<void>.delayed(Duration.zero);

      expect(
        calls.map((call) => call.method),
        containsAllInOrder(<String>['canDrawOverlays', 'startOverlay']),
      );
      expect(calls.where((call) => call.method == 'stopOverlay'), isEmpty);
    },
  );

  test(
    'a stop requested during start prevents a stale overlay restart',
    () async {
      const channel = MethodChannel('test.subtitle.overlay.start-race');
      final startEntered = Completer<void>();
      final releaseStart = Completer<void>();
      var stopCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'startOverlay') {
              startEntered.complete();
              await releaseStart.future;
            } else if (call.method == 'stopOverlay') {
              stopCalls++;
            }
            return <String, Object?>{'ok': true, 'value': true};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final controller = SubtitleOverlayController(
        platform: SubtitleOverlayPlatformService(channel: channel),
      );
      addTearDown(controller.dispose);

      final start = controller.startOverlay();
      await startEntered.future;
      await controller.stopOverlay(immediate: true);
      releaseStart.complete();

      expect(await start, isFalse);
      expect(stopCalls, 2);
    },
  );
}

final class _TestTimer implements Timer {
  _TestTimer(this._callback);

  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() {
    _active = false;
  }
}
