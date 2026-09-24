import 'package:doujin_audio/app/presentation/global_shortcuts.dart';
import 'dart:async';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_persistence_repository.dart';

void main() {
  late PlaybackFacade playback;
  late NotificationFacade notifications;
  late List<String> resumed;
  late _RecordingRepository native;

  setUp(() {
    resumed = [];
    native = _RecordingRepository();
    playback = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
      nativeRepository: native,
    );
    playback.configurePersistence(enabled: false);
    notifications = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    for (final id in ['first', 'primary']) {
      playback.registerSession(
        PlaybackSession(
          id: id,
          currentTrackPath: '/$id.mp3',
          loopMode: SessionLoopMode.folderSequential,
          nonSingleLoopMode: SessionLoopMode.folderSequential,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(false, ProcessingState.ready),
        ),
      );
    }
    notifications.attachActions(
      playback: playback,
      resolveSession: ([id]) => playback.sessionById(id ?? 'primary'),
      resolveActionSession: () => playback.sessionById('primary'),
      resumeSession: (session) async {
        resumed.add(session.id);
      },
      setFocusSessionId: (_) {},
      notify: () {},
      syncKeepAlive: () {},
      hasPlaybackToKeepAlive: () => true,
      clearUnifiedNotifications: () async {},
      preferredSessionId: () => 'primary',
      notifyNotificationChanged: () {},
    );
  });

  tearDown(() async {
    await notifications.dispose();
    await playback.dispose();
  });

  Widget app(
    Widget child, {
    bool enabled = true,
    GlobalKey<NavigatorState>? navigatorKey,
    String? focusedCardSessionId,
    String? focusedDetailSessionId,
  }) => ProviderScope(
    key: ValueKey<String>(
      'scope_${focusedCardSessionId}_$focusedDetailSessionId',
    ),
    overrides: [
      playbackFacadeProvider.overrideWithValue(playback),
      notificationFacadeProvider.overrideWithValue(notifications),
      activeVisibleSessionCardIdProvider.overrideWith(
        () => _TestCardIdNotifier(focusedCardSessionId),
      ),
      activeSessionDetailIdsProvider.overrideWith(
        () => _TestDetailIdsNotifier(
          focusedDetailSessionId != null ? [focusedDetailSessionId] : const [],
        ),
      ),
    ],
    child: MaterialApp(
      navigatorKey: navigatorKey,
      builder: (context, child) => GlobalShortcuts(
        enabled: enabled,
        navigatorKey: navigatorKey,
        child: child!,
      ),
      home: Scaffold(body: child),
    ),
  );

  testWidgets(
    'Windows space only controls focused audio (detail page or card)',
    (tester) async {
      // 1. When no session is focused, space does not control playback
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(resumed, isEmpty);

      // 2. When card session is focused, space toggles that session
      await tester.pumpWidget(app(const SizedBox(), focusedCardSessionId: 'primary'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(resumed, ['primary']);

      // 3. When detail session is focused, space toggles detail session
      resumed.clear();
      await tester.pumpWidget(
        app(
          const SizedBox(),
          focusedCardSessionId: 'primary',
          focusedDetailSessionId: 'first',
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(resumed, ['first']);
      await tester.pump(const Duration(milliseconds: 200));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Windows left and right arrow keys seek 5s on focused audio only',
    (tester) async {
      playback.sessionById('primary')!
        ..duration = const Duration(seconds: 10)
        ..lastKnownPosition = const Duration(seconds: 3);

      // 1. Without focused audio, arrow keys do not seek
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 200));
      expect(native.seeks, isEmpty);

      // 2. With focused audio, plain Right arrow seeks forward 5s (3s -> 8s)
      await tester.pumpWidget(app(const SizedBox(), focusedCardSessionId: 'primary'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 200));
      expect(native.seeks, [('primary', const Duration(seconds: 8))]);

      // 3. Plain Left arrow seeks backward 5s (8s -> 3s)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 200));
      expect(native.seeks.last, ('primary', const Duration(seconds: 3)));

      // 4. Plain Left arrow again seeks backward 5s (3s -> clamped to 0s)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 200));
      expect(native.seeks.last, ('primary', Duration.zero));
      await tester.pump(const Duration(milliseconds: 200));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'text editing preserves space and Ctrl arrow shortcuts',
    (tester) async {
      await tester.pumpWidget(
        app(const TextField(autofocus: true), focusedCardSessionId: 'primary'),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(resumed, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'space activates focused button while Ctrl space controls playback',
    (tester) async {
      var activated = 0;
      await tester.pumpWidget(
        app(
          TextButton(
            autofocus: true,
            onPressed: () => activated++,
            child: const Text('Action'),
          ),
          focusedCardSessionId: 'primary',
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(activated, 1);
      expect(resumed, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(resumed, ['primary']);
      await tester.pump(const Duration(milliseconds: 200));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'disabled shortcuts leave startup keyboard events alone',
    (tester) async {
      await tester.pumpWidget(app(const SizedBox(), enabled: false));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(resumed, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Esc pops a route above home',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(app(const Text('home'), navigatorKey: navigator));
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('details')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('details'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'seek and volume shortcuts use focused session and existing bounds',
    (tester) async {
      notifications.registerSessionFocus('primary');
      playback.sessionById('primary')!
        ..duration = const Duration(seconds: 2)
        ..volume = 0.02;
      await tester.pumpWidget(app(const SizedBox(), focusedCardSessionId: 'primary'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 200));
      expect(native.seeks, [('primary', const Duration(seconds: 2))]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 200));
      expect(native.seeks.last, ('primary', Duration.zero));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(seconds: 1));
      expect(native.volumes, [('primary', 0.0)]);
      expect(playback.sessionById('first')!.volume, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'F1 help reports native query errors and closes with Esc',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final language = AppLanguageProvider();
      await language.initialized;
      addTearDown(language.dispose);
      const channel = MethodChannel('doujin_audio/windows_desktop');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
          ],
          child: app(const SizedBox(), navigatorKey: navigator),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(
        find.textContaining(language.tr('keyboard_shortcuts_status_error')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Android does not install Windows modified shortcuts',
    (tester) async {
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(resumed, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

class _TestCardIdNotifier extends ActiveVisibleSessionCardIdNotifier {
  _TestCardIdNotifier(this._initial);
  final String? _initial;
  @override
  String? build() => _initial;
}

class _TestDetailIdsNotifier extends ActiveSessionDetailIdsNotifier {
  _TestDetailIdsNotifier(this._initial);
  final List<String> _initial;
  @override
  List<String> build() => _initial;
}

class _RecordingRepository extends NativePlaybackRepository {
  final seeks = <(String, Duration)>[];
  final volumes = <(String, double)>[];

  @override
  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) async {
    seeks.add((sessionId, position));
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume, {
    bool reloadSource = true,
  }) async {
    volumes.add((sessionId, volume));
    return const NativeSuccess();
  }
}
