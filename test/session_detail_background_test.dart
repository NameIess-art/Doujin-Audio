import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:doujin_audio/app/presentation/app_orientation_controller.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/notifications_platform_service.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_cover_transition.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_scaffold.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_theme.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_subtitle_menu_sheet.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

class _ResolvedCoverCache extends CoverArtworkCacheService {
  _ResolvedCoverCache([this.path = '/covers/detail.png'])
    : super(libraryService: LibraryService());

  String? path;

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
    'detail defers cold credits and reverses before laying out a coverless close',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      UiInteractionCoordinator.instance.resetForTest();
      addTearDown(UiInteractionCoordinator.instance.resetForTest);

      final fixture = AppRuntimeWidgetTestFixture(
        providedNotificationService: PlaybackNotificationService(
          notificationsPlatformService: NotificationsPlatformService(
            isWindowsOverride: false,
          ),
        ),
      );
      addTearDown(fixture.dispose);
      final track = testMusicTrack(
        name: 'Cold credits',
        path: '/music/cold/track.mp3',
        groupKey: '/music/cold',
        groupTitle: 'Cold',
      );
      fixture.library.addTracks([track], persist: false);
      final session = fixture.playback.createTrackSession(track);
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      final target = fixture.library.audioDetailTargetForTrack(track);
      var creditReads = 0;
      final route = SessionDetailRoute(sessionId: session.id);
      const homeKey = ValueKey('coverless_detail_home');
      await tester.pumpWidget(
        fixture.build(
          const Scaffold(key: homeKey),
          overrides: [
            libraryDetailForTargetProvider(target).overrideWith((_) {
              creditReads++;
              return AudioDetail.empty(target).copyWith(circleName: 'Credits');
            }),
          ],
        ),
      );
      final navigator = Navigator.of(tester.element(find.byKey(homeKey)));
      unawaited(navigator.push(route));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(route.animation!.status, AnimationStatus.forward);
      expect(creditReads, 0);
      expect(find.byType(ImageFiltered), findsNothing);

