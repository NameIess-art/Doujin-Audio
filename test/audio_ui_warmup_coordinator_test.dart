import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/audio_ui_warmup_coordinator.dart';
import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/warmup_scheduler.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

class _RecordingSubtitles extends PlaybackSubtitleService {
  _RecordingSubtitles() : super(trackResolver: (_) => null);

  final List<String> loads = [];

  @override
  Future<SubtitleTrack?> load(String trackPath) async {
    loads.add(trackPath);
    return null;
  }
}

PlaybackSession _addPlayingSession(AppRuntimeWidgetTestFixture fixture) {
  final session = PlaybackSession(
    id: 'warmup_session',
    currentTrackPath: 'content://test/first.mp3',
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.single,
    volume: 1,
    createdAt: DateTime(2026),
    state: const PlayerState(true, ProcessingState.ready),
  );
  fixture.playbackService.registerSession(session);
  fixture.playbackService.syncSlice(
    activeSessions: [session],
    playingSessionCount: 1,
    focusedSessionId: session.id,
    coverGeneration: 0,
    isInitialized: true,
  );
  addTearDown(session.shutdown);
  return session;
}

void main() {
  AppRuntimeTestFixture.initialize();

  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final showLocal in [true, false]) {
      for (final showAsmr in [true, false]) {
        testWidgets(
          '${platform.name} warms playback after animation and idle with '
          'local=$showLocal asmr=$showAsmr',
          (tester) async {
            debugDefaultTargetPlatformOverride = platform;
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(1280, 800);
            addTearDown(() {
              debugDefaultTargetPlatformOverride = null;
              tester.view.resetDevicePixelRatio();
              tester.view.resetPhysicalSize();
            });
            final fixture = AppRuntimeWidgetTestFixture(
              configureSettingsRepository: (settings) {
                settings.showLocalLibrary = showLocal;
                settings.showAsmrOne = showAsmr;
                settings.startupPage = StartupPage.playlist;
                settings.syncSlice(isInitialized: true);
              },
            );
            addTearDown(fixture.dispose);
            fixture.libraryService.syncSlice(
              isInitialized: true,
              detailRevision: 0,
            );
            final session = _addPlayingSession(fixture);
            final subtitles = _RecordingSubtitles();
            addTearDown(subtitles.dispose);
            final scheduler = WarmupScheduler();
            final warmup = AudioUiWarmupCoordinator(
              library: fixture.library,
              playback: fixture.playback,
              notifications: fixture.notifications,
              subtitles: subtitles,
              scheduler: scheduler,
            );
            addTearDown(warmup.shutdown);
            final app =
                fixture.build(const MainScreen(), subtitleService: subtitles)
                    as ProviderScope;
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  ...app.overrides.where(
                    (override) =>
                        override.origin != audioUiWarmupCoordinatorProvider,
                  ),
                  audioUiWarmupCoordinatorProvider.overrideWithValue(warmup),
                ],
                child: app.child,
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            await tester.pump();
            subtitles.loads.clear();
            final destinations = resolveMainDestinations(
              showLocalLibrary: showLocal,
              showAsmrOne: showAsmr,
            );
            void select(MainDestinationType type) {
              tester
                  .widget<NavigationRail>(find.byType(NavigationRail))
                  .onDestinationSelected!(
                destinations.indexWhere((item) => item.type == type),
              );
            }

            select(MainDestinationType.settings);
            await tester.pump();
            await tester.pump(kAppMotionSlow);
            await tester.pump(kAppMotionSlow);
            await tester.pump(const Duration(milliseconds: 200));
            expect(subtitles.loads, isEmpty);

            select(MainDestinationType.playlist);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
            expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
            expect(scheduler.isPaused, isTrue);
            expect(subtitles.loads, isEmpty);
            await tester.pump(kAppMotionSlow);
            await tester.pump(const Duration(milliseconds: 100));
            expect(subtitles.loads, isEmpty);
            await tester.pump(const Duration(milliseconds: 80));
            await tester.pump();
            expect(subtitles.loads, [session.currentTrackPath]);
            expect(UiInteractionCoordinator.instance.isInteracting, isFalse);

            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 1));
            debugDefaultTargetPlatformOverride = null;
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('interaction pause retains only the latest warmup request', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final session = _addPlayingSession(fixture);
    final subtitles = _RecordingSubtitles();
    addTearDown(subtitles.dispose);
    final scheduler = WarmupScheduler();
    final warmup = AudioUiWarmupCoordinator(
      library: fixture.library,
      playback: fixture.playback,
      notifications: fixture.notifications,
      subtitles: subtitles,
      scheduler: scheduler,
    );
    addTearDown(warmup.shutdown);

    warmup.setInteractionPaused(true);
    warmup.schedule(isPlaybackPage: true, immediate: true);
    session.currentTrackPath = 'content://test/latest.mp3';
    warmup.schedule(isPlaybackPage: true, immediate: true);
    await tester.pump(const Duration(seconds: 1));
    expect(subtitles.loads, isEmpty);
    expect(scheduler.pendingCount, 2);
    warmup.setInteractionPaused(false);
    await tester.pump();
    expect(subtitles.loads, [session.currentTrackPath]);

    subtitles.loads.clear();
    warmup.setInteractionPaused(true);
    warmup.schedule(isPlaybackPage: true, immediate: true);
    warmup.schedule(immediate: true);
    warmup.setInteractionPaused(false);
    await tester.pump();
    expect(scheduler.pendingCount, 0);
    expect(subtitles.loads, isEmpty);
  });
}
