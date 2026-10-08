import 'dart:async';

import 'package:doujin_audio/app/application/app_runtime_lifecycle.dart';
import 'package:doujin_audio/app/application/windows_runtime_binding.dart';
import 'package:doujin_audio/core/platform/windows_desktop_service.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_persistence_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('doujin_audio/windows_desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PlaybackFacade playback;
  late NotificationFacade notifications;
  late TimerFacade timer;
  late _Runtime runtime;
  late List<String> calls;
  Completer<void>? saveGate;
  Object? saveError;
  late WindowsRuntimeBinding binding;

  setUp(() {
    calls = [];
    saveGate = null;
    saveError = null;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    playback = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
    )..configurePersistence(enabled: false);
    notifications = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    timer = TimerFacade.create(
      preferencesLoader: () async {
        calls.add('saveTimer');
        await saveGate?.future;
        if (saveError case final error?) throw error;
        return SharedPreferences.getInstance();
      },
    );
    runtime = _Runtime(calls);
    binding = WindowsRuntimeBinding(
      desktop: WindowsDesktopService(channel: channel),
    );
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
    await notifications.dispose();
    await playback.dispose();
    await timer.dispose();
  });
  Future<void> attach() async {
    await binding.attach();
    binding.bindRuntime(
      runtime: runtime,
      playback: playback,
      notifications: notifications,
      timer: timer,
    );
    await binding.initializeRuntime(() async {});
  }

  test('bootstrap failure can exit without saving default state', () async {
    await binding.attach();
    await expectLater(
      binding.initializeStartup(() async => throw StateError('startup failed')),
      throwsStateError,
    );
    await _sendAction(channel, 'play');
    await _sendAction(channel, 'exit');
    expect(calls, ['ready', 'exit']);
  });

  test('exit invalidates and drains initialization before disposing', () async {
    final initialization = Completer<void>();
    await binding.attach();
    var invalidations = 0;
    binding.bindRuntime(
      runtime: runtime,
      playback: playback,
      notifications: notifications,
      timer: timer,
      invalidateInitialization: () => invalidations++,
    );
    final attempt = binding.initializeRuntime(() => initialization.future);
    final failedAttempt = expectLater(attempt, throwsStateError);
    final exit = _sendAction(channel, 'exit');
    final repeated = _sendAction(channel, 'exit');
    await Future<void>.delayed(Duration.zero);
    expect(invalidations, 1);
    expect(calls, ['ready']);
    initialization.complete();
    await Future.wait([failedAttempt, exit, repeated]);
    expect(calls, ['ready', 'dispose', 'exit']);
  });

  test(
    'runtime failure and retry keep a single desktop registration',
    () async {
      await binding.attach();
      binding.bindRuntime(
        runtime: runtime,
        playback: playback,
        notifications: notifications,
        timer: timer,
      );
      await expectLater(
        binding.initializeRuntime(() async => throw StateError('load failed')),
        throwsStateError,
      );
      await binding.attach();
      await binding.initializeRuntime(() async {});
      await _sendAction(channel, 'exit');
      expect(calls, ['ready', 'saveTimer', 'dispose', 'exit']);
    },
  );

  test('failed runtime is disposed without persisting partial state', () async {
    await binding.attach();
    binding.bindRuntime(
      runtime: runtime,
      playback: playback,
      notifications: notifications,
      timer: timer,
    );
    await expectLater(
      binding.initializeRuntime(() async => throw StateError('load failed')),
      throwsStateError,
    );
    await _sendAction(channel, 'endSession');
    expect(calls, ['ready', 'dispose']);
  });

  test('endSession acknowledges only after saving and disposing', () async {
    saveGate = Completer<void>();
    runtime.disposeGate = Completer<void>();
    await attach();
    var acknowledged = false;
    final ended = _sendAction(channel, 'endSession').then((_) {
      acknowledged = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['ready', 'saveTimer']);
    expect(acknowledged, false);
    saveGate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['ready', 'saveTimer', 'dispose']);
    expect(acknowledged, false);
    runtime.disposeGate!.complete();
    await ended;
    expect(acknowledged, true);
    expect(calls, ['ready', 'saveTimer', 'dispose']);
  });

  test('repeated exit shares one cleanup and closes the window once', () async {
    runtime.disposeGate = Completer<void>();
    await attach();
    final first = _sendAction(channel, 'exit');
    final second = _sendAction(channel, 'exit');
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['ready', 'saveTimer', 'dispose']);
    runtime.disposeGate!.complete();
    await Future.wait([first, second]);
    expect(calls, ['ready', 'saveTimer', 'dispose', 'exit']);
  });

  test(
    'endSession waits for an ongoing exit and suppresses window close',
    () async {
      runtime.disposeGate = Completer<void>();
      await attach();
      final first = _sendAction(channel, 'exit');
      await Future<void>.delayed(Duration.zero);
      var acknowledged = false;
      final second = _sendAction(channel, 'endSession').then((_) {
        acknowledged = true;
      });
      final repeated = _sendAction(channel, 'endSession');
      await Future<void>.delayed(Duration.zero);
      expect(acknowledged, false);
      runtime.disposeGate!.complete();
      await Future.wait([first, second, repeated]);
      expect(calls, ['ready', 'saveTimer', 'dispose']);
    },
  );

  test('cleanup failure replies without repeating disposal', () async {
    runtime.disposeError = StateError('cleanup failed');
    await attach();
    await expectLater(
      _sendAction(channel, 'endSession'),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, ['ready', 'saveTimer', 'dispose']);
    runtime.disposeError = null;
    await expectLater(
      _sendAction(channel, 'endSession'),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, ['ready', 'saveTimer', 'dispose']);
  });

  test(
    'timer save failure still releases runtime and permits tray exit',
    () async {
      await attach();
      saveError = StateError('disk full');
      await _sendAction(channel, 'exit');
      expect(calls, ['ready', 'saveTimer', 'dispose', 'exit']);
    },
  );
}

Future<void> _sendAction(MethodChannel channel, String action) {
  final reply = Completer<void>();
  const codec = StandardMethodCodec();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall('action', action)),
        (data) {
          try {
            codec.decodeEnvelope(data!);
            reply.complete();
          } catch (error, stackTrace) {
            reply.completeError(error, stackTrace);
          }
        },
      );
  return reply.future;
}

final class _Runtime implements AppRuntimeLifecycle {
  _Runtime(this.calls);
  final List<String> calls;
  Completer<void>? disposeGate;
  Object? disposeError;
  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await disposeGate?.future;
    if (disposeError case final error?) throw error;
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> enterBackground() async {}
  @override
  Future<void> resumeForeground() async {}
  @override
  Future<void> handleMemoryPressure() async {}
}
