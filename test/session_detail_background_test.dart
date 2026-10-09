import 'dart:async';

import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_scaffold.dart';
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

class _SubtitlePresenceService extends PlaybackSubtitleService {
  _SubtitlePresenceService() : super(trackResolver: (_) => null);

  final Set<String> _knownPaths = {};

  @override
  bool hasKnownSubtitle(String trackPath) => _knownPaths.contains(trackPath);

  @override
  bool hasResult(String trackPath) => true;

  void publish(String trackPath, {bool present = true, bool notify = true}) {
    if (present) {
      _knownPaths.add(trackPath);
    } else {
      _knownPaths.remove(trackPath);
    }
    if (notify) notifyListeners();
  }
}

void main() {
  testWidgets(
    'detail ignores unrelated subtitle notifications and defers presence changes',
    (tester) async {
      UiInteractionCoordinator.instance.resetForTest();
      addTearDown(UiInteractionCoordinator.instance.resetForTest);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final subtitles = _SubtitlePresenceService();
      addTearDown(subtitles.dispose);
      final transitioning = ValueNotifier<bool>(true);
      addTearDown(transitioning.dispose);
      final expanded = ValueNotifier<bool>(false);
      addTearDown(expanded.dispose);
      final track = MusicTrack(
        path: '/library/detail.mp3',
        displayName: 'Detail',
        groupKey: '__single_files__',
        groupTitle: 'Imported files',
        groupSubtitle: '',
        isSingle: true,
      );
      fixture.library.addTracks([track], notify: false, persist: false);
      final session = fixture.playback.createTrackSession(track);
      addTearDown(session.shutdown);
      Widget buildDetail() => fixture.build(
        SessionDetailScaffold(
          transitionActive: transitioning,
          session: fixture.playback.sessionSnapshotById(session.id)!,
          coverPathFuture: SynchronousFuture<String?>(null),
          dismissAnimation: const AlwaysStoppedAnimation<double>(0),
          onClose: () {},
          segmentPanelExpandedNotifier: expanded,
        ),
        overrides: [
          playbackSubtitleServiceProvider.overrideWithValue(subtitles),
        ],
      );
      await tester.pumpWidget(buildDetail());
      await tester.pump();
      SessionDetailContent content() => tester.widget<SessionDetailContent>(
        find.byType(SessionDetailContent),
      );
      final initialContent = content();
      expect(initialContent.hasSubtitle, isFalse);

      for (var update = 0; update < 5; update++) {
        subtitles.publish('/library/other.mp3');
        await tester.pump(const Duration(milliseconds: 16));
        expect(identical(content(), initialContent), isTrue);
      }
      subtitles.publish(track.path);
      await tester.pump(const Duration(milliseconds: 16));
      expect(identical(content(), initialContent), isTrue);

      transitioning.value = false;
      await tester.pump();
      await tester.pump();
      expect(content().hasSubtitle, isTrue);
      final updatedContent = content();
      subtitles.publish(track.path);
      await tester.pump();
      expect(identical(content(), updatedContent), isTrue);

      subtitles.publish(track.path, present: false);
      await tester.pump();
      await tester.pump();
      expect(content().hasSubtitle, isFalse);
      subtitles.publish(track.path, notify: false);
      await tester.pumpWidget(buildDetail());
      expect(content().hasSubtitle, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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

      expect(find.byType(SessionDetailContent), findsNothing);
      expect(
        find.byKey(ValueKey<String>('artwork_${session.id}')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('session_detail_close_button')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();

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

      final contentState = tester.state<SessionDetailContentState>(
        find.byType(SessionDetailContent),
      );
      final detailContext = tester.element(find.byType(SessionDetailScaffold));
      final navigator = Navigator.of(detailContext);
      unawaited(
        navigator.push(
          buildAppPageRoute<void>(
            context: detailContext,
            child: const Scaffold(body: Text('Cover session detail')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(
        tester.state<SessionDetailContentState>(
          find.byType(SessionDetailContent),
        ),
        same(contentState),
      );
      expect(
        find.byKey(ValueKey<String>('artwork_${session.id}')),
        findsOneWidget,
      );

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
