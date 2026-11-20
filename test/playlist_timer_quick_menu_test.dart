import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/widgets/app_dialog.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/test_playback_commands.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  testWidgets('header pauses and resumes the last playback batch', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = AppRuntimeWidgetTestFixture(
      providedNativePlaybackRepository: _PlaylistTransportRepository(),
    );
    addTearDown(fixture.dispose);
    final playback = fixture.playback;
    final session =
        playback.createTrackSession(
          MusicTrack(
            path: '/tracks/resume.mp3',
            displayName: 'Resume',
            groupKey: '/tracks',
            groupTitle: 'Tracks',
            groupSubtitle: '',
            isSingle: true,
          ),
        )..setOptimisticState(
          playing: true,
          processingState: ProcessingState.ready,
        );
    playback.publishSessionState(session.id);
    playback.detachCommandPort();
    playback.attachPlaybackCommands(
      prepareSession:
          (
            session, {
            required nextPath,
            autoPlay = true,
            forceStartAtZero = false,
            showLoading = true,
            targetQueueIndex,
          }) async {
            session.setOptimisticState(
              playing: true,
              processingState: ProcessingState.ready,
            );
            playback.publishSessionState(session.id);
            return true;
          },
      pauseSession: (_) async {},
      startSession: (_, {required shouldStartTriggerCountdown}) async => false,
      resolveAdvance: (_, {required forward}) => null,
      hasAdjacent: (_, {required forward}) => false,
    );

    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pumpAndSettle();
    final pause = find.byKey(const ValueKey('playlist_pause_all_button'));
    final resume = find.byKey(const ValueKey('playlist_resume_last_button'));
    expect(pause, findsOneWidget);

    await tester.tap(pause);
    await tester.pumpAndSettle();
    expect(resume, findsOneWidget);
    expect(tester.widget<IconButton>(resume).onPressed, isNotNull);

    await tester.tap(resume);
    await tester.pumpAndSettle();
    expect(session.state.playing, isTrue);
    expect(pause, findsOneWidget);
  });

  testWidgets(
    'opening timer settings waits for the quick menu to finish closing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      var openedTimerSettings = 0;

      await tester.pumpWidget(
        fixture.build(PlaylistTab(onTimerTap: () => openedTimerSettings++)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final resume = find.byKey(const ValueKey('playlist_resume_last_button'));
      expect(tester.widget<IconButton>(resume).onPressed, isNull);
      expect(
        tester.widget<IconButton>(resume).tooltip,
        fixture.languageProvider.tr('resume_last_playback'),
      );
      final pause = tester.getRect(resume);
      final clear = tester.getRect(
        find.byKey(const ValueKey('playlist_clear_all_button')),
      );
      final add = tester.getRect(
        find.byKey(const ValueKey('playlist_add_queue_button')),
      );
      final timer = tester.getSize(
        find.byTooltip(fixture.languageProvider.tr('timer')),
      );
      final pillButton = HeaderActionPill.buttonConstraints.smallest;
      expect(pillButton.height, timer.height);
      expect(pause.size, pillButton);
      expect(clear.size, pillButton);
      expect(add.size, pillButton);
      expect(clear.center.dx - pause.center.dx, pillButton.width);
      expect(add.center.dx - clear.center.dx, pillButton.width);

      final i18n = fixture.languageProvider;
      await tester.longPress(
        find.byTooltip(i18n.tr('timer')),
        kind: defaultTargetPlatform == TargetPlatform.windows
            ? PointerDeviceKind.mouse
            : PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppModalBackground), findsOneWidget);
      expect(find.text(i18n.tr('stop_after_current_track')), findsNothing);
      expect(find.text(i18n.tr('cancel_timer')), findsNothing);
      var previousY = 0.0;
      for (final count in [15, 30, 60]) {
        final y = tester
            .getCenter(find.text(i18n.tr('minutes_duration', {'count': count})))
            .dy;
        expect(y, greaterThan(previousY));
        previousY = y;
      }
      final setCountdown = find.text(i18n.tr('set_countdown'));
      expect(tester.getCenter(setCountdown).dy, greaterThan(previousY));
      await tester.tap(setCountdown);
      await tester.pump();

      expect(openedTimerSettings, 0);
      await tester.pump(const Duration(milliseconds: 199));
      expect(openedTimerSettings, 0);

      await tester.pumpAndSettle();
      expect(find.byType(AppModalBackground), findsNothing);
      expect(openedTimerSettings, 1);
      await tester.tap(find.byTooltip(i18n.tr('timer')));
      expect(openedTimerSettings, 2);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'active timer menu toggles track-end stop, starts a preset and cancels',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      fixture.timer.configureTimer(
        TimerMode.manual,
        const Duration(minutes: 15),
      );
      fixture.timer.startCountdown();

      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final quickMenuTrigger = find.byType(TimerCountdownCapsule);
      expect(quickMenuTrigger, findsOneWidget);
      Future<void> openMenu() async {
        if (defaultTargetPlatform == TargetPlatform.windows) {
          await tester.tap(
            quickMenuTrigger,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
        } else {
          await tester.longPress(quickMenuTrigger);
        }
        await tester.pumpAndSettle();
      }

      final i18n = fixture.languageProvider;
      final stopAfterTrack = find.text(i18n.tr('stop_after_current_track'));
      await openMenu();
      expect(stopAfterTrack, findsOneWidget);
      await tester.tap(stopAfterTrack);
      await tester.pumpAndSettle();
      expect(fixture.timer.stopAfterCurrentTrack, isTrue);

      await openMenu();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.tap(find.text(i18n.tr('minutes_duration', {'count': 30})));
      await tester.pumpAndSettle();
      expect(fixture.timer.state.active, isTrue);
      expect(fixture.timer.state.duration, const Duration(minutes: 30));

      await openMenu();
      await tester.tap(find.text(i18n.tr('cancel_timer')));
      await tester.pumpAndSettle();
      expect(fixture.timer.state.active, isFalse);
      expect(fixture.timer.state.duration, isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}

final class _PlaylistTransportRepository extends NativePlaybackRepository {
  @override
  Future<NativeResult<void>> pauseAll() async => const NativeSuccess<void>();

  @override
  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() async =>
      const NativeFailure('snapshot unavailable after native pause');
}
