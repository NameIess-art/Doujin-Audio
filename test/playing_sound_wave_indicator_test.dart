import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/widgets/playing_sound_wave_indicator.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

void main() {
  group('PlayingSoundWaveIndicator', () {
    testWidgets('renders CustomPaint with correct bounded size', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlayingSoundWaveIndicator(
              color: Colors.blue,
              size: 16.0,
              barWidth: 2.5,
              barSpacing: 2.0,
            ),
          ),
        ),
      );

      final indicatorFinder = find.byType(PlayingSoundWaveIndicator);
      expect(indicatorFinder, findsOneWidget);

      final customPaintFinder = find.descendant(
        of: indicatorFinder,
        matching: find.byType(CustomPaint),
      );
      expect(customPaintFinder, findsOneWidget);

      // Total width = 4 * 2.5 + 3 * 2.0 = 10.0 + 6.0 = 16.0
      final size = tester.getSize(customPaintFinder);
      expect(size.width, closeTo(16.0, 0.01));
      expect(size.height, closeTo(16.0, 0.01));
    });

    testWidgets('animates over time when isPlaying is true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: PlayingSoundWaveIndicator())),
      );

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(PlayingSoundWaveIndicator), findsOneWidget);
    });

    testWidgets('bar heights loop seamlessly and resume from the same phase', (
      tester,
    ) async {
      final tickerEnabled = ValueNotifier(true);
      addTearDown(tickerEnabled.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: tickerEnabled,
              builder: (context, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
              child: const Center(
                child: PlayingSoundWaveIndicator(
                  color: Colors.white,
                  size: 100,
                  barWidth: 8,
                  barSpacing: 5,
                ),
              ),
            ),
          ),
        ),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.descendant(
          of: find.byType(PlayingSoundWaveIndicator),
          matching: find.byType(RepaintBoundary),
        ),
      );
      Future<List<int>> barTops() async {
        final image = boundary.toImageSync();
        final width = image.width;
        final height = image.height;
        final bytes = await tester.runAsync(() => image.toByteData());
        image.dispose();
        return [
          for (var bar = 0; bar < 4; bar++)
            List.generate(height, (y) => y).firstWhere(
              (y) => bytes!.getUint8((y * width + bar * 13 + 4) * 4 + 3) > 0,
            ),
        ];
      }

      final firstFrame = await barTops();
      await tester.pump(const Duration(milliseconds: 2));
      final secondFrame = await barTops();
      for (var cycle = 0; cycle < 2; cycle++) {
        await tester.pump(const Duration(milliseconds: 21996));
        final before = await barTops();
        await tester.pump(const Duration(milliseconds: 2));
        final end = await barTops();
        expect(end, firstFrame);
        await tester.pump(const Duration(milliseconds: 2));
        final after = await barTops();
        expect(after, secondFrame);
        for (var bar = 0; bar < before.length; bar++) {
          expect((before[bar] - end[bar]).abs(), lessThanOrEqualTo(2));
          expect((end[bar] - after[bar]).abs(), lessThanOrEqualTo(2));
        }
      }
      await tester.pump(const Duration(milliseconds: 300));
      final beforePause = await barTops();
      tickerEnabled.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(await barTops(), beforePause);
      tickerEnabled.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2));
      final afterResume = await barTops();
      for (var bar = 0; bar < beforePause.length; bar++) {
        expect(
          (beforePause[bar] - afterResume[bar]).abs(),
          lessThanOrEqualTo(2),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('halts animation and stays static when isPlaying is false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlayingSoundWaveIndicator(
              isPlaying: false,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(PlayingSoundWaveIndicator), findsOneWidget);
    });

    testWidgets('dynamic isPlaying change toggles animation state', (tester) async {
      var isPlaying = true;
      late StateSetter setState;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setter) {
                setState = setter;
                return PlayingSoundWaveIndicator(
                  isPlaying: isPlaying,
                );
              },
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(PlayingSoundWaveIndicator), findsOneWidget);

      // Turn off playback
      setState(() {
        isPlaying = false;
      });
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(PlayingSoundWaveIndicator), findsOneWidget);

      // Turn playback back on
      setState(() {
        isPlaying = true;
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(PlayingSoundWaveIndicator), findsOneWidget);
    });

    testWidgets('respects disableAnimations from MediaQuery', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: PlayingSoundWaveIndicator()),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(PlayingSoundWaveIndicator), findsOneWidget);
    });

    testWidgets('shows jumping sound wave in playlist card when playing and hides when paused', (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final track = MusicTrack(
        path: PathMatcher.normalize('/library/test_track.mp3'),
        displayName: 'Test Playing Track',
        groupKey: PathMatcher.normalize('/library'),
        groupTitle: 'Album',
        groupSubtitle: '',
        isSingle: false,
      );
      fixture.runtimeGraph.library.addTracks([track], notify: false, persist: false);

      final session = fixture.runtimeGraph.playback.createTrackSession(
        track,
        loopMode: SessionLoopMode.single,
        customQueueTracks: <MusicTrack>[track],
      );
      addTearDown(session.shutdown);

      // Initially paused
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        fixture.build(const PlaylistTab()),
      );
      // Wait for skeleton fade out
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      final soundWaveFinder = find.byKey(
        ValueKey<String>('playlist_sound_wave_${session.id}'),
      );
      // Not playing -> sound wave indicator is not displayed
      expect(soundWaveFinder, findsNothing);

      // Start playback
      session.state = const PlayerState(true, ProcessingState.ready);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 1,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Now playing -> sound wave indicator is prominently displayed
      expect(soundWaveFinder, findsOneWidget);

      // Verify the title text is tinted with active color when playing
      final titleTextFinder = find.textContaining('Test Playing Track');
      expect(titleTextFinder, findsOneWidget);
      final titleText = tester.widget<Text>(titleTextFinder);
      expect(titleText.style?.color, isNotNull);

      // Pause playback
      session.state = const PlayerState(false, ProcessingState.ready);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Paused -> sound wave indicator is hidden again
      expect(soundWaveFinder, findsNothing);
    });
    for (final isQueue in [false, true]) {
      for (final textScale in [1.0, 1.8]) {
        testWidgets(
          'second title line wraps below the sound wave (queue: $isQueue, text scale: $textScale)',
          (tester) async {
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            messenger.setMockMethodCallHandler(
              notificationsChannel,
              (_) async => <String, Object?>{'ok': true, 'value': null},
            );
            addTearDown(
              () => messenger.setMockMethodCallHandler(
                notificationsChannel,
                null,
              ),
            );
            final fixture = AppRuntimeWidgetTestFixture();
            addTearDown(fixture.dispose);
            final track = MusicTrack(
              path: PathMatcher.normalize('/library/long_title.mp3'),
              displayName: List.filled(12, 'Long track name').join(' '),
              groupKey: PathMatcher.normalize('/library'),
              groupTitle: 'Album',
              groupSubtitle: '',
              isSingle: false,
            );
            fixture.runtimeGraph.library.addTracks(
              [track],
              notify: false,
              persist: false,
            );
            final session = isQueue
                ? (fixture.runtimeGraph.playback.createPlaybackQueue('Queue')
                    ..currentTrackPath = track.path
                    ..playbackQueue = PlaybackQueueDefinition(
                      name: 'Queue',
                      entries: [
                        PlaybackQueueEntry(
                          id: 'track',
                          kind: PlaybackQueueEntryKind.track,
                          title: track.displayName,
                          tracks: [track],
                        ),
                      ],
                    ))
                : fixture.runtimeGraph.playback.createTrackSession(
                    track,
                    loopMode: SessionLoopMode.single,
                    customQueueTracks: [track],
                  );
            addTearDown(session.shutdown);
            session.state = const PlayerState(true, ProcessingState.ready);
            fixture.playbackService.syncSlice(
              activeSessions: [session],
              playingSessionCount: 1,
              focusedSessionId: session.id,
              coverGeneration: 0,
              isInitialized: true,
            );
            await tester.pumpWidget(
              fixture.build(
                MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 360,
                      child: isQueue
                          ? PlaybackQueueCard(
                              session: PlaybackSessionSnapshot.fromRuntime(
                                session,
                              ),
                              library: fixture.runtimeGraph.library,
                              playback: fixture.runtimeGraph.playback,
                              coverCacheWidth: 96,
                              onOpen: () {},
                              onEdit: () {},
                            )
                          : SessionListCard(
                              sessionId: session.id,
                              track: track,
                              coverPath: null,
                              coverGeneration: 0,
                              coverCacheWidth: 96,
                              library: fixture.runtimeGraph.library,
                              playback: fixture.runtimeGraph.playback,
                              isTemporary: false,
                              onOpen: () {},
                            ),
                    ),
                  ),
                ),
              ),
            );
            final title = find.textContaining(track.displayName);
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: title, matching: find.byType(RichText)),
            );
            final titleOffset = paragraph.text.toPlainText().indexOf(
              track.displayName,
            );
            final lines = paragraph.getBoxesForSelection(
              TextSelection(
                baseOffset: titleOffset,
                extentOffset: titleOffset + track.displayName.length,
              ),
            );
            expect(lines.map((box) => box.top).toSet(), hasLength(2));
            final titleRect = tester.getRect(title);
            final waveRect = tester.getRect(
              find.byType(PlayingSoundWaveIndicator),
            );
            final firstLineHeight = titleRect.height / 2;
            expect(waveRect.top, greaterThanOrEqualTo(titleRect.top));
            expect(
              waveRect.bottom,
              lessThanOrEqualTo(titleRect.top + firstLineHeight),
            );
            expect(
              waveRect.center.dy,
              closeTo(titleRect.top + firstLineHeight / 2, 0.5),
            );
            final secondLine = lines.firstWhere(
              (box) => box.top > lines.first.top,
            );
            expect(
              titleRect.left + secondLine.left,
              closeTo(waveRect.left, 0.5),
            );
            expect(
              titleRect.left + lines.first.left,
              greaterThanOrEqualTo(waveRect.right + 5.5),
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 200));
          },
          variant: const TargetPlatformVariant({
            TargetPlatform.android,
            TargetPlatform.windows,
          }),
        );
      }
    }
  });
}
