import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/subtitle_overlay_platform_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_overlay_controller.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'paused overlay has no polling and follows only its target stream',
    (tester) async {
      const channel = MethodChannel('test.subtitle.overlay.events');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return <String, Object?>{'ok': true, 'value': true};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final first = _OverlaySession(id: 'a', path: '/music/a.mp3');
      final second = _OverlaySession(id: 'b', path: '/music/b.mp3');
      addTearDown(first.positions.close);
      addTearDown(second.positions.close);
      final subtitles = _CountingSubtitles();
      addTearDown(subtitles.dispose);
      final controller = SubtitleOverlayController(
        platform: SubtitleOverlayPlatformService(channel: channel),
      );
      addTearDown(controller.dispose);
      var selected = first;
      controller.attachRuntime(
        enabled: () => true,
        session: () => selected,
        subtitles: () => subtitles,
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
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(first.positions.hasListener, isTrue);
      expect(second.positions.hasListener, isFalse);
      final textReads = subtitles.textReads;
      final platformCalls = calls.length;
      await tester.pump(const Duration(seconds: 60));
      expect(subtitles.textReads, textReads);
      expect(calls.length, platformCalls);

      first.emit(const Duration(seconds: 2));
      await tester.pump();
      expect(calls.last.arguments, {'text': 'a:next'});
      selected = second;
      controller.requestRuntimeSync();
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(first.positions.hasListener, isFalse);
      expect(second.positions.hasListener, isTrue);
      final switchedCalls = calls.length;
      first.emit(const Duration(seconds: 3));
      await tester.pump();
      expect(calls.length, switchedCalls);
      second.emit(const Duration(seconds: 2));
      await tester.pump();
      expect(calls.last.arguments, {'text': 'b:next'});

      await tester.runAsync(controller.detachRuntime);
      expect(second.positions.hasListener, isFalse);
      final stoppedCalls = calls.length;
      second.emit(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 60));
      expect(calls.length, stoppedCalls);
    },
  );

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
  _OverlaySession({this.id = 'session', String path = '/music/track.mp3'})
    : currentTrackPath = path;

  @override
  final String id;
  @override
  final String currentTrackPath;
  final positions = StreamController<Duration>.broadcast(sync: true);
  @override
  Duration position = Duration.zero;
  @override
  Stream<Duration> get positionStream => positions.stream;

  void emit(Duration value) {
    position = value;
    positions.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingSubtitles extends PlaybackSubtitleService {
  _CountingSubtitles() : super(trackResolver: (_) => null);

  int textReads = 0;
  @override
  bool hasResult(String trackPath) => true;
  @override
  SubtitleTrack trackSync(String trackPath) =>
      SubtitleTrack(sourcePath: '$trackPath.lrc', cues: const []);
  @override
  Future<SubtitleTrack?> load(String trackPath) async => trackSync(trackPath);
  @override
  String textAt(
    String trackPath,
    Duration position, {
    SubtitleTrack? subtitleTrack,
    bool persistent = false,
  }) {
    textReads++;
    final name = trackPath.contains('/a.') ? 'a' : 'b';
    return '$name:${position.inSeconds >= 2 ? 'next' : 'first'}';
  }
}
