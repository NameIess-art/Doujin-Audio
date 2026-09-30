import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/platform/subtitle_overlay_platform_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_overlay_controller.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('overlay permission is only requested on Android', () {
    expect(shouldRequestSubtitleOverlayPermission(isAndroid: true), isTrue);
    expect(shouldRequestSubtitleOverlayPermission(isAndroid: false), isFalse);
  });

  test('detached runtime ignores a late overlay permission result', () async {
    const channel = MethodChannel('test.subtitle.overlay.runtime-race');
    final entered = Completer<void>();
    final release = Completer<void>();
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'canDrawOverlays') {
        entered.complete();
        await release.future;
      }
      return <String, Object?>{'ok': true, 'value': true};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final controller = SubtitleOverlayController(
      platform: SubtitleOverlayPlatformService(channel: channel),
    );
    addTearDown(controller.dispose);
    controller.attachRuntime(
      enabled: () => true,
      session: () => _OverlaySession(),
      subtitles: () =>
          throw StateError('Detached runtime must not load subtitles'),
      style: () => (
        fontSize: null,
        backgroundColor: null,
        textColor: null,
        backgroundOpacity: null,
        fontFamily: null,
        borderDepth: null,
      ),
    );
    controller.requestRuntimeSync();
    await entered.future;
    await controller.detachRuntime();
    release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isNot(contains('startOverlay')));
    expect(calls, isNot(contains('updateStyle')));
    expect(calls, contains('stopOverlay'));
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

class _OverlaySession implements PlaybackSession {
  @override
  String get id => 'session';
  @override
  String get currentTrackPath => '/music/track.mp3';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
