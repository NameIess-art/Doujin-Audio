import 'dart:async';

import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

class _ResolvedCoverCache extends CoverArtworkCacheService {
  _ResolvedCoverCache() : super(libraryService: LibraryService());

  @override
  String? resolvedForPlaybackTrack(MusicTrack? track, {String? trackPath}) =>
      '/covers/detail.png';

  @override
  Future<String?> futureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => SynchronousFuture<String?>('/covers/detail.png');
}

void main() {
  testWidgets(
    'detail has no filtered background and preserves original foreground size',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _ResolvedCoverCache(),
        configureSettingsRepository: (settings) {
          settings.coverImageResolution = CoverImageResolution.original;
          settings.syncSlice();
        },
      );
      addTearDown(fixture.dispose);
      final track = MusicTrack(
        path: '/library/detail.mp3',
        displayName: 'Detail',
        groupKey: '__single_files__',
        groupTitle: 'Imported files',
        groupSubtitle: '',
        isSingle: true,
      );
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final session = fixture.runtimeGraph.playback.createTrackSession(track);
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      unawaited(
        Navigator.of(
          tester.element(find.byType(PlaylistTab)),
        ).push(buildSessionDetailRoute(sessionId: session.id)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 230));

      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      final backdropGate = find.byKey(
        const ValueKey<String>('session_detail_backdrop_paint_gate'),
      );
      expect(tester.widget<Opacity>(backdropGate).opacity, 0);
      final artwork = find.byKey(ValueKey<String>('artwork_${session.id}'));
      final foregroundImage = tester.widget<AsyncLocalCoverImage>(
        find.descendant(
          of: artwork,
          matching: find.byType(AsyncLocalCoverImage),
        ),
      );
      expect(foregroundImage.cacheWidth, isNull);

      final dismissGesture = tester.widget<GestureDetector>(
        find.byWidgetPredicate(
          (widget) =>
              widget is GestureDetector && widget.onVerticalDragUpdate != null,
        ),
      );
      dismissGesture.onVerticalDragStart!(DragStartDetails());
      dismissGesture.onVerticalDragUpdate!(
        DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: const Offset(0, 80),
          primaryDelta: 80,
        ),
      );
      await tester.pump();
      expect(tester.widget<Opacity>(backdropGate).opacity, 1);

      dismissGesture.onVerticalDragEnd!(DragEndDetails(primaryVelocity: 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(backdropGate).opacity, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
