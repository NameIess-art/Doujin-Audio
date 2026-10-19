import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:doujin_audio/app/presentation/app_orientation_controller.dart';
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
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_theme.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_subtitle_menu_sheet.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

class _ResolvedCoverCache extends CoverArtworkCacheService {
  _ResolvedCoverCache([this.path = '/covers/detail.png'])
    : super(libraryService: LibraryService());

  final String? path;

  @override
  String? resolvedForPlaybackTrack(MusicTrack? track, {String? trackPath}) =>
      path;

  @override
  Future<String?> futureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => SynchronousFuture<String?>(path);
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
    'detail retains its cover request when another cover scope changes',
    (tester) async {
      UiInteractionCoordinator.instance.resetForTest();
      addTearDown(UiInteractionCoordinator.instance.resetForTest);
      final cache = _ResolvedCoverCache(null);
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      addTearDown(fixture.dispose);
      final track = testMusicTrack(
        name: 'Current',
        path: '/library/current/audio.mp3',
        groupKey: '/library/current',
        groupTitle: 'Current',
      );
      fixture.library.addTracks([track], persist: false);
      final session = fixture.playback.createTrackSession(track);
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: cache.generation,
        isInitialized: true,
      );
      final revealBehind = ValueNotifier(false);
      addTearDown(revealBehind.dispose);
      await tester.pumpWidget(
        fixture.build(
          SessionDetailPage(
            sessionId: session.id,
            revealBehindNotifier: revealBehind,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = tester.widget<SessionDetailTheme>(
        find.byType(SessionDetailTheme),
      );
      cache.invalidateFolder('/library/unrelated');
      await tester.pumpAndSettle();
      final unchanged = tester.widget<SessionDetailTheme>(
        find.byType(SessionDetailTheme),
      );
      expect(unchanged.coverPathFuture, same(original.coverPathFuture));
      expect(unchanged.coverRevision, original.coverRevision);
      cache.invalidateFolder(track.path);
      await tester.pumpAndSettle();
      final changed = tester.widget<SessionDetailTheme>(
        find.byType(SessionDetailTheme),
      );
      expect(changed.coverPathFuture, isNot(same(original.coverPathFuture)));
      expect(changed.coverRevision.scope, original.coverRevision.scope);
      expect(
        changed.coverRevision.revision,
        greaterThan(original.coverRevision.revision),
      );
      cache.invalidateAll();
      await tester.pumpAndSettle();
      final cleared = tester.widget<SessionDetailTheme>(
        find.byType(SessionDetailTheme),
      );
      expect(cleared.coverPathFuture, isNot(same(changed.coverPathFuture)));
      expect(
        cleared.coverRevision.epoch,
        greaterThan(changed.coverRevision.epoch),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final kind in ['normal', 'asmr', 'queue', 'fullscreen']) {
    testWidgets(
      'cover palette reaches detail background controls and menu for $kind',
      (tester) async {
        UiInteractionCoordinator.instance.resetForTest();
        addTearDown(UiInteractionCoordinator.instance.resetForTest);
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final cover = (await tester.runAsync(() async {
          final directory = await Directory.systemTemp.createTemp('detail-ui-');
          addTearDown(() => directory.delete(recursive: true));
          final recorder = ui.PictureRecorder();
          ui.Canvas(recorder).drawColor(Colors.red, ui.BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(16, 16);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          return File('${directory.path}/cover.png')
            ..writeAsBytesSync(bytes!.buffer.asUint8List());
        }))!;
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: _ResolvedCoverCache(cover.path),
        );
        addTearDown(fixture.dispose);
        final track = MusicTrack(
          path:
              '/library/palette-${kind == 'fullscreen' ? 'video.mp4' : '$kind.mp3'}',
          displayName: 'Palette',
          groupKey: '__single_files__',
          groupTitle: 'Imported files',
          groupSubtitle: '',
          isSingle: true,
          isVideo: kind == 'fullscreen',
          remoteMetadataKind: kind == 'asmr'
              ? MusicTrack.remoteMetadataKindAsmrOne
              : null,
        );
        fixture.library.addTracks([track], persist: false);
        final session = fixture.playback.createTrackSession(track);
        addTearDown(session.shutdown);
        if (kind == 'queue') {
          session.playbackQueue = PlaybackQueueDefinition(
            name: 'Colored queue',
            colorValue: Colors.green.toARGB32(),
            entries: [
              PlaybackQueueEntry(
                id: 'track',
                kind: PlaybackQueueEntryKind.track,
                title: track.displayName,
                tracks: [track],
              ),
            ],
          );
        }
        fixture.playbackService.syncSlice(
          activeSessions: [session],
          playingSessionCount: 0,
          focusedSessionId: session.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        if (kind == 'fullscreen') {
          final orientation = AppOrientationController(
            setPreferredOrientations: (_) async {},
            setSystemUiMode: (_) async {},
          );
          final lease = await orientation.enterVideoFullscreen();
          addTearDown(lease.release);
          await tester.pumpWidget(
            fixture.build(
              SessionVideoFullscreenPage(
                sessionId: session.id,
                trackPath: track.path,
                fullscreenLease: lease,
              ),
            ),
          );
        } else {
          await tester.pumpWidget(fixture.build(const PlaylistTab()));
          unawaited(
            Navigator.of(
              tester.element(find.byType(PlaylistTab)),
            ).push(buildSessionDetailRoute(sessionId: session.id)),
          );
        }
        await tester.pumpAndSettle();
        final detail = kind == 'fullscreen'
            ? find.byKey(const ValueKey('fullscreen_video_play_pause'))
            : find.byType(SessionDetailScaffold);
        final brightness = Theme.of(tester.element(detail)).brightness;
        final expected = (await tester.runAsync(
          () => ColorScheme.fromImageProvider(
            provider: FileImage(cover),
            brightness: brightness,
          ),
        ))!;
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          if (Theme.of(tester.element(detail)).colorScheme == expected) break;
        }
        await tester.pumpAndSettle();
        expect(Theme.of(tester.element(detail)).colorScheme, expected);
        final slider = kind == 'fullscreen'
            ? find.byKey(const ValueKey('fullscreen_video_progress'))
            : find.descendant(
                of: find.byKey(ValueKey('progress_${session.id}')),
                matching: find.byType(Slider),
              );
        expect(
          SliderTheme.of(tester.element(slider)).activeTrackColor,
          expected.primary,
        );
        final play = kind == 'fullscreen'
            ? detail
            : find
                  .ancestor(
                    of: find.byIcon(Icons.play_arrow_rounded).last,
                    matching: find.byType(IconButton),
                  )
                  .first;
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find
                          .ancestor(
                            of: play,
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration;
        expect(decoration.color, expected.primary);
        if (kind == 'fullscreen') {
          final scaffold = tester.widget<Scaffold>(
            find.descendant(
              of: find.byType(SessionVideoFullscreenPage),
              matching: find.byType(Scaffold),
            ),
          );
          expect(scaffold.backgroundColor, Colors.black);
        } else {
          final material = tester.widget<Material>(
            find.descendant(of: detail, matching: find.byType(Material)).first,
          );
          expect(material.color, expected.surface);
          await tester.tap(
            find.byKey(const ValueKey('session_subtitle_menu_button')),
          );
          await tester.pumpAndSettle();
          expect(
            Theme.of(
              tester.element(find.byType(SubtitleMenuSheet)),
            ).colorScheme,
            expected,
          );
          Navigator.of(tester.element(find.byType(SubtitleMenuSheet))).pop();
          await tester.pumpAndSettle();
          if (defaultTargetPlatform == TargetPlatform.android) {
            final dismiss = tester.widget<GestureDetector>(
              find.byKey(const ValueKey('session_detail_dismiss_gesture')),
            );
            dismiss.onVerticalDragStart!(DragStartDetails());
            void move(double delta) => dismiss.onVerticalDragUpdate!(
              DragUpdateDetails(
                globalPosition: Offset.zero,
                delta: Offset(0, delta),
                primaryDelta: delta,
              ),
            );
            move(24);
            await tester.pump();
            final content = tester.widget<SessionDetailContent>(
              find.byType(SessionDetailContent),
            );
            final theme = Theme.of(tester.element(detail));
            for (var frame = 0; frame < 8; frame++) {
              move(8);
              await tester.pump(const Duration(milliseconds: 16));
              expect(
                tester.widget<SessionDetailContent>(
                  find.byType(SessionDetailContent),
                ),
                same(content),
              );
              expect(Theme.of(tester.element(detail)), same(theme));
            }
            // A short drag returns to the same page; a long drag closes it.
            dismiss.onVerticalDragEnd!(DragEndDetails(primaryVelocity: 0));
            await tester.pumpAndSettle();
            expect(find.byType(SessionDetailContent), findsOneWidget);
            dismiss.onVerticalDragStart!(DragStartDetails());
            move(400);
            dismiss.onVerticalDragEnd!(
              DragEndDetails(
                primaryVelocity: 600,
                velocity: const Velocity(pixelsPerSecond: Offset(0, 600)),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.byType(SessionDetailContent), findsNothing);
            unawaited(
              Navigator.of(
                tester.element(find.byType(PlaylistTab)),
              ).push(buildSessionDetailRoute(sessionId: session.id)),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 48));
            final enteringContent = tester.widget<SessionDetailContent>(
              find.byType(SessionDetailContent),
            );
            final enteringTheme = Theme.of(tester.element(detail));
            for (var frame = 0; frame < 8; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              expect(
                tester.widget<SessionDetailContent>(
                  find.byType(SessionDetailContent),
                ),
                same(enteringContent),
              );
              expect(Theme.of(tester.element(detail)), same(enteringTheme));
            }
            await tester.pumpAndSettle();
            expect(Theme.of(tester.element(detail)).colorScheme, expected);
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 6));
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

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
      fixture.library.addTracks([track], persist: false);
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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
      ], persist: false);
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

      expect(find.byType(SessionDetailContent), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('artwork_${session.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session_detail_close_button')),
        findsOneWidget,
      );
      final entryContentState = tester.state<SessionDetailContentState>(
        find.byType(SessionDetailContent),
      );
      await tester.pumpAndSettle();
      expect(
        tester.state<SessionDetailContentState>(
          find.byType(SessionDetailContent),
        ),
        same(entryContentState),
      );

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
      for (var round = 0; round < 2; round++) {
        unawaited(
          navigator.push(
            buildAppPageRoute<void>(
              context: detailContext,
              child: const Scaffold(body: Text('Cover session detail')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Route visibility can rebuild immutable widgets; the page state and
        // its controllers must survive being covered and revealed.
        expect(
          tester.state<SessionDetailContentState>(
            find.byType(SessionDetailContent, skipOffstage: false),
          ),
          same(contentState),
        );
        navigator.pop();
        await tester.pumpAndSettle();
        expect(
          tester.state<SessionDetailContentState>(
            find.byType(SessionDetailContent),
          ),
          same(contentState),
        );
      }
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
        find.byKey(const ValueKey('session_detail_dismiss_gesture')),
      );
      if (defaultTargetPlatform == TargetPlatform.android) {
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
      } else {
        expect(dismissGesture.onVerticalDragUpdate, isNull);
      }
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