      await tester.pumpAndSettle();
      expect(creditReads, 1);
      expect(find.text('Credits'), findsOneWidget);
      expect(find.byType(ImageFiltered), findsNothing);
      final closing = route.requestClose();
      await Future<void>.value();
      expect(route.animation!.status, AnimationStatus.reverse);
      await closing;
      await tester.pumpAndSettle();
      expect(find.byType(SessionDetailPage), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Android video detail mounts the surface after entry and retains it during exit',
    (tester) async {
      tester.view.physicalSize = const Size(450, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = testMusicTrack(
        name: 'Video',
        path: '/video/track.mp4',
        groupKey: '/video',
        groupTitle: 'Video',
      ).copyWith(isVideo: true);
      fixture.library.addTracks([track], persist: false);
      final session = fixture.playback.createTrackSession(track)
        ..loadedPath = track.path;
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      const homeKey = ValueKey('video_detail_home');
      await tester.pumpWidget(fixture.build(const Scaffold(key: homeKey)));
      final route = SessionDetailRoute(sessionId: session.id);
      unawaited(Navigator.of(tester.element(find.byKey(homeKey))).push(route));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final surface = find.byKey(const ValueKey('session_video_surface'));
      expect(route.animation!.status, AnimationStatus.forward);
      expect(surface, findsNothing);
      await tester.pumpAndSettle();
      expect(surface, findsOneWidget);
      final surfaceElement = tester.element(surface);

      await route.requestClose();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(route.animation!.status, AnimationStatus.reverse);
      expect(tester.element(surface), same(surfaceElement));
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final (entry, exitToDock) in [
    for (final entry in ['list', 'queue', 'dock', 'routed dock']) (entry, true),
    for (final entry in ['list', 'queue', 'dock']) (entry, false),
  ]) {
    testWidgets(
      'detail cover moves from the $entry and returns to the '
      '${exitToDock ? 'matching dock' : 'matching playlist row'}',
      (tester) async {
        tester.view.physicalSize =
            defaultTargetPlatform == TargetPlatform.android
            ? const Size(390, 820)
            : const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final cover = (await tester.runAsync(() async {
          final directory = await Directory.systemTemp.createTemp(
            'cover-flight-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final recorder = ui.PictureRecorder();
          ui.Canvas(recorder).drawColor(Colors.red, ui.BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(192, 192);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          return File('${directory.path}/cover.png')
            ..writeAsBytesSync(bytes!.buffer.asUint8List());
        }))!;
        final cache = _ResolvedCoverCache(cover.path);
        final coldDetail =
            entry == 'list' && defaultTargetPlatform == TargetPlatform.android;
        final fixture = AppRuntimeWidgetTestFixture(
          // Cover-flight rendering does not need native taskbar image decoding.
          providedNotificationService: PlaybackNotificationService(
            notificationsPlatformService: NotificationsPlatformService(
              isWindowsOverride: false,
            ),
          ),
          coverArtworkCacheService: cache,
          configureSettingsRepository: (settings) {
            settings.coverImageResolution = CoverImageResolution.original;
            settings.syncSlice();
          },
        );
        addTearDown(fixture.dispose);
        final tracks = [
          for (final name in ['First', 'Current'])
            testMusicTrack(
              name: name,
              path: '/music/$name.mp3',
              groupKey: '/music/$name',
              groupTitle: name,
            ),
        ];
        fixture.library.addTracks(tracks, persist: false);
        final sessions = [
          for (final track in tracks)
            fixture.playback.createTrackSession(track),
        ];
        final session = sessions.last;
        for (final item in sessions) {
          addTearDown(item.shutdown);
        }
        if (entry == 'queue') {
          session.playbackQueue = PlaybackQueueDefinition(
            name: 'Two covers',
            entries: [
              for (final track in tracks)
                PlaybackQueueEntry(
                  id: track.path,
                  kind: PlaybackQueueEntryKind.track,
                  title: track.displayName,
                  tracks: [track],
                ),
            ],
          );
        }
        fixture.playbackService.syncSlice(
          activeSessions: sessions,
          playingSessionCount: 0,
          focusedSessionId: sessions.first.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        final fromDock = entry.endsWith('dock');
        final showDock = ValueNotifier(exitToDock || fromDock);
        addTearDown(showDock.dispose);
        await tester.pumpWidget(
          fixture.build(
            Column(
              children: [
                const Expanded(child: PlaylistTab()),
                ValueListenableBuilder<bool>(
                  valueListenable: showDock,
                  builder: (_, visible, child) =>
                      visible ? child! : const SizedBox.shrink(),
                  child: SizedBox(
                    width: 300,
                    child: ActiveSessionCarousel(
                      sessions: [
                        for (final item in fromDock ? [session] : sessions)
                          fixture.playback.sessionSnapshotById(item.id)!,
                      ],
                      viewportFraction: 1,
                      presentation: ActiveSessionCarouselPresentation.embedded,
                      isRoutedDock: entry == 'routed dock',
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.runAsync(() async {
          final context = tester.element(find.byType(PlaylistTab));
          await precacheImage(FileImage(cover), context);
          await precacheImage(
            resizeFileImageIfNeeded(path: cover.path, cacheWidth: 64),
            context,
          );
        });
        await pumpAndSettleWithAsync(tester);
        final source = find.byWidgetPredicate(
          (widget) =>
              widget is SessionCoverAnchor &&
              widget.sessionId == session.id &&
              widget.isDock == fromDock,
        );
        expect(source, findsOneWidget);
        if (entry == 'queue') {
          expect(
            tester.widget<SessionCoverAnchor>(source).imageKey,
            const ValueKey('playback_queue_cover_cell_1'),
          );
        }
        final sourceRect = tester.getRect(source);
        // The source has a decoded image, but the detail's independent artwork
        // request has no result yet.
        if (coldDetail) cache.path = null;
        await tester.tap(source);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final flightFinder = find.byKey(
          const ValueKey('session_detail_cover_flight'),
        );
        final enter =
            tester.widget<CustomPaint>(flightFinder).painter!
                as SessionCoverFlight;
        double overlayOpacity(String name) => tester
            .widget<FadeTransition>(
              find.descendant(
                of: find.byKey(ValueKey('session_detail_${name}_fade')),
                matching: find.byType(FadeTransition),
              ).first,
            )
            .opacity
            .value;
        for (final name in ['close', 'title']) {
          expect(overlayOpacity(name), 0, reason: name);
        }
        expect(enter.from, sourceRect);
        expect(enter.to.width, greaterThan(enter.from.width));
        expect(enter.fromRadius, greaterThan(enter.toRadius));
        expect(enter.progress.value, inExclusiveRange(0, 1));
        expect(enter.reverse, isFalse);
        // Android can report window metrics after an orientation-policy change
        // even when the physical view and cover geometry have not changed.
        tester.binding.handleMetricsChanged();
        await tester.pump();
        expect(flightFinder, findsOneWidget);
        final detailImages = find.descendant(
          of: find.byKey(ValueKey('session_detail_cover_${session.id}')),
          matching: find.byType(RawImage),
        );
        final detailImage = detailImages.first;
        expect(enter.to, tester.getRect(detailImage));
        if (coldDetail) {
          final preview = tester.widget<RawImage>(
            find.byKey(const ValueKey('session_detail_cover_preview')).first,
          );
          expect(preview.image!.isCloneOf(enter.image), isTrue);
        }
        if (entry == 'routed dock') {
          tester.view.physicalSize =
              defaultTargetPlatform == TargetPlatform.android
              ? const Size(400, 840)
              : const Size(1200, 780);
          await tester.pump();
          expect(flightFinder, findsNothing);
        }
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        expect(flightFinder, findsNothing);
        final verifyUpgrade = entry == 'dock' && exitToDock;
        final previewFinder = find.byKey(
          const ValueKey('session_detail_cover_preview'),
        );
        final upgradeFinder = find.byKey(
          const ValueKey('session_detail_cover_upgrade'),
        );
        if (verifyUpgrade) {
          expect(enter.image.width, lessThan(192));
          expect(previewFinder, findsOneWidget);
          expect(tester.widget<Opacity>(upgradeFinder).opacity, 0);
        }
        for (final name in ['close', 'title']) {
          expect(overlayOpacity(name), 0);
        }
        await tester.pump(const Duration(milliseconds: 150));
        if (verifyUpgrade) {
          expect(previewFinder, findsOneWidget);
          expect(
            tester.widget<Opacity>(upgradeFinder).opacity,
            inExclusiveRange(0, 1),
          );
        }
        for (final name in ['close', 'title']) {
          expect(overlayOpacity(name), inExclusiveRange(0, 1));
        }
        await tester.pumpAndSettle();
        if (verifyUpgrade) {
          expect(previewFinder, findsNothing);
          expect(tester.widget<RawImage>(detailImage).image!.width, 192);
        }
        for (final name in ['close', 'title']) {
          expect(overlayOpacity(name), 1);
        }
        expect(flightFinder, findsNothing);
        if (entry != 'routed dock') {
          expect(tester.getRect(detailImage), enter.to);
        }
        if (coldDetail) {
          expect(
            find.byKey(const ValueKey('session_detail_cover_preview')),
            findsOneWidget,
          );
          cache.path = cover.path;
          if (exitToDock) {
            cache.invalidateFolder(tracks.last.path);
            await tester.pump();
            await tester.pump();
            expect(previewFinder, findsOneWidget);
            expect(tester.widget<Opacity>(upgradeFinder).opacity, 0);
            for (
              var frame = 0;
              frame < 6 && tester.widget<Opacity>(upgradeFinder).opacity == 0;
              frame++
            ) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(
              tester.widget<Opacity>(upgradeFinder).opacity,
              inExclusiveRange(0, 1),
            );
            await tester.pumpAndSettle();
            expect(previewFinder, findsNothing);
            expect(tester.widget<RawImage>(detailImage).image!.width, 192);
          }
        }

        if (!exitToDock) {
          showDock.value = false;
          await tester.pump();
        }
        if (defaultTargetPlatform == TargetPlatform.android) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(
            find.byKey(const ValueKey('session_detail_close_button')),
          );
        }
        await tester.pump();
        await tester.pump();
        await tester.pump();
        tester.binding.handleMetricsChanged();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final exit =
            tester.widget<CustomPaint>(flightFinder).painter!
                as SessionCoverFlight;
        final target = find.byWidgetPredicate(
          (widget) =>
              widget is SessionCoverAnchor &&
              widget.sessionId == session.id &&
              (exitToDock
                  ? widget.isDock
                  : widget.location == SessionCoverLocation.playlist),
        );
        expect(exit.to, tester.getRect(target));
        expect(exit.reverse, isTrue);
        expect(exit.progress.value, inExclusiveRange(0, 1));
        for (final name in ['close', 'title']) {
          expect(overlayOpacity(name), 1);
        }
        await tester.pumpAndSettle();
        expect(flightFinder, findsNothing);
        expect(find.byType(SessionDetailPage), findsNothing);
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
      await tester.pumpWidget(
        fixture.build(SessionDetailPage(sessionId: session.id)),
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
        final overlay = find.byKey(
          ValueKey(
            kind == 'fullscreen'
                ? 'fullscreen_video_exit'
                : 'session_detail_close_button',
          ),
        );
        final overlayButton = tester.widget<IconButton>(
          find.descendant(of: overlay, matching: find.byType(IconButton)),
        );
        expect(
          overlayButton.style!.foregroundColor!.resolve({WidgetState.hovered}),
          expected.primary,
        );
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
            await tester.tap(
              find.byKey(const ValueKey('session_detail_close_button')),
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
          track: track,
          coverPathFuture: SynchronousFuture<String?>(null),
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

  testWidgets('Windows detail blank space drags the window', (tester) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final expanded = ValueNotifier<bool>(false);
    addTearDown(expanded.dispose);
    final commands = <Object?>[];
    const channel = MethodChannel('doujin_audio/windows_desktop');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'windowCommand') commands.add(call.arguments);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final track = MusicTrack(
      path: '/library/drag.mp3',
      displayName: 'Drag',
      groupKey: '__single_files__',
      groupTitle: 'Imported files',
      groupSubtitle: '',
      isSingle: true,
    );
    fixture.library.addTracks([track], persist: false);
    final session = fixture.playback.createTrackSession(track);
    addTearDown(session.shutdown);
    await tester.pumpWidget(
      fixture.build(
        SessionDetailScaffold(
          transitionActive: ValueNotifier<bool>(false),
          session: fixture.playback.sessionSnapshotById(session.id)!,
          track: track,
          coverPathFuture: SynchronousFuture<String?>(null),
          onClose: () {},
          segmentPanelExpandedNotifier: expanded,
        ),
      ),
    );
    await tester.pump();

    final closeRect = tester.getRect(
      find.byKey(const ValueKey('session_detail_close_button')),
    );
    expect(closeRect.top, 36.0);
    expect(closeRect.left, 24.0);

    await tester.drag(
      find.byKey(const ValueKey('session_detail_close_button')),
      const Offset(40, 0),
    );
    expect(commands, isEmpty);

    final detail = tester.getRect(find.byType(SessionDetailScaffold));
    await tester.dragFrom(
      Offset(detail.center.dx, detail.top + 16),
      const Offset(40, 0),
    );
    expect(commands, [
      {'command': 'drag'},
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    'detail renders blurred cover background and preserves original foreground size',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture(
        providedNotificationService: PlaybackNotificationService(
          notificationsPlatformService: NotificationsPlatformService(
            isWindowsOverride: false,
          ),
        ),
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

      final imageFilteredFinder = find.byType(ImageFiltered);
      expect(imageFilteredFinder, findsOneWidget);
      final filtered = tester.widget<ImageFiltered>(imageFilteredFinder);
      final isDark =
          Theme.of(tester.element(imageFilteredFinder)).brightness ==
          Brightness.dark;
      final expectedSigma = isDark ? 30.0 : 18.0;
      expect(
        filtered.imageFilter,
        ui.ImageFilter.blur(
          sigmaX: expectedSigma,
          sigmaY: expectedSigma,
          tileMode: ui.TileMode.clamp,
        ),
      );
      final backgroundCover = tester.widget<RetryingFileImage>(
        find.descendant(
          of: imageFilteredFinder,
          matching: find.byType(RetryingFileImage),
        ),
      );
      expect(backgroundCover.fit, BoxFit.cover);
      expect(backgroundCover.cacheWidth, 200);
      expect(find.byType(BackdropFilter), findsNothing);
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

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );


  testWidgets(
    'detail blurred background reduces blur sigma in light mode and uses higher sigma in dark mode',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _ResolvedCoverCache(),
      );
      addTearDown(fixture.dispose);
      final track = MusicTrack(
        path: '/library/detail_blur.mp3',
        displayName: 'Detail Blur',
        groupKey: '__single_files__',
        groupTitle: 'Imported files',
        groupSubtitle: '',
        isSingle: true,
      );
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[track], persist: false);
      final session = fixture.runtimeGraph.playback.createTrackSession(track);
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      // Light mode verification:
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        fixture.build(SessionDetailPage(sessionId: session.id)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 230));

      final lightFiltered = tester.widget<ImageFiltered>(
        find.byType(ImageFiltered),
      );
      expect(
        lightFiltered.imageFilter,
        ui.ImageFilter.blur(
          sigmaX: 18.0,
          sigmaY: 18.0,
          tileMode: ui.TileMode.clamp,
        ),
      );

      // Dark mode verification:
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpWidget(
        fixture.build(SessionDetailPage(sessionId: session.id)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 230));

      final darkFiltered = tester.widget<ImageFiltered>(
        find.byType(ImageFiltered),
      );
      expect(
        darkFiltered.imageFilter,
        ui.ImageFilter.blur(
          sigmaX: 30.0,
          sigmaY: 30.0,
          tileMode: ui.TileMode.clamp,
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
  );
}
