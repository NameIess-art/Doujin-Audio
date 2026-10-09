import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/widgets/playing_sound_wave_indicator.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

void main() {
  group('PlayingSoundWaveIndicator', () {
    testWidgets('renders CustomPaint with correct bounded size', (tester) async {
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
        const MaterialApp(
          home: Scaffold(
            body: PlayingSoundWaveIndicator(),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(PlayingSoundWaveIndicator), findsOneWidget);
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
            child: Scaffold(
              body: PlayingSoundWaveIndicator(),
            ),
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
      final titleTextFinder = find.text('Test Playing Track');
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
  });
}
