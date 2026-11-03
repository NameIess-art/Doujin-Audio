import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
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
      expect(clear.center.dx - pause.center.dx, 48);
      expect(add.center.dx - clear.center.dx, 48);

      final quickMenuTrigger = find.ancestor(
        of: find.byTooltip(fixture.languageProvider.tr('timer')),
        matching: find.byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.onLongPress != null,
        ),
      );
      expect(quickMenuTrigger, findsOneWidget);
      tester.widget<GestureDetector>(quickMenuTrigger).onLongPress!();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text(fixture.languageProvider.tr('stop_after_current_track')),
        findsNothing,
      );
      final setCountdown = tester.widget<ActionChip>(
        find.widgetWithText(
          ActionChip,
          fixture.languageProvider.tr('set_countdown'),
        ),
      );
      setCountdown.onPressed!();
      await tester.pump();

      expect(openedTimerSettings, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(openedTimerSettings, 0);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(openedTimerSettings, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quick menu shows stop_after_current_track when timer is active',
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
      tester.widget<TimerCountdownCapsule>(quickMenuTrigger).onLongPress!();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text(fixture.languageProvider.tr('stop_after_current_track')),
        findsOneWidget,
      );
      fixture.timer.cancelTimer();
      await tester.pump();
    },
  );
}

final class _PlaylistTransportRepository extends NativePlaybackRepository {
  @override
  Future<NativeResult<void>> pauseAll() async => const NativeSuccess<void>();

  @override
  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() async =>
      const NativeFailure('snapshot unavailable after native pause');
}
