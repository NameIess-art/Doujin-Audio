import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

PlaybackSessionSnapshot _createTestSnapshot({
  required String id,
  required String trackPath,
  Duration position = Duration.zero,
  Duration duration = const Duration(minutes: 2),
  Stream<PlaybackPositionSample>? progressStream,
  int? queueColorValue,
}) {
  return PlaybackSessionSnapshot(
    id: id,
    createdAt: DateTime(2026),
    lastPlayedAt: null,
    currentTrackPath: trackPath,
    loadedPath: trackPath,
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.crossSequential,
    volume: 1,
    channelSwapEnabled: false,
    position: position,
    duration: duration,
    bufferedPosition: Duration.zero,
    speed: 1,
    audioEffects: AudioEffectsState.flat,
    eqCapabilities: EqCapabilities.unsupported,
    state: const PlaybackStatus(
      playing: true,
      processing: PlaybackProcessingStatus.ready,
    ),
    effectivePlaying: true,
    playbackRequested: true,
    isLoading: false,
    isPlaybackLoading: false,
    playbackError: null,
    currentQueueIndex: 0,
    playbackQueue: queueColorValue != null
        ? PlaybackQueueDefinition(
            name: 'Queue $id',
            colorValue: queueColorValue,
            entries: const [],
          )
        : null,
    customQueueTracks: null,
    positionStream: const Stream.empty(),
    durationStream: const Stream.empty(),
    progressStream: progressStream ?? const Stream.empty(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('coverProgressInnerDimension', () {
    test('computes inner dimension correctly', () {
      expect(coverProgressInnerDimension(52), 47.0);
      expect(coverProgressInnerDimension(48), 43.0);
      expect(coverProgressInnerDimension(56), 51.0);
    });

    test('clamps to zero when outer dimension is smaller than insets', () {
      expect(coverProgressInnerDimension(4), 0.0);
    });
  });

  group('SessionCoverProgressRing', () {
    testWidgets('renders child in center and paints progress ring', (tester) async {
      final snapshot = _createTestSnapshot(
        id: 's1',
        trackPath: '/test/track.mp3',
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 60),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SessionCoverProgressRing(
                session: snapshot,
                size: 52,
                activeColor: Colors.amber,
                child: const SizedBox(key: ValueKey('test_cover_child')),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SessionCoverProgressRing), findsOneWidget);
      expect(find.byKey(const ValueKey('test_cover_child')), findsOneWidget);

      final customPaintFinder = find.descendant(
        of: find.byType(SessionCoverProgressRing),
        matching: find.byType(CustomPaint),
      );
      expect(customPaintFinder, findsOneWidget);
    });

    testWidgets('updates progress arc on stream position ticks', (tester) async {
      final posController = StreamController<PlaybackPositionSample>.broadcast();
      addTearDown(posController.close);

      final snapshot = _createTestSnapshot(
        id: 's2',
        trackPath: '/test/track2.mp3',
        duration: const Duration(seconds: 100),
        progressStream: posController.stream,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SessionCoverProgressRing(
                session: snapshot,
                size: 52,
                child: const SizedBox(),
              ),
            ),
          ),
        ),
      );

      final ring = find.byType(SessionCoverProgressRing);
      final paint = find.descendant(of: ring, matching: find.byType(CustomPaint));
      final original = tester.widget<CustomPaint>(paint);
      posController.add(const PlaybackPositionSample(
        position: Duration(seconds: 50),
        duration: Duration(seconds: 100),
        bufferedPosition: Duration.zero,
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.widget<CustomPaint>(paint), same(original));
      expect(paint, paints..arc(sweepAngle: math.pi));
    });
  });

  group('ActiveSessionCarousel without legacy progress strip', () {
    testWidgets('shows progress ring around cover and has no legacy progress strip', (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final track = MusicTrack(
        path: '/music/track.mp3',
        displayName: 'Test Track',
        groupKey: 'test_group',
        groupTitle: 'Test Album',
        groupSubtitle: 'Test Artist',
        isSingle: false,
        duration: const Duration(minutes: 1),
      );

      fixture.runtimeGraph.library.addTracks([track], persist: false);

      final runtimeSession = PlaybackSession(
        id: 'carousel_session',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      )..setOptimisticPosition(const Duration(seconds: 15));

      fixture.playbackService.registerSession(runtimeSession);
      fixture.playbackService.syncSlice(
        activeSessions: [runtimeSession],
        playingSessionCount: 0,
        focusedSessionId: runtimeSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      final session = PlaybackSessionSnapshot.fromRuntime(runtimeSession);

      await tester.pumpWidget(
        fixture.build(
          ActiveSessionCarousel(
            sessions: [session],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Confirm SessionCoverProgressRing is in the carousel
      expect(find.byType(SessionCoverProgressRing), findsWidgets);

      // Confirm the cover artwork key is preserved
      final coverFinder = find.byKey(
        const ValueKey('active_session_cover_carousel_session'),
      );
      expect(coverFinder, findsWidgets);

      // When isPlaybackRaised is false (default), cover is 1:1 circle
      final defaultCoverSize = tester.getSize(coverFinder.first);
      expect(defaultCoverSize.width, defaultCoverSize.height);

      // Check card ClipRRect when embedded and raised
      await tester.pumpWidget(
        fixture.build(
          ActiveSessionCarousel(
            sessions: [session],
            presentation: ActiveSessionCarouselPresentation.embedded,
            isPlaybackRaised: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final raisedCoverFinder = find.byKey(
        const ValueKey('active_session_cover_carousel_session'),
      );
      final raisedCoverSize = tester.getSize(raisedCoverFinder.first);
      // Cover is unified to circular (width == height)
      expect(raisedCoverSize.width, raisedCoverSize.height);

      final cardClipFinder = find.byKey(
        const ValueKey('active_session_card_carousel_session'),
      );
      expect(cardClipFinder, findsWidgets);
      final cardClip = tester.widget<ClipRRect>(cardClipFinder.first);
      final border = cardClip.borderRadius as BorderRadius;
      expect(border.topLeft.x, LibraryLikeCardMetrics.cardRadius);
      expect(border.bottomLeft.x, LibraryLikeCardMetrics.cardRadius);
      expect(border.topRight.x, 28.0);
      expect(border.bottomRight.x, 28.0);

      // Verify the right-side text column height is strictly less than the cover height
      final titleBoxFinder = find.byKey(
        const ValueKey('active_session_title_overflow_box'),
      );
      if (titleBoxFinder.evaluate().isNotEmpty) {
        final titleBoxSize = tester.getSize(titleBoxFinder);
        expect(titleBoxSize.height, lessThan(raisedCoverSize.height));
      }
    });
  });

  group('Playlist item cards have progress ring around covers', () {
    testWidgets('SessionListCard wraps cover with SessionCoverProgressRing', (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final track = MusicTrack(
        path: '/lib/track.mp3',
        displayName: 'Test Track',
        groupKey: 'test_group',
        groupTitle: 'Test Album',
        groupSubtitle: 'Test Artist',
        isSingle: false,
        duration: const Duration(minutes: 3),
      );

      fixture.runtimeGraph.library.addTracks([track], persist: false);

      final runtimeSession = PlaybackSession(
        id: 'card_session',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      )..setOptimisticPosition(const Duration(minutes: 1));

      fixture.playbackService.registerSession(runtimeSession);
      fixture.playbackService.syncSlice(
        activeSessions: [runtimeSession],
        playingSessionCount: 0,
        focusedSessionId: runtimeSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      final session = PlaybackSessionSnapshot.fromRuntime(runtimeSession);

      await tester.pumpWidget(
        fixture.build(
          SessionListCard(
            sessionId: session.id,
            session: session,
            track: track,
            coverCacheWidth: 64,
            library: fixture.runtimeGraph.library,
            playback: fixture.runtimeGraph.playback,
            isTemporary: false,
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SessionCoverProgressRing), findsOneWidget);
      expect(find.byKey(const ValueKey('playlist_cover_card_session')), findsOneWidget);
    });

    testWidgets('PlaybackQueueCard wraps mosaic cover with SessionCoverProgressRing', (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final track = MusicTrack(
        path: '/music/queue_track.mp3',
        displayName: 'Queue Track',
        groupKey: 'queue_group',
        groupTitle: 'Queue Album',
        groupSubtitle: 'Queue Artist',
        isSingle: false,
        duration: const Duration(minutes: 2),
      );

      fixture.runtimeGraph.library.addTracks([track], persist: false);

      final queueDefinition = PlaybackQueueDefinition(
        name: 'Test Queue',
        colorValue: 0xFF2196F3,
        entries: [
          PlaybackQueueEntry(
            id: 'entry-0',
            kind: PlaybackQueueEntryKind.track,
            title: track.displayName,
            tracks: [track],
          ),
        ],
      );

      final runtimeSession = PlaybackSession(
        id: 'queue_session',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        playbackQueue: queueDefinition,
        customQueueTracks: [track],
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      )..setOptimisticPosition(const Duration(seconds: 45));

      fixture.playbackService.registerSession(runtimeSession);
      fixture.playbackService.syncSlice(
        activeSessions: [runtimeSession],
        playingSessionCount: 0,
        focusedSessionId: runtimeSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      final session = PlaybackSessionSnapshot.fromRuntime(runtimeSession);

      await tester.pumpWidget(
        fixture.build(
          PlaybackQueueCard(
            session: session,
            library: fixture.runtimeGraph.library,
            playback: fixture.runtimeGraph.playback,
            coverCacheWidth: 64,
            onOpen: (_) {},
            onEdit: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SessionCoverProgressRing), findsOneWidget);
      expect(find.byKey(const ValueKey('playback_queue_cover_grid')), findsOneWidget);
    });
  });
}
