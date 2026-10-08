import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show ProviderContainer, ProviderScope;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/app_orientation_controller.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/cover_image_retention.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_layout.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_subtitle_panel.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playback_queue_cover.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/session_video_viewport.dart';
import 'package:doujin_audio/features/player/presentation/session_video_surface.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/app_brand_icon.dart';
import 'package:doujin_audio/core/widgets/duration_overlay.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/test_playback_commands.dart';

class _RecordingPlaybackCoverCacheService extends CoverArtworkCacheService {
  _RecordingPlaybackCoverCacheService()
    : super(libraryService: LibraryService());

  final List<String> requestedPaths = <String>[];

  @override
  String? resolvedForPlaybackTrack(MusicTrack? track, {String? trackPath}) =>
      null;

  @override
  Future<String?> futureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final path = track?.path ?? trackPath;
    if (path != null) {
      requestedPaths.add(path);
    }
    return SynchronousFuture<String?>(null);
  }

  @override
  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) {
    return SynchronousFuture<String?>(null);
  }
}

class _RecordingWorkCoverCacheService
    extends _RecordingPlaybackCoverCacheService {
  @override
  String? coverScopeFolderForTrack(MusicTrack? track, {String? trackPath}) =>
      '/library/work';
}

Set<String> _selectedSortControls(WidgetTester tester) {
  final controls =
      tester.widget(
            find.byWidgetPredicate((widget) => widget is SegmentedButton),
          )
          as dynamic;
  return (controls.selected as Set<Object>)
      .map((value) => value.toString().split('.').last)
      .toSet();
}

void _expectThemeSessionResetButtonStyle(WidgetTester tester, Finder finder) {
  expect(finder, findsOneWidget);
  final button = tester.widget<FilledButton>(finder);
  final style = button.style!;
  final colorScheme = Theme.of(tester.element(finder)).colorScheme;
  const enabled = <WidgetState>{};

  expect(
    style.padding!.resolve(enabled),
    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  );
  expect(style.minimumSize!.resolve(enabled), const Size.fromHeight(48));
  expect(tester.getSize(finder).height, 48);
  expect(
    style.shape!.resolve(enabled),
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );
  expect(style.visualDensity, VisualDensity.standard);
  expect(style.elevation!.resolve(enabled), 0);
  expect(
    style.backgroundColor!.resolve(enabled),
    colorScheme.primary.withValues(alpha: 0.12),
  );
  expect(style.foregroundColor!.resolve(enabled), colorScheme.primary);
  final textStyle = style.textStyle!.resolve(enabled)!;
  expect(textStyle.fontSize, 14);
  expect(textStyle.fontWeight, FontWeight.w700);
}

Future<
  ({
    AppRuntimeWidgetTestFixture fixture,
    PlaybackSession session,
    _RecordingPlaybackCoverCacheService coverCache,
  })
>
_pumpSubtitleDetail({
  required WidgetTester tester,
  required SubtitleTrack subtitleTrack,
  required Duration initialPosition,
  MusicTrack? initialTrack,
  Size physicalSize = const Size(1080, 2400),
  Future<SubtitleTrack?>? subtitleResult,
  Widget Function(PlaybackSessionSnapshot)? detailBuilder,
  List<MusicTrack>? queueTracks,
  bool preloadSubtitle = false,
  bool openDetail = true,
  VoidCallback? onSubtitleLoad,
  List<NavigatorObserver> navigatorObservers = const [],
  void Function(AppRuntimeWidgetTestFixture)? configureFixture,
  List<Override> overrides = const [],
}) async {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = physicalSize;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final track =
      initialTrack ??
      queueTracks?.first ??
      MusicTrack(
        path: '/library/subtitles/track.mp3',
        displayName: 'Subtitle track',
        groupKey: '/library/subtitles',
        groupTitle: 'Subtitle album',
        groupSubtitle: '/library/subtitles',
        isSingle: false,
      );
  final coverCache = _RecordingPlaybackCoverCacheService();
  final fixture = AppRuntimeWidgetTestFixture(
    coverArtworkCacheService: coverCache,
  );
  addTearDown(fixture.dispose);
  configureFixture?.call(fixture);
  fixture.runtimeGraph.library.addTracks(
    queueTracks ?? <MusicTrack>[track],
    notify: false,
    persist: false,
  );
  final session = PlaybackSession(
    id: 'subtitle-session',
    currentTrackPath: track.path,
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.single,
    volume: 1,
    customQueueTracks: queueTracks,
    playbackQueue: queueTracks == null
        ? null
        : PlaybackQueueDefinition(
            name: 'Test queue',
            entries: [
              for (var index = 0; index < queueTracks.length; index++)
                PlaybackQueueEntry(
                  id: '$index',
                  kind: PlaybackQueueEntryKind.track,
                  title: queueTracks[index].displayName,
                  tracks: [queueTracks[index]],
                ),
            ],
          ),
    createdAt: DateTime(2026),
    state: const PlayerState(false, ProcessingState.ready),
  )..setOptimisticPosition(initialPosition);
  fixture.playbackService.registerSession(session);
  fixture.playbackService.syncSlice(
    activeSessions: <PlaybackSession>[session],
    playingSessionCount: 0,
    focusedSessionId: session.id,
    coverGeneration: coverCache.generation,
    isInitialized: true,
  );
  final subtitleService = PlaybackSubtitleService(
    trackResolver: (_) => track,
    subtitleLoader: (_, _) {
      onSubtitleLoad?.call();
      return subtitleResult ?? Future.value(subtitleTrack);
    },
  );
  if (preloadSubtitle) await subtitleService.load(track.path);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        nativePlaybackChannel,
        (_) async => <String, Object?>{'ok': true, 'value': null},
      );
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativePlaybackChannel, null);
  });

  await tester.pumpWidget(
    fixture.build(
      detailBuilder == null
          ? const PlaylistTab()
          : Scaffold(
              body: detailBuilder(
                fixture.runtimeGraph.playback.sessionSnapshotById(session.id)!,
              ),
            ),
      subtitleService: subtitleService,
      navigatorObservers: navigatorObservers,
      overrides: overrides,
    ),
  );
  await tester.pumpAndSettle();
  coverCache.requestedPaths.clear();
  if (detailBuilder == null && openDetail) {
    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: session.id)),
    );
  }
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();

  return (fixture: fixture, session: session, coverCache: coverCache);
}

void main() {
  AppRuntimeTestFixture.initialize();
  late Database testDatabase;

  setUpAll(() async {
    testDatabase = await AppRuntimeTestFixture.installSharedDatabase();
  });

  tearDownAll(() async {
    await AppRuntimeTestFixture.disposeSharedDatabase(testDatabase);
  });

  testWidgets('detail repeated close only pops its own route', (tester) async {
    await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
      initialPosition: Duration.zero,
    );
    final close = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down_rounded),
    );
    close.onPressed!();
    close.onPressed!();
    await tester.pumpAndSettle();
    expect(find.byType(SessionDetailPage), findsNothing);
    expect(find.byType(PlaylistTab), findsOneWidget);
    expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'detail pauses internal animation through entry and dismiss on $platform',
      (tester) async {
        final fixture = await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: Duration.zero,
          physicalSize: platform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1080, 2400),
        );
        final navigator = Navigator.of(
          tester.element(find.byType(SessionDetailPage)),
        );
        navigator.pop();
        await tester.pumpAndSettle();
        final route = buildSessionDetailRoute(sessionId: fixture.session.id);
        unawaited(navigator.push(route));
        await tester.pump();
        await tester.pump();
        final content = find.byType(SessionDetailContent, skipOffstage: false);
        expect(content, findsOneWidget);
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isFalse);
        await tester.pump(const Duration(milliseconds: 60));
        final firstTop = tester.getTopLeft(content).dy;
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.getTopLeft(content).dy, lessThan(firstTop));
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isFalse);
        await tester.pumpAndSettle();
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isTrue);

        final drag = tester.widget<GestureDetector>(
          find
              .descendant(
                of: find.byType(SessionDetailPage),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is GestureDetector &&
                      widget.onVerticalDragUpdate != null,
                ),
              )
              .first,
        );
        drag.onVerticalDragStart!(DragStartDetails());
        drag.onVerticalDragUpdate!(
          DragUpdateDetails(
            globalPosition: Offset.zero,
            delta: const Offset(0, 60),
            primaryDelta: 60,
          ),
        );
        await tester.pump();
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isFalse);
        drag.onVerticalDragCancel!();
        await tester.pumpAndSettle();
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isTrue);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final (cachedSubtitle, closeDuringEntrance) in [
    (false, false),
    (true, false),
    (false, true),
  ]) {
    testWidgets(
      'Windows detail defers cold artwork and subtitle work '
      '(cached subtitle: $cachedSubtitle, close early: $closeDuringEntrance)',
      (tester) async {
        final interaction = UiInteractionCoordinator.instance;
        interaction.resetForTest();
        addTearDown(interaction.resetForTest);
        final observer = UiInteractionNavigatorObserver();
        addTearDown(observer.dispose);
        var subtitleLoads = 0;
        final fixture = await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(
            sourcePath: 'test.srt',
            cues: const [
              SubtitleCue(
                start: Duration.zero,
                end: Duration(seconds: 5),
                text: 'Cached or deferred subtitle',
              ),
            ],
          ),
          initialPosition: Duration.zero,
          physicalSize: const Size(3840, 2400),
          openDetail: false,
          preloadSubtitle: cachedSubtitle,
          onSubtitleLoad: () => subtitleLoads++,
          navigatorObservers: [observer],
        );
        expect(subtitleLoads, cachedSubtitle ? 1 : 0);
        final navigator = Navigator.of(tester.element(find.byType(PlaylistTab)));
        final route = buildSessionDetailRoute(sessionId: fixture.session.id);
        unawaited(navigator.push(route));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(fixture.coverCache.requestedPaths, isEmpty);
        expect(subtitleLoads, cachedSubtitle ? 1 : 0);
        expect(
          find.text('Cached or deferred subtitle'),
          cachedSubtitle ? findsOneWidget : findsNothing,
        );
        if (closeDuringEntrance) navigator.pop();
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
        await tester.pump();
        expect(
          fixture.coverCache.requestedPaths.length,
          closeDuringEntrance ? 0 : 1,
        );
        expect(subtitleLoads, closeDuringEntrance ? 0 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  testWidgets('local work switcher waits for idle and reuses the result', (
    tester,
  ) async {
    UiInteractionCoordinator.instance.resetForTest();
    addTearDown(UiInteractionCoordinator.instance.resetForTest);
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _RecordingWorkCoverCacheService(),
    );
    addTearDown(fixture.dispose);
    final busy = ValueNotifier<bool>(true);
    addTearDown(busy.dispose);
    final showDetail = ValueNotifier<bool>(true);
    addTearDown(showDetail.dispose);
    final tracks = <MusicTrack>[
      for (final folder in ['one', 'two'])
        MusicTrack(
          path: PathMatcher.normalize('/library/work/$folder/track.mp3'),
          displayName: folder,
          groupKey: '/library/work/$folder',
          groupTitle: 'Work',
          groupSubtitle: '',
          isSingle: false,
        ),
    ];
    fixture.library.addWatchedFolder('/library/work', notify: false);
    fixture.library.addTracks(tracks, notify: false, persist: false);
    final session = fixture.playback.createTrackSession(tracks.first);
    final snapshot = fixture.playback.sessionSnapshotById(session.id)!;
    final singleTrack = MusicTrack(
      path: PathMatcher.normalize('/library/single.mp3'),
      displayName: 'Single',
      groupKey: '/library',
      groupTitle: 'Single',
      groupSubtitle: '',
      isSingle: true,
    );
    fixture.library.addTracks([singleTrack], notify: false, persist: false);
    final singleSession = fixture.playback.createTrackSession(singleTrack);
    final selectedSession = ValueNotifier<PlaybackSessionSnapshot>(snapshot);
    addTearDown(selectedSession.dispose);
    final app = fixture.build(
      ValueListenableBuilder<bool>(
        valueListenable: showDetail,
        builder: (context, visible, _) => visible
            ? Scaffold(
                body: ValueListenableBuilder<PlaybackSessionSnapshot>(
                  valueListenable: selectedSession,
                  builder: (context, current, _) => SessionDetailContent(
                    session: current,
                    artworkWidget: const SizedBox.shrink(),
                    transitionActive: busy,
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
    bool switcherEnabled() => tester
        .widget<TransportPlaybackControlPanel>(
          find.byType(TransportPlaybackControlPanel),
        )
        .hasSiblings;

    await tester.pumpWidget(app);
    await tester.pump();
    final paths = ProviderScope.containerOf(
      tester.element(find.byType(SessionDetailContent)),
    ).read(audioPathCoordinatorProvider);
    expect(switcherEnabled(), isFalse);
    expect(paths.cachedHasOtherTracksInSameWork(tracks.first.path), isNull);

    final disposedInteraction = Object();
    UiInteractionCoordinator.instance.beginInteraction(disposedInteraction);
    busy.value = false;
    await tester.pump();
    showDetail.value = false;
    await tester.pump();
    UiInteractionCoordinator.instance.endInteraction(disposedInteraction);
    await tester.pump(
      UiInteractionCoordinator.instance.idleDelay +
          const Duration(milliseconds: 20),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(paths.cachedHasOtherTracksInSameWork(tracks.first.path), isNull);
    busy.value = true;
    showDetail.value = true;
    await tester.pump();
    expect(switcherEnabled(), isFalse);

    final interaction = Object();
    UiInteractionCoordinator.instance.beginInteraction(interaction);
    busy.value = false;
    await tester.pump();
    selectedSession.value = fixture.playback.sessionSnapshotById(
      singleSession.id,
    )!;
    await tester.pump();
    UiInteractionCoordinator.instance.endInteraction(interaction);
    await tester.pump(
      UiInteractionCoordinator.instance.idleDelay +
          const Duration(milliseconds: 20),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(switcherEnabled(), isFalse);
    expect(paths.cachedHasOtherTracksInSameWork(tracks.first.path), isNull);

    selectedSession.value = snapshot;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(switcherEnabled(), isTrue);
    expect(paths.cachedHasOtherTracksInSameWork(tracks.first.path), isTrue);

    showDetail.value = false;
    await tester.pump();
    showDetail.value = true;
    await tester.pump();
    expect(switcherEnabled(), isTrue);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    // Drain the shared SQLite queue outside fake time after the detail is
    // removed; its deferred label loads must finish before fixture teardown.
    await tester.runAsync(
      () => fixture.persistenceRepository.loadTimeSegmentLabels(
        TimeSegmentLabel.trackKeyFor(tracks.first),
      ),
    );
  });

  testWidgets(
    'detail drag takes over a running spring and releases interaction',
    (tester) async {
      await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
      );
      final drag = tester.widget<GestureDetector>(
        find
            .descendant(
              of: find.byType(SessionDetailPage),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is GestureDetector &&
                    widget.onVerticalDragUpdate != null,
              ),
            )
            .first,
      );
      void move(double delta) => drag.onVerticalDragUpdate!(
        DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: Offset(0, delta),
          primaryDelta: delta,
        ),
      );
      drag.onVerticalDragStart!(DragStartDetails());
      move(120);
      drag.onVerticalDragEnd!(DragEndDetails(primaryVelocity: 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      drag.onVerticalDragStart!(DragStartDetails());
      move(40);
      await tester.pump();
      expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
      drag.onVerticalDragCancel!();
      await tester.pumpAndSettle();
      await tester.pump(
        UiInteractionCoordinator.instance.idleDelay +
            const Duration(milliseconds: 20),
      );
      expect(find.byType(SessionDetailPage), findsOneWidget);
      expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final replaceQueue in [false, true]) {
    testWidgets(
      'switcher waits for actual exit and validates queue, replaced=$replaceQueue',
      (tester) async {
        final tracks = List.generate(
          2,
          (i) => MusicTrack(
            path: '/queue/$i.mp3',
            displayName: 'Queue track $i',
            groupKey: '__single_files__',
            groupTitle: '',
            groupSubtitle: '',
            isSingle: true,
          ),
        );
        final harness = await _pumpSubtitleDetail(
          tester: tester,
          queueTracks: tracks,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: Duration.zero,
        );
        final commands = <(String, String, int?)>[];
        harness.fixture.runtimeGraph.playback.detachCommandPort();
        harness.fixture.runtimeGraph.playback.attachPlaybackCommands(
          prepareSession:
              (
                session, {
                required nextPath,
                autoPlay = true,
                forceStartAtZero = false,
                showLoading = true,
                targetQueueIndex,
              }) async {
                commands.add((session.id, nextPath, targetQueueIndex));
                return true;
              },
          pauseSession: (_) async {},
          startSession: (_, {required shouldStartTriggerCountdown}) async =>
              true,
          resolveAdvance: (_, {required forward}) => null,
          hasAdjacent: (_, {required forward}) => true,
        );
        await tester.tap(
          find.byTooltip(harness.fixture.languageProvider.tr('switch_audio')),
        );
        await tester.pumpAndSettle();
        final row = find.byKey(
          ValueKey('queue_switcher_track_${tracks[1].path}'),
        );
        await tester.tap(row);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 210));
        expect(commands, isEmpty);
        expect(harness.session.currentTrackPath, tracks.first.path);
        if (replaceQueue) {
          harness.session.playbackQueue = harness.session.playbackQueue!
              .copyWith(entries: []);
        }
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        if (replaceQueue) {
          expect(harness.session.currentTrackPath, tracks.first.path);
          expect(commands, isEmpty);
        } else {
          expect(commands, [(harness.session.id, tracks[1].path, 1)]);
        }
        await tester.pump(PlaybackSession.loadingIndicatorThreshold);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final forward in [false, true]) {
    testWidgets(
      'five-second ${forward ? 'forward' : 'rewind'} delays the central spinner by 400ms',
      (tester) async {
        final harness = await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: const Duration(seconds: 20),
          physicalSize: defaultTargetPlatform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1080, 2400),
        );
        final session = harness.session;
        final playback = harness.fixture.runtimeGraph.playback;
        final stateSubscription = session.stateStream.listen((_) {
          playback.publishSessionState(session.id);
        });
        addTearDown(stateSubscription.cancel);
        session.loadedPath = session.currentTrackPath;
        session.setOptimisticState(playing: true);
        playback.publishSessionState(session.id);
        await tester.pump();

        await tester.tap(
          find.byIcon(
            forward ? Icons.forward_5_rounded : Icons.replay_5_rounded,
          ),
        );
        await tester.pump();
        expect(session.position, Duration(seconds: forward ? 25 : 15));
        session.setOptimisticState(processingState: ProcessingState.buffering);
        await tester.pump();
        final spinner = find.descendant(
          of: find.byType(TransportPlaybackControlPanel),
          matching: find.byType(CircularProgressIndicator),
        );
        expect(spinner, findsNothing);
        await tester.pump(const Duration(milliseconds: 399));
        expect(spinner, findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(spinner, findsOneWidget);

        session.setOptimisticState(processingState: ProcessingState.ready);
        await tester.pump();
        await tester.pump();
        expect(spinner, findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('detail transport updates do not request artwork again', (
    tester,
  ) async {
    final harness = await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
      initialPosition: Duration.zero,
    );
    // This fixture deliberately has no cover. Finish its bounded retries
    // before counting work caused by transport changes.
    for (var i = 0; i < 13; i++) {
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    }
    harness.coverCache.requestedPaths.clear();
    await harness.fixture.runtimeGraph.playback.setSessionVolume(
      harness.session.id,
      1.2,
      persist: false,
    );
    await tester.pumpAndSettle();
    expect(harness.coverCache.requestedPaths, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey('session_volume_button_anchor')),
    );
    await tester.pumpAndSettle();
    expect(find.text('105%'), findsOneWidget);
    expect(harness.coverCache.requestedPaths, isEmpty);
  });

  for (final cueCount in [100, 1000, 5000]) {
    testWidgets('timeline reuses measured overlap for $cueCount cues', (
      tester,
    ) async {
      final track = SubtitleTrack(
        sourcePath: 'large.srt',
        cues: List.generate(
          cueCount,
          (i) => SubtitleCue(
            start: Duration(seconds: i * 2),
            end: Duration(seconds: i * 2 + 2),
            text: 'Cue $i',
          ),
        ),
      );
      await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: track,
        initialPosition: Duration(seconds: cueCount),
      );
      final timeline = find.byType(TimelineSubtitleView);
      final dynamic state = tester.state(timeline);
      final listFinder = find.byKey(const ValueKey('subtitle_timeline_list'));
      final initialCount = tester
          .widget<ListView>(listFinder)
          .childrenDelegate
          .estimatedChildCount!;
      expect(initialCount, 61);
      final measuredBefore = state.debugMeasuredCueCount as int;
      await tester.drag(listFinder, const Offset(0, -10000));
      await tester.pumpAndSettle();
      final expandedCount = tester
          .widget<ListView>(listFinder)
          .childrenDelegate
          .estimatedChildCount!;
      expect(
        state.debugMeasuredCueCount - measuredBefore,
        expandedCount - initialCount,
      );
      final beforeResize = state.debugMeasuredCueCount as int;
      tester.view.physicalSize = const Size(1200, 2400);
      await tester.pumpAndSettle();
      expect(state.debugMeasuredCueCount - beforeResize, expandedCount);
      expect(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'subtitle_timeline_text_',
                  ),
            )
            .evaluate()
            .length,
        lessThan(20),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('cached subtitles remain visible during entry', (tester) async {
    final busy = ValueNotifier(true);
    addTearDown(busy.dispose);
    final track = SubtitleTrack(
      sourcePath: 'cached.srt',
      cues: [
        const SubtitleCue(
          start: Duration.zero,
          end: Duration(seconds: 10),
          text: 'Cached line',
        ),
      ],
    );
    await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: track,
      initialPosition: Duration.zero,
      preloadSubtitle: true,
      detailBuilder: (session) =>
          SessionSubtitlePanel(session: session, transitionActive: busy),
    );
    expect(find.text('Cached line'), findsOneWidget);
  });

  testWidgets(
    'SessionSubtitlePanel holds subtitle text across gaps and during buffering',
    (tester) async {
      final busy = ValueNotifier(false);
      addTearDown(busy.dispose);
      final track = SubtitleTrack(
        sourcePath: 'asmr.vtt',
        cues: const [
          SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 3),
            text: 'Line 1',
          ),
          SubtitleCue(
            start: Duration(seconds: 10),
            end: Duration(seconds: 12),
            text: 'Line 2',
          ),
        ],
      );
      final harness = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: track,
        initialPosition: const Duration(seconds: 2),
        preloadSubtitle: true,
        detailBuilder: (session) =>
            SessionSubtitlePanel(session: session, transitionActive: busy),
      );
      expect(find.text('Line 1'), findsOneWidget);

      // In the gap between 3s and 10s: Line 1 should persist
      harness.session.setOptimisticPosition(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Line 1'), findsOneWidget);

      // Audio buffering occurs (isPlaybackLoading = true) while track is loaded
      harness.session.state = const PlayerState(
        true,
        ProcessingState.buffering,
      );
      harness.fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[harness.session],
        playingSessionCount: 1,
        focusedSessionId: harness.session.id,
        coverGeneration: harness.coverCache.generation,
        isInitialized: true,
      );
      await tester.pump();
      // Subtitle must NOT be replaced with loading
      expect(find.byKey(const ValueKey('subtitle_loading')), findsNothing);
      expect(find.text('Line 1'), findsOneWidget);

      // Reaching Line 2
      harness.session.setOptimisticPosition(const Duration(seconds: 11));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text('Line 2'), findsOneWidget);
    },
  );

  for (final disposeBeforeResult in [false, true]) {
    testWidgets(
      'segment loading is shared and invalidated, disposed=$disposeBeforeResult',
      (tester) async {
        final interaction = UiInteractionCoordinator.instance;
        interaction.resetForTest();
        addTearDown(interaction.resetForTest);
        final busy = ValueNotifier(true);
        addTearDown(busy.dispose);
        final pending = Completer<void>();
        var reads = 0;
        await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: Duration.zero,
          configureFixture: (fixture) {
            fixture.persistenceRepository.beforeTimeSegmentLabelLoad = () {
              reads++;
              return reads == 1 ? pending.future : Future.value();
            };
          },
          detailBuilder: (session) => SessionDetailContent(
            session: session,
            artworkWidget: const SizedBox.shrink(),
            transitionActive: busy,
          ),
        );
        final state = tester.state<SessionDetailContentState>(
          find.byType(SessionDetailContent),
        );
        state.expandSegmentPanel();
        await tester.pumpAndSettle();
        expect(reads, 0);
        final navigation = Object();
        interaction.beginInteraction(navigation);
        busy.value = false;
        await tester.pump();
        expect(reads, 0);
        interaction.endInteraction(navigation);
        await tester.pump(interaction.idleDelay);
        await tester.pump();
        expect(reads, 1);
        busy.value = true;
        if (disposeBeforeResult) {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        pending.completeError(StateError('label read failure'));
        await tester.pumpAndSettle();
        busy.value = false;
        await tester.pumpAndSettle();
        if (!disposeBeforeResult) {
          state.collapseSegmentPanel();
          state.expandSegmentPanel();
          await tester.pump();
          expect(reads, 2);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final closeBeforeIdle in [false, true]) {
      testWidgets(
        'segment loading cancels stale starts on $platform, closed=$closeBeforeIdle',
        (tester) async {
          final interaction = UiInteractionCoordinator.instance;
          interaction.resetForTest();
          addTearDown(interaction.resetForTest);
          final busy = ValueNotifier(true);
          addTearDown(busy.dispose);
          late ValueNotifier<PlaybackSessionSnapshot> selected;
          var reads = 0;
          final tracks = [
            for (final name in ['old', 'current'])
              MusicTrack(
                path: '/library/segments/$name.mp3',
                displayName: name,
                groupKey: '/library/segments',
                groupTitle: 'Segments',
                groupSubtitle: '',
                isSingle: false,
              ),
          ];
          final harness = await _pumpSubtitleDetail(
            tester: tester,
            subtitleTrack: SubtitleTrack(
              sourcePath: 'empty.srt',
              cues: const [],
            ),
            initialPosition: Duration.zero,
            queueTracks: tracks,
            configureFixture: (fixture) {
              fixture.persistenceRepository.beforeTimeSegmentLabelLoad = () {
                reads++;
                return Future.value();
              };
            },
            detailBuilder: (snapshot) {
              selected = ValueNotifier(snapshot);
              return ValueListenableBuilder<PlaybackSessionSnapshot>(
                valueListenable: selected,
                builder: (_, session, _) => SessionDetailContent(
                  session: session,
                  artworkWidget: const SizedBox.shrink(),
                  transitionActive: busy,
                ),
              );
            },
          );
          addTearDown(selected.dispose);
          expect(reads, 0);
          await tester.runAsync(() async {
            for (final track in tracks) {
              await harness.fixture.persistenceRepository
                  .upsertTimeSegmentLabel(
                    TimeSegmentLabel(
                      id: 'deferred-${track.displayName}',
                      trackKey: TimeSegmentLabel.trackKeyFor(track),
                      name: '${track.displayName} deferred label',
                      start: Duration.zero,
                      end: const Duration(seconds: 5),
                      colorValue: kTimeSegmentLabelPalette.first,
                      createdAt: DateTime(2026),
                      updatedAt: DateTime(2026),
                    ),
                  );
            }
          });
          tester
              .state<SessionDetailContentState>(
                find.byType(SessionDetailContent),
              )
              .expandSegmentPanel();
          final navigation = Object();
          interaction.beginInteraction(navigation);
          busy.value = false;
          await tester.pump();
          harness.session.currentTrackPath = tracks.last.path;
          selected.value = PlaybackSessionSnapshot.fromRuntime(harness.session);
          await tester.pump();
          expect(reads, 0);
          if (closeBeforeIdle) {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          interaction.endInteraction(navigation);
          await tester.pump(interaction.idleDelay);
          await tester.pump();
          expect(reads, closeBeforeIdle ? 0 : 1);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
          expect(reads, closeBeforeIdle ? 0 : 1);
          expect(find.text('old deferred label'), findsNothing);
          if (!closeBeforeIdle) {
            expect(
              tester
                  .widget<TimeSegmentPanel>(find.byType(TimeSegmentPanel))
                  .labels
                  .map((label) => label.name),
              ['current deferred label'],
            );
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }

  for (final disposeBeforeCommit in [false, true]) {
    testWidgets(
      'cold subtitle waits for animation, disposed=$disposeBeforeCommit',
      (tester) async {
        final busy = ValueNotifier(true);
        addTearDown(busy.dispose);
        final result = Completer<SubtitleTrack?>();
        final track = SubtitleTrack(
          sourcePath: 'deferred.srt',
          cues: [
            const SubtitleCue(
              start: Duration.zero,
              end: Duration(seconds: 2),
              text: 'Old line',
            ),
            const SubtitleCue(
              start: Duration(seconds: 2),
              end: Duration(seconds: 10),
              text: 'Latest line',
            ),
          ],
        );
        final harness = await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: track,
          subtitleResult: result.future,
          initialPosition: Duration.zero,
          detailBuilder: (session) =>
              SessionSubtitlePanel(session: session, transitionActive: busy),
        );
        result.complete(track);
        await tester.pumpAndSettle();
        expect(find.text('Old line'), findsNothing);
        harness.session.setOptimisticPosition(const Duration(seconds: 3));
        await tester.pump();
        if (disposeBeforeCommit) {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        busy.value = false;
        await tester.pumpAndSettle();
        if (disposeBeforeCommit) {
          expect(find.text('Latest line'), findsNothing);
        } else {
          expect(find.text('Latest line'), findsOneWidget);
          final list = tester.widget<ListView>(
            find.byKey(const ValueKey('subtitle_timeline_list')),
          );
          expect(list.controller!.offset, greaterThan(0));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final hidden in [true, false]) {
    testWidgets(
      'buffered progress defers while ${hidden ? 'hidden' : 'interacting'} and resumes with the latest value',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final interactions = UiInteractionCoordinator.instance;
        interactions.resetForTest();
        addTearDown(interactions.resetForTest);
        final visible = ValueNotifier(true);
        addTearDown(visible.dispose);
        final session = PlaybackSession(
          id: 'buffered-session',
          currentTrackPath: '/library/track.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(false, ProcessingState.ready),
        )..setOptimisticDuration(const Duration(minutes: 1));
        addTearDown(session.shutdown);
        await tester.pumpWidget(
          fixture.build(
            ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
              child: SessionProgressBar(
                session: PlaybackSessionSnapshot.fromRuntime(session),
                playback: fixture.runtimeGraph.playback,
                paths: fixture.runtimeGraph.audioPaths,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (hidden) {
          visible.value = false;
          await tester.pump();
        } else {
          interactions.beginInteraction('buffered-test');
        }
        final originalSlider = tester.widget<Slider>(find.byType(Slider));
        for (final seconds in [10, 20]) {
          session.applyNativeProgress(
            NativePlaybackProgressUpdate(
              sessionId: session.id,
              position: Duration.zero,
              duration: const Duration(minutes: 1),
              bufferedPosition: Duration(seconds: seconds),
              nativeElapsedRealtimeMs: seconds * 1000,
            ),
          );
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(
          tester.widget<Slider>(find.byType(Slider)),
          same(originalSlider),
        );
        if (hidden) {
          visible.value = true;
        } else {
          interactions.cancelInteraction('buffered-test');
        }
        await tester.pumpAndSettle();
        expect(
          tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue,
          20000,
        );
        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChangeStart!(0);
        slider.onChanged!(30000);
        await tester.pump();
        expect(tester.widget<Slider>(find.byType(Slider)).value, 30000);
        session.applyNativeProgress(
          NativePlaybackProgressUpdate(
            sessionId: session.id,
            position: const Duration(seconds: 3),
            duration: const Duration(minutes: 1),
            bufferedPosition: const Duration(seconds: 40),
            nativeElapsedRealtimeMs: 30000,
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.widget<Slider>(find.byType(Slider)).value, 30000);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'SessionProgressBar renders compact slider height and tight timecode spacing',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final session = PlaybackSession(
        id: 'compact-progress-session',
        currentTrackPath: '/library/track.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      )..setOptimisticDuration(const Duration(minutes: 1));
      addTearDown(session.shutdown);

      await tester.pumpWidget(
        fixture.build(
          SessionProgressBar(
            session: PlaybackSessionSnapshot.fromRuntime(session),
            playback: fixture.runtimeGraph.playback,
            paths: fixture.runtimeGraph.audioPaths,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sliderFinder = find.byType(Slider);
      expect(sliderFinder, findsOneWidget);
      final sliderRect = tester.getRect(sliderFinder);
      // Slider height is compact (20px)
      expect(sliderRect.height, lessThanOrEqualTo(24));

      final timecodeFinder = find.byType(TimecodeLabel).first;
      expect(timecodeFinder, findsOneWidget);
      final timecodeRect = tester.getRect(timecodeFinder);

      // Gap between slider bottom and timecode top is reduced (< 6px)
      final gap = timecodeRect.top - sliderRect.bottom;
      expect(gap, lessThanOrEqualTo(5));
    },
  );

  testWidgets(
    'segment marker geometry is reused across native progress and invalidated by width',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final width = ValueNotifier(500.0);
      addTearDown(width.dispose);
      final session = PlaybackSession(
        id: 'marker-cache-session',
        currentTrackPath: '/track.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      )..setOptimisticDuration(const Duration(minutes: 1));
      addTearDown(session.shutdown);
      final labels = List.generate(
        200,
        (i) => TimeSegmentLabel(
          id: '$i',
          trackKey: '/track.mp3',
          name: 'Label$i',
          start: Duration(milliseconds: (i % 60) * 1000),
          end: Duration(milliseconds: (i % 60) * 1000 + 500),
          colorValue: 0xff336699,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
      await tester.pumpWidget(
        fixture.build(
          Center(
            child: ValueListenableBuilder<double>(
              valueListenable: width,
              builder: (_, size, child) => SizedBox(width: size, child: child),
              child: SessionProgressBar(
                session: PlaybackSessionSnapshot.fromRuntime(session),
                playback: fixture.runtimeGraph.playback,
                paths: fixture.runtimeGraph.audioPaths,
                timeSegmentLabels: labels,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final paint = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString() ==
                '_TimeSegmentProgressPainter',
      );
      final render = tester.renderObject<RenderCustomPaint>(paint);
      final dynamic painter = render.painter;
      expect(painter.debugMarkerLayoutBuilds, 1);
      for (var second = 1; second <= 10; second++) {
        session.applyNativeProgress(
          NativePlaybackProgressUpdate(
            sessionId: session.id,
            position: Duration(seconds: second),
            duration: const Duration(minutes: 1),
            bufferedPosition: Duration(seconds: second + 1),
            nativeElapsedRealtimeMs: second * 1000,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(tester.widget<Slider>(find.byType(Slider)).value, 10000);
      expect(render.painter, same(painter));
      expect(painter.debugMarkerLayoutBuilds, 1);
      width.value = 650;
      await tester.pumpAndSettle();
      expect(render.painter, same(painter));
      expect(painter.debugMarkerLayoutBuilds, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('segment markers preserve overlap parity and clamped geometry', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final session = PlaybackSession(
      id: 'marker-parity-session',
      currentTrackPath: '/track.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(false, ProcessingState.ready),
    )..setOptimisticDuration(const Duration(seconds: 1));
    addTearDown(session.shutdown);
    // The 4/354 ms pair at width 40 exercises subtraction rounding at 14 px.
    const endpoints = [(0, 354), (4, 700), (4, 700), (-100, 1300), (350, 700)];
    final labels = [
      for (var i = 0; i < endpoints.length; i++)
        TimeSegmentLabel(
          id: '$i',
          trackKey: '/track.mp3',
          name: '$i',
          start: Duration(milliseconds: endpoints[i].$1),
          end: Duration(milliseconds: endpoints[i].$2),
          colorValue: 0xff336699,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
    ];
    await tester.pumpWidget(
      fixture.build(
        Center(
          child: SizedBox(
            width: 500,
            child: SessionProgressBar(
              session: PlaybackSessionSnapshot.fromRuntime(session),
              playback: fixture.runtimeGraph.playback,
              paths: fixture.runtimeGraph.audioPaths,
              timeSegmentLabels: labels,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final paint = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.painter.runtimeType.toString() ==
              '_TimeSegmentProgressPainter',
    );
    final dynamic painter = tester
        .renderObject<RenderCustomPaint>(paint)
        .painter;
    for (final width in [40.0, 100.0, 452.0]) {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), Size(width + 48, 40));
      recorder.endRecording().dispose();
      final expected = <({double x, double top})>[];
      for (final label in labels) {
        for (final position in [label.start, label.end]) {
          final x =
              24 + width * (position.inMilliseconds / 1000).clamp(0.0, 1.0);
          final nearby = expected
              .where((marker) => (marker.x - x).abs() < 14)
              .length;
          expected.add((x: x, top: nearby.isOdd ? 7.0 : 0.0));
        }
      }
      expect(painter.debugMarkers, expected, reason: 'track width $width');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (platform, screenSize) in [
    (TargetPlatform.android, const Size(360, 800)),
    (TargetPlatform.android, const Size(800, 360)),
    (TargetPlatform.windows, const Size(800, 360)),
  ]) {
    testWidgets(
      'segment tooltip appears above the progress bar while dragging on ${platform.name} at $screenSize',
      (tester) async {
        tester.view.physicalSize = screenSize;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final session = PlaybackSession(
          id: 'landscape-tooltip-session',
          currentTrackPath: '/library/track.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(false, ProcessingState.ready),
        )..setOptimisticDuration(const Duration(minutes: 1));
        addTearDown(session.shutdown);
        final now = DateTime(2026);
        final label = TimeSegmentLabel(
          id: 'middle',
          trackKey: '/library/track.mp3',
          name: 'Middle section',
          start: const Duration(seconds: 20),
          end: const Duration(seconds: 40),
          colorValue: 0xFF64B5F6,
          createdAt: now,
          updatedAt: now,
        );

        await tester.pumpWidget(
          fixture.build(
            SessionDetailLayout(
              isLandscape: screenSize.width > screenSize.height,
              padding: const EdgeInsets.fromLTRB(8, 40, 8, 8),
              segmentPanelExpanded: false,
              artwork: const SizedBox.shrink(),
              isVideo: false,
              title: 'Track',
              sessionId: session.id,
              progress: SessionProgressBar(
                session: PlaybackSessionSnapshot.fromRuntime(session),
                playback: fixture.runtimeGraph.playback,
                paths: fixture.runtimeGraph.audioPaths,
                timeSegmentLabels: [label],
              ),
              transport: const SizedBox.shrink(),
              subtitle: const SizedBox.shrink(),
              segmentPanelBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        tester.widget<Slider>(find.byType(Slider)).onChangeStart!(30000);
        await tester.pump();

        expect(find.text('Middle section'), findsOneWidget);
        final capsule = find.ancestor(
          of: find.text('Middle section'),
          matching: find.byType(DecoratedBox),
        ).first;
        expect(
          tester.getBottomLeft(capsule).dy,
          lessThan(tester.getTopLeft(find.byType(Slider)).dy),
        );
        expect(
          tester.getTopLeft(capsule).dy,
          greaterThanOrEqualTo(
            tester.getRect(find.byType(SessionDetailLayout)).top,
          ),
        );
        tester.widget<Slider>(find.byType(Slider)).onChanged!(35000);
        await tester.pump();
        expect(find.text('Middle section'), findsOneWidget);
        tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(35000);
        await tester.pump();
        expect(find.text('Middle section'), findsNothing);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'mounted playback card refreshes when the cover generation changes',
    (tester) async {
      final coverCache = _RecordingPlaybackCoverCacheService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: coverCache,
      );
      addTearDown(fixture.dispose);
      final track = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: 'Track 01',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: '/library/work',
        isSingle: false,
        manualCoverPath: '/library/work/embedded.cover',
      );
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final session = PlaybackSession(
        id: 'cover-refresh-session',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.folderSequential,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
        customQueueTracks: <MusicTrack>[track],
      );
      addTearDown(session.shutdown);
      fixture.playbackService.registerSession(session);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        fixture.build(
          ActiveSessionCarousel(
            sessions: <PlaybackSessionSnapshot>[
              PlaybackSessionSnapshot.fromRuntime(session),
            ],
            onOpenSession: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(coverCache.requestedPaths, contains(track.path));
      coverCache.requestedPaths.clear();

      fixture.runtimeGraph.library.invalidateCoverArtwork();
      await tester.pumpAndSettle();

      expect(coverCache.requestedPaths, contains(track.path));
    },
  );

  testWidgets('carousel hides indicator dots in compact presentation', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final session1 = PlaybackSession(
      id: 'session_1',
      currentTrackPath: '/track1.mp3',
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1.0,
      createdAt: DateTime.now(),
      state: const PlayerState(false, ProcessingState.idle),
    );
    final session2 = PlaybackSession(
      id: 'session_2',
      currentTrackPath: '/track2.mp3',
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1.0,
      createdAt: DateTime.now(),
      state: const PlayerState(false, ProcessingState.idle),
    );
    addTearDown(session1.shutdown);
    addTearDown(session2.shutdown);
    final sessions = <PlaybackSessionSnapshot>[
      PlaybackSessionSnapshot.fromRuntime(session1),
      PlaybackSessionSnapshot.fromRuntime(session2),
    ];

    await tester.pumpWidget(
      fixture.build(
        ActiveSessionCarousel(
          sessions: sessions,
          presentation: ActiveSessionCarouselPresentation.compact,
          onOpenSession: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ActiveSessionCarousel),
        matching: find.byType(AnimatedContainer),
      ),
      findsNothing,
    );

    await tester.pumpWidget(
      fixture.build(
        ActiveSessionCarousel(sessions: sessions, onOpenSession: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ActiveSessionCarousel),
        matching: find.byType(AnimatedContainer),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('replaying a session refocuses its card after manual paging', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeSessions = <PlaybackSession>[
      for (final id in ['first', 'second'])
        PlaybackSession(
          id: id,
          currentTrackPath: '/$id.mp3',
          loopMode: SessionLoopMode.folderSequential,
          nonSingleLoopMode: SessionLoopMode.folderSequential,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(false, ProcessingState.ready),
        ),
    ];
    for (final session in runtimeSessions) {
      addTearDown(session.shutdown);
    }
    final sessions = runtimeSessions
        .map(PlaybackSessionSnapshot.fromRuntime)
        .toList(growable: false);
    final visible = <String>[];
    await tester.pumpWidget(
      fixture.build(
        ActiveSessionCarousel(
          sessions: sessions,
          viewportFraction: 1,
          onVisibleSessionChanged: visible.add,
          onOpenSession: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = ProviderScope.containerOf(
      tester.element(find.byType(ActiveSessionCarousel)),
    ).read(playlistUiControllerProvider);

    final pageController = tester
        .widget<PageView>(find.byType(PageView))
        .controller!;
    pageController.jumpToPage(pageController.page!.round() + 1);
    await tester.pumpAndSettle();
    expect(visible.last, 'second');
    controller.requestCarouselSnap('first');
    await tester.pumpAndSettle();
    expect(visible.last, 'first');

    pageController.jumpToPage(pageController.page!.round() + 1);
    await tester.pumpAndSettle();
    expect(visible.last, 'second');
    controller.requestCarouselSnap('first');
    await tester.pumpAndSettle();
    expect(visible.last, 'first');
  });

  testWidgets('carousel starts on the most recently played session', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final sessions = <PlaybackSession>[
      for (final id in ['first', 'latest', 'third'])
        PlaybackSession(
          id: id,
          currentTrackPath: '/$id.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(true, ProcessingState.ready),
        ),
    ];
    for (final session in sessions) {
      addTearDown(session.shutdown);
    }
    sessions[0].lastPlayedAt = DateTime(2026);
    sessions[1].lastPlayedAt = DateTime(2026, 1, 3);
    sessions[2]
      ..lastPlayedAt = DateTime(2026, 1, 4)
      ..state = const PlayerState(false, ProcessingState.ready);
    final visible = <String>[];

    await tester.pumpWidget(
      fixture.build(
        ActiveSessionCarousel(
          sessions: sessions.map(PlaybackSessionSnapshot.fromRuntime).toList(),
          viewportFraction: 1,
          onVisibleSessionChanged: visible.add,
          onOpenSession: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(visible.last, 'latest');
    expect(
      find.byKey(const ValueKey('active_session_card_latest')),
      findsOneWidget,
    );
  });

  testWidgets('new playback takes focus when a second card appears', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final sessions = <PlaybackSession>[
      for (final id in ['first', 'second'])
        PlaybackSession(
          id: id,
          currentTrackPath: '/$id.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(true, ProcessingState.ready),
        ),
    ];
    for (final session in sessions) {
      addTearDown(session.shutdown);
    }
    final visible = <String>[];
    Widget carousel(List<PlaybackSession> shown) => fixture.build(
      ActiveSessionCarousel(
        sessions: shown.map(PlaybackSessionSnapshot.fromRuntime).toList(),
        viewportFraction: 1,
        onVisibleSessionChanged: visible.add,
        onOpenSession: (_) {},
      ),
    );

    await tester.pumpWidget(carousel([sessions.first]));
    await tester.pumpAndSettle();
    final controller = ProviderScope.containerOf(
      tester.element(find.byType(ActiveSessionCarousel)),
    ).read(playlistUiControllerProvider);
    expect(visible.last, 'first');

    controller.requestCarouselSnap('second');
    await tester.pumpWidget(carousel(sessions));
    await tester.pumpAndSettle();

    expect(visible.last, 'second');
  });

  testWidgets(
    'focused pause slides in the left card; other pause keeps focus',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final sessions = <PlaybackSession>[
        for (final id in ['first', 'middle', 'last'])
          PlaybackSession(
            id: id,
            currentTrackPath: '/$id.mp3',
            loopMode: SessionLoopMode.single,
            nonSingleLoopMode: SessionLoopMode.single,
            volume: 1,
            createdAt: DateTime(2026),
            state: const PlayerState(true, ProcessingState.ready),
          ),
      ];
      for (final session in sessions) {
        addTearDown(session.shutdown);
      }
      sessions[1].lastPlayedAt = DateTime(2026, 1, 2);
      final visible = <String>[];

      Widget carousel(List<PlaybackSession> shown) => fixture.build(
        ActiveSessionCarousel(
          sessions: shown.map(PlaybackSessionSnapshot.fromRuntime).toList(),
          viewportFraction: 1,
          onVisibleSessionChanged: visible.add,
          onOpenSession: (_) {},
        ),
      );

      await tester.pumpWidget(carousel(sessions));
      await tester.pumpAndSettle();
      final pageController = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      final startingPage = pageController.page!;
      expect(visible.last, 'middle');

      await tester.pumpWidget(carousel([sessions[0], sessions[2]]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(pageController.page!, lessThan(startingPage));
      expect(pageController.page!, greaterThan(startingPage - 1));
      expect(
        find.byKey(const ValueKey('active_session_card_middle')),
        findsWidgets,
      );

      await tester.pumpAndSettle();
      expect(visible.last, 'first');
      final focusedCard = find.byKey(
        const ValueKey('active_session_card_first'),
      );
      final focusedElement = tester.element(focusedCard.first);
      final focusedPage = pageController.page!;

      await tester.pumpWidget(carousel([sessions[0]]));
      await tester.pumpAndSettle();
      expect(pageController.page, focusedPage);
      expect(tester.element(focusedCard.first), same(focusedElement));
      expect(visible.last, 'first');
    },
  );

  testWidgets(
    'circular cover disables paging and preserves the visible session',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: '/track1.mp3',
            displayName: 'Track 1',
            groupKey: '/work',
            groupTitle: 'Work',
            groupSubtitle: '/work',
            isSingle: false,
            manualCoverPath: '/covers/track1.jpg',
          ),
          MusicTrack(
            path: '/track2.mp3',
            displayName: 'Track 2',
            groupKey: '/work',
            groupTitle: 'Work',
            groupSubtitle: '/work',
            isSingle: false,
            manualCoverPath: '/covers/track2.jpg',
          ),
        ],
        notify: false,
        persist: false,
      );
      final first = PlaybackSession(
        id: 'circular_1',
        currentTrackPath: '/track1.mp3',
        loopMode: SessionLoopMode.folderSequential,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      final second = PlaybackSession(
        id: 'circular_2',
        currentTrackPath: '/track2.mp3',
        loopMode: SessionLoopMode.folderSequential,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(first.shutdown);
      addTearDown(second.shutdown);
      final sessions = [
        PlaybackSessionSnapshot.fromRuntime(first),
        PlaybackSessionSnapshot.fromRuntime(second),
      ];
      final visibleSessions = <String>[];

      Widget carousel(ActiveSessionCarouselPresentation presentation) {
        return fixture.build(
          SizedBox(
            width:
                presentation == ActiveSessionCarouselPresentation.circularCover
                ? kActiveSessionCarouselDockHeight
                : 320,
            child: ActiveSessionCarousel(
              sessions: sessions,
              presentation: presentation,
              viewportFraction: 1,
              onVisibleSessionChanged: visibleSessions.add,
              onOpenSession: (_) {},
            ),
          ),
        );
      }

      await tester.pumpWidget(
        carousel(ActiveSessionCarouselPresentation.circularCover),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PageView), findsNothing);
      expect(
        tester.getSize(
          find.byKey(const ValueKey<String>('active_session_card_circular_1')),
        ),
        const Size.square(56),
      );
      expect(
        tester
            .widgetList<Material>(
              find.descendant(
                of: find.byKey(
                  const ValueKey<String>('active_session_cover_circular_1'),
                ),
                matching: find.byType(Material),
              ),
            )
            .any((material) => material.shape is CircleBorder),
        isTrue,
      );
      expect(visibleSessions.last, 'circular_1');

      await tester.pumpWidget(
        carousel(ActiveSessionCarouselPresentation.embedded),
      );
      await tester.pump();
      await tester.drag(find.byType(PageView), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(visibleSessions.last, 'circular_2');
      final embeddedCard = find.byKey(
        const ValueKey<String>('active_session_card_circular_2'),
      );
      expect(tester.getSize(embeddedCard).height, 56);
      expect(
        tester.getSize(
          find.byKey(const ValueKey<String>('active_session_cover_circular_2')),
        ),
        const Size.square(48),
      );
      expect(
        tester
            .widgetList<InkWell>(
              find.descendant(of: embeddedCard, matching: find.byType(InkWell)),
            )
            .any((inkWell) => inkWell.customBorder is StadiumBorder),
        isTrue,
      );
      expect(
        tester
            .widgetList<Material>(
              find.descendant(
                of: find.byKey(
                  const ValueKey<String>('active_session_cover_circular_2'),
                ),
                matching: find.byType(Material),
              ),
            )
            .any((material) => material.shape is CircleBorder),
        isTrue,
      );

      await tester.pumpWidget(
        carousel(ActiveSessionCarouselPresentation.circularCover),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('active_session_card_circular_2')),
        findsOneWidget,
      );
      await tester.drag(
        find.byKey(const ValueKey<String>('active_session_card_circular_2')),
        const Offset(300, 0),
      );
      await tester.pumpAndSettle();
      expect(visibleSessions.last, 'circular_2');
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'active session card reserves subtitle slot and keeps title layout invariant on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final normalizedPath = PathMatcher.normalize('/library/track_sub.mp3');
        final track = MusicTrack(
          path: normalizedPath,
          displayName: 'Invariant Track Title',
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
        final session = PlaybackSession(
          id: 'session_sub_test',
          currentTrackPath: track.path,
          customQueueTracks: [track],
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 1.0,
          createdAt: DateTime(2026),
          state: const PlayerState(false, ProcessingState.ready),
        )..setOptimisticPosition(Duration.zero);
        addTearDown(session.shutdown);
        fixture.playbackService.registerSession(session);
        fixture.playbackService.syncSlice(
          activeSessions: <PlaybackSession>[session],
          playingSessionCount: 0,
          focusedSessionId: session.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        final subtitleService = PlaybackSubtitleService(
          trackResolver: (_) => track,
          subtitleLoader: (_, _) async => SubtitleTrack(
            sourcePath: 'sub.srt',
            cues: const [
              SubtitleCue(
                start: Duration(seconds: 1),
                end: Duration(seconds: 5),
                text: 'Playing Subtitle Line',
              ),
            ],
          ),
        );
        await subtitleService.load(track.path);

        await tester.pumpWidget(
          fixture.build(
            SizedBox(
              width: 320,
              child: ActiveSessionCarousel(
                sessions: [PlaybackSessionSnapshot.fromRuntime(session)],
                presentation: ActiveSessionCarouselPresentation.embedded,
                onOpenSession: (_) {},
              ),
            ),
            subtitleService: subtitleService,
          ),
        );
        await tester.pumpAndSettle();

        final titleFinder = find.text('Invariant Track Title');
        expect(titleFinder, findsWidgets);
        final titleRectsBefore = [
          for (var i = 0; i < tester.widgetList(titleFinder).length; i++)
            tester.getRect(titleFinder.at(i)),
        ];

        // Subtitle line text should not be visible yet (at 0s, cue is at 1-5s)
        expect(find.text('Playing Subtitle Line'), findsNothing);

        // Advance playback position into the subtitle range
        session.applyNativeProgress(
          NativePlaybackProgressUpdate(
            sessionId: session.id,
            position: const Duration(seconds: 2),
            bufferedPosition: const Duration(seconds: 2),
            nativeElapsedRealtimeMs: 0,
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        // Subtitle line text is now visible
        expect(find.text('Playing Subtitle Line'), findsWidgets);
        final titleRectsWithSubtitle = [
          for (var i = 0; i < tester.widgetList(titleFinder).length; i++)
            tester.getRect(titleFinder.at(i)),
        ];
        expect(titleRectsWithSubtitle, titleRectsBefore);

        // Advance position past the subtitle cue
        session.applyNativeProgress(
          NativePlaybackProgressUpdate(
            sessionId: session.id,
            position: const Duration(seconds: 10),
            bufferedPosition: const Duration(seconds: 10),
            nativeElapsedRealtimeMs: 0,
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('Playing Subtitle Line'), findsNothing);
        final titleRectsAfter = [
          for (var i = 0; i < tester.widgetList(titleFinder).length; i++)
            tester.getRect(titleFinder.at(i)),
        ];
        expect(titleRectsAfter, titleRectsBefore);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  test('equalizer badge only appears while equalizer is enabled', () {
    final disabledIcons = sessionFeatureBadgeIcons(
      showSubtitles: false,
      channelSwapEnabled: false,
      audioEffects: AudioEffectsState(eqPresetId: 'voice_clear'),
      speed: 1,
    );
    final enabledIcons = sessionFeatureBadgeIcons(
      showSubtitles: false,
      channelSwapEnabled: false,
      audioEffects: AudioEffectsState(eqEnabled: true),
      speed: 1,
    );

    expect(disabledIcons, isNot(contains(Icons.tune_rounded)));
    expect(enabledIcons, contains(Icons.tune_rounded));
  });

  test('fullscreen video follows adjacent video tracks', () {
    expect(
      shouldKeepSessionVideoFullscreen(
        sessionExists: true,
        currentTrackIsVideo: true,
      ),
      isTrue,
    );
    expect(
      shouldKeepSessionVideoFullscreen(
        sessionExists: true,
        currentTrackIsVideo: false,
      ),
      isFalse,
    );
    expect(
      shouldKeepSessionVideoFullscreen(
        sessionExists: false,
        currentTrackIsVideo: true,
      ),
      isFalse,
    );
  });

  test('session volume display scale preserves unity and compresses boost', () {
    expect(sessionVolumeDisplayValueFromGain(0), 0);
    expect(sessionVolumeDisplayValueFromGain(1), 1);
    expect(sessionVolumeDisplayValueFromGain(2), 1.25);
    expect(sessionVolumeDisplayValueFromGain(3), 1.5);
    expect(sessionVolumeDisplayValueFromGain(4), 1.5);

    expect(sessionVolumeGainFromDisplayValue(0), 0);
    expect(sessionVolumeGainFromDisplayValue(1), 1);
    expect(sessionVolumeGainFromDisplayValue(1.25), 2);
    expect(sessionVolumeGainFromDisplayValue(1.5), 3);
    expect(sessionVolumeGainFromDisplayValue(2), 3);

    final gestureDisplayValue = sessionVideoVerticalGestureValue(
      startValue: 1,
      dragDy: -500,
      viewportHeight: 500,
      minimum: 0,
      maximum: sessionVolumeDisplayMaximum,
    );
    expect(gestureDisplayValue, 1.5);
    expect(sessionVolumeGainFromDisplayValue(gestureDisplayValue), 3);
  });

  test('ASMR session switcher displays tracks in natural path order', () {
    MusicTrack asmrTrack(String title) {
      final relativePath = '01/$title.mp3';
      return MusicTrack(
        path: 'https://example.test/$relativePath',
        displayName: title,
        groupKey: 'asmr-work-1',
        groupTitle: 'Work',
        groupSubtitle: 'RJ000001',
        isSingle: false,
        remoteMetadataKind: 'asmr.one',
        remoteMetadata: <String, Object?>{'trackRelativePath': relativePath},
      );
    }

    const sortedTitles = <String>[
      'トラック１',
      'トラック２',
      'トラック３',
      'トラック４',
      'トラック５',
      'トラック６',
      'トラック７',
      'トラック８',
      'トラック９',
      'トラック１０',
      'トラック１１',
    ];
    final rotated = <MusicTrack>[
      asmrTrack(sortedTitles[9]),
      asmrTrack(sortedTitles[10]),
      ...sortedTitles.skip(1).take(8).map(asmrTrack),
      asmrTrack(sortedTitles[0]),
    ];

    final ordered = orderTracksForSessionSwitcher(
      rotated,
      preserveQueueOrder: false,
    );

    expect(ordered.map((track) => track.displayName), sortedTitles);
    expect(
      orderTracksForSessionSwitcher(rotated, preserveQueueOrder: true),
      same(rotated),
    );
  });

  test('ASMR session switcher restores selection from stable metadata', () {
    MusicTrack asmrTrack(String url, String relativePath) => MusicTrack(
      path: url,
      displayName: 'Track',
      groupKey: 'asmr-work-42',
      groupTitle: 'Work',
      groupSubtitle: 'RJ000042',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: <String, Object?>{
        'id': 42,
        'trackRelativePath': relativePath,
      },
    );

    final queued = asmrTrack(
      'https://old.example/audio.mp3?token=old',
      r'mp3\01.mp3',
    );
    final refreshed = asmrTrack(
      'https://new.example/audio.mp3?token=new',
      'mp3/01.mp3',
    );
    final exactPathTrack = asmrTrack(
      'https://new.example/audio-02.mp3?token=new',
      'mp3/02.mp3',
    );

    expect(
      resolveSessionSwitcherSelectedTrack(
        displayedTracks: <MusicTrack>[refreshed],
        queueTracks: <MusicTrack>[queued],
        currentPath: queued.path,
        currentQueueIndex: 0,
      ),
      same(refreshed),
    );
    expect(
      resolveSessionSwitcherSelectedTrack(
        displayedTracks: <MusicTrack>[refreshed, exactPathTrack],
        queueTracks: <MusicTrack>[queued, exactPathTrack],
        currentPath: exactPathTrack.path,
        currentQueueIndex: 0,
      ),
      same(exactPathTrack),
    );
  });

  testWidgets('active track path provider exposes current session paths', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();

    final active = PlaybackSession(
      id: 'active',
      currentTrackPath: '/tracks/active.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(false, ProcessingState.ready),
    );
    final empty = PlaybackSession(
      id: 'empty',
      currentTrackPath: '',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(false, ProcessingState.ready),
    );

    fixture.playbackService
      ..registerSession(active)
      ..registerSession(empty);
    fixture.playbackService.syncSlice(
      activeSessions: [active, empty],
      playingSessionCount: 0,
      focusedSessionId: null,
      coverGeneration: 0,
      isInitialized: true,
    );

    final container = ProviderContainer(
      overrides: [playbackFacadeProvider.overrideWithValue(fixture.playback)],
    );

    final paths = container.read(activeTrackPathsProvider);

    expect(paths.contains('/tracks/active.mp3'), isTrue);
    expect(paths.contains(''), isFalse);
    expect(container.read(isTrackActiveProvider('/tracks/active.mp3')), isTrue);
    expect(container.read(isTrackActiveProvider('/tracks/other.mp3')), isFalse);

    final activeChanges = <bool>[];
    final activeSubscription = container.listen(
      isTrackActiveProvider('/tracks/active.mp3'),
      (_, next) => activeChanges.add(next),
    );
    await tester.pump();
    active.state = const PlayerState(true, ProcessingState.ready);
    fixture.playbackService.syncSlice(
      activeSessions: [active, empty],
      playingSessionCount: 1,
      focusedSessionId: active.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pumpAndSettle();
    expect(container.read(isTrackActiveProvider('/tracks/active.mp3')), isTrue);
    expect(activeChanges, isEmpty);

    active.currentTrackPath = '/tracks/other.mp3';
    fixture.playbackService.syncSlice(
      activeSessions: [active, empty],
      playingSessionCount: 1,
      focusedSessionId: active.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pumpAndSettle();
    expect(
      container.read(activeTrackPathsProvider).paths,
      contains('/tracks/other.mp3'),
    );
    expect(
      container.read(isTrackActiveProvider('/tracks/active.mp3')),
      isFalse,
    );
    expect(activeChanges, [false]);
    expect(container.read(isTrackActiveProvider('/tracks/other.mp3')), isTrue);

    activeSubscription.close();
    container.dispose();
    await tester.runAsync(() async {
      await active.shutdown();
      await empty.shutdown();
    });
    fixture.dispose();
    await tester.pump();
  });

  testWidgets('horizontal drag does not switch the detail session', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final tracks = <MusicTrack>[
      testMusicTrack(
        name: 'First session track',
        path: '/library/first.mp3',
        groupKey: '/library/first',
        groupTitle: 'First work',
      ),
      testMusicTrack(
        name: 'Second session track',
        path: '/library/second.mp3',
        groupKey: '/library/second',
        groupTitle: 'Second work',
      ),
    ];
    fixture.runtimeGraph.library.addTracks(
      tracks,
      notify: false,
      persist: false,
    );
    final sessions = <PlaybackSession>[
      for (final track in tracks)
        fixture.runtimeGraph.playback.createTrackSession(track),
    ];
    for (final s in sessions) {
      addTearDown(s.shutdown);
    }
    final subtitleLoads = <String>[];
    final firstSubtitle = SubtitleTrack(
      sourcePath: '/library/first.srt',
      cues: <SubtitleCue>[
        const SubtitleCue(
          start: Duration.zero,
          end: Duration(seconds: 5),
          text: 'First session subtitle',
        ),
      ],
    );
    final subtitleService = PlaybackSubtitleService(
      trackResolver: (path) => fixture.library.trackByPath(path),
      subtitleLoader: (path, _) async {
        subtitleLoads.add(path);
        return path == tracks.first.path ? firstSubtitle : null;
      },
    );
    fixture.playbackService.syncSlice(
      activeSessions: sessions,
      playingSessionCount: 0,
      focusedSessionId: sessions.first.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      fixture.build(const PlaylistTab(), subtitleService: subtitleService),
    );
    await tester.pumpAndSettle();
    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: sessions.first.id)),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    subtitleLoads.clear();

    await tester.drag(find.byType(SessionDetailPage), const Offset(-120, 0));
    await tester.pumpAndSettle();

    expect(subtitleLoads, isNot(contains(tracks.last.path)));
    expect(
      find.byKey(ValueKey<String>('progress_${sessions.first.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('progress_${sessions.last.id}')),
      findsNothing,
    );
    expect(find.text(tracks.first.displayName), findsOneWidget);
    expect(find.text(tracks.last.displayName), findsNothing);

    if (find.byType(SessionDetailPage).evaluate().isNotEmpty) {
      Navigator.of(tester.element(find.byType(SessionDetailPage))).pop();
      await tester.pumpAndSettle();
    }
    UiInteractionCoordinator.instance.resetForTest();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets(
    'session detail forward 5s and replay 5s seek relative to live position',
    (WidgetTester tester) async {
      final pumped = await _pumpSubtitleDetail(
        tester: tester,
        initialPosition: const Duration(seconds: 30),
        subtitleTrack: SubtitleTrack(
          sourcePath: '/library/subtitles/track.vtt',
          cues: const <SubtitleCue>[],
        ),
      );

      final forwardButton = find.ancestor(
        of: find.byIcon(Icons.forward_5_rounded),
        matching: find.byType(IconButton),
      );
      final replayButton = find.ancestor(
        of: find.byIcon(Icons.replay_5_rounded),
        matching: find.byType(IconButton),
      );
      expect(forwardButton, findsOneWidget);
      expect(replayButton, findsOneWidget);

      await tester.tap(forwardButton);
      await tester.pumpAndSettle();
      expect(pumped.session.position, const Duration(seconds: 35));

      await tester.tap(replayButton);
      await tester.pumpAndSettle();
      expect(pumped.session.position, const Duration(seconds: 30));

      if (find.byType(SessionDetailPage).evaluate().isNotEmpty) {
        Navigator.of(tester.element(find.byType(SessionDetailPage))).pop();
        await tester.pumpAndSettle();
      }
      UiInteractionCoordinator.instance.resetForTest();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('playlist first open fades its card skeleton out over 300ms', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    fixture.playbackService.syncSlice(
      activeSessions: const <PlaybackSession>[],
      playingSessionCount: 0,
      focusedSessionId: null,
      coverGeneration: 0,
      isInitialized: true,
    );

    tester.view.padding = const FakeViewPadding(top: 40);
    tester.view.viewPadding = const FakeViewPadding(top: 40);
    addTearDown(() {
      tester.view.padding = FakeViewPadding.zero;
      tester.view.viewPadding = FakeViewPadding.zero;
    });
    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: fixture.runtimeGraph,
        persistenceRepository: fixture.persistenceRepository,
        nativePlaybackRepository: fixture.nativePlaybackRepository,
        playbackCommandRunner:
            AppRuntimeWidgetTestFixture.playbackCommandRunner,
        libraryService: fixture.libraryService,
        playbackService: fixture.playbackService,
        timerService: fixture.timerService,
        notificationCoordinatorService: fixture.notificationCoordinatorService,
        settingsRepository: fixture.settings,
        languageProvider: fixture.languageProvider,
        child: const PlaylistTab(),
      ),
    );

    const placeholderKey = ValueKey<String>('playlist_initial_placeholder');
    const contentKey = ValueKey<String>('playlist_loaded_content');
    expect(
      tester.widget<TopPageHeader>(find.byType(TopPageHeader)).bottomSpacing,
      4,
    );
    expect(
      tester
          .widget<TopPageHeader>(find.byType(TopPageHeader))
          .collapseController,
      isNotNull,
    );
    expect(find.byKey(placeholderKey), findsOneWidget);
    expect(find.byKey(contentKey), findsNothing);

    final skeletonCards = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('playlist_skeleton_card_');
    });
    expect(skeletonCards, findsAtLeastNWidgets(1));
    final firstSkeleton = tester.widget<Container>(skeletonCards.first);
    expect(firstSkeleton.padding, playlistRowPadding);
    expect(
      firstSkeleton.decoration,
      isNull,
      reason: 'Playlist loading rows should blend into the page background.',
    );
    final firstSkeletonCover = find
        .descendant(
          of: skeletonCards.first,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.constraints ==
                    const BoxConstraints.tightFor(
                      width: playlistCoverSize,
                      height: playlistCoverSize,
                    ),
          ),
        )
        .first;
    expect(tester.getSize(firstSkeletonCover), const Size.square(52));
    final skeletonTrailingCircles = find.descendant(
      of: skeletonCards.first,
      matching: find.byWidgetPredicate((widget) {
        return widget is Container &&
            widget != tester.widget(firstSkeletonCover) &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).shape == BoxShape.circle;
      }),
    );
    expect(skeletonTrailingCircles, findsOneWidget);
    expect(tester.getSize(skeletonTrailingCircles), const Size.square(36));
    final initialSkeletonCardTop = tester.getTopLeft(skeletonCards.first).dy;
    expect(
      initialSkeletonCardTop,
      greaterThanOrEqualTo(tester.getBottomLeft(find.byType(TopPageHeader)).dy),
    );
    expect(
      tester.getBottomLeft(skeletonCards.last).dy,
      greaterThan(initialSkeletonCardTop),
    );

    await tester.pump();
    expect(
      tester.getTopLeft(skeletonCards.first).dy,
      closeTo(initialSkeletonCardTop, 0.01),
    );
    expect(find.byKey(placeholderKey), findsOneWidget);
    expect(find.byKey(contentKey), findsOneWidget);

    await tester.pump(
      kPlaceholderContentTransitionDuration - const Duration(milliseconds: 1),
    );
    expect(find.byKey(placeholderKey), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.byKey(placeholderKey), findsNothing);
    expect(find.byKey(contentKey), findsOneWidget);
  });

  testWidgets(
    'playlist first open without view padding renders skeleton flush under header without twitch',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.playbackService.syncSlice(
        activeSessions: const <PlaybackSession>[],
        playingSessionCount: 0,
        focusedSessionId: null,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: fixture.runtimeGraph,
          persistenceRepository: fixture.persistenceRepository,
          nativePlaybackRepository: fixture.nativePlaybackRepository,
          playbackCommandRunner:
              AppRuntimeWidgetTestFixture.playbackCommandRunner,
          libraryService: fixture.libraryService,
          playbackService: fixture.playbackService,
          timerService: fixture.timerService,
          notificationCoordinatorService:
              fixture.notificationCoordinatorService,
          settingsRepository: fixture.settings,
          languageProvider: fixture.languageProvider,
          child: const PlaylistTab(),
        ),
      );

      final skeletonCards = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('playlist_skeleton_card_');
      });
      expect(skeletonCards, findsAtLeastNWidgets(1));
      final initialTop = tester.getTopLeft(skeletonCards.first).dy;
      expect(
        initialTop,
        greaterThanOrEqualTo(
          tester.getBottomLeft(find.byType(TopPageHeader)).dy,
        ),
      );

      await tester.pump();
      expect(
        tester.getTopLeft(skeletonCards.first).dy,
        closeTo(initialTop, 0.01),
      );
    },
  );

  testWidgets(
    'playlist skeleton play button placeholder matches actual card play button center',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = testMusicTrack(
        name: 'Alignment track',
        path: '/library/alignment/track.mp3',
        groupKey: '/library/alignment',
        groupTitle: 'Alignment',
      );
      final session = PlaybackSession(
        id: 'alignment-session',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(session.shutdown);
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      fixture.playbackService.registerSession(session);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: fixture.runtimeGraph,
          persistenceRepository: fixture.persistenceRepository,
          nativePlaybackRepository: fixture.nativePlaybackRepository,
          playbackCommandRunner:
              AppRuntimeWidgetTestFixture.playbackCommandRunner,
          libraryService: fixture.libraryService,
          playbackService: fixture.playbackService,
          timerService: fixture.timerService,
          notificationCoordinatorService:
              fixture.notificationCoordinatorService,
          settingsRepository: fixture.settings,
          languageProvider: fixture.languageProvider,
          child: const PlaylistTab(),
        ),
      );

      final skeletonCards = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('playlist_skeleton_card_');
      });
      expect(skeletonCards, findsAtLeastNWidgets(1));
      final skeletonTrailingCircle = find.descendant(
        of: skeletonCards.first,
        matching: find.byWidgetPredicate((widget) {
          return widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration! as BoxDecoration).shape == BoxShape.circle &&
              widget !=
                  tester.widget(
                    find
                        .descendant(
                          of: skeletonCards.first,
                          matching: find.byWidgetPredicate(
                            (w) =>
                                w is Container &&
                                w.constraints ==
                                    const BoxConstraints.tightFor(
                                      width: playlistCoverSize,
                                      height: playlistCoverSize,
                                    ),
                          ),
                        )
                        .first,
                  );
        }),
      );
      expect(skeletonTrailingCircle, findsOneWidget);
      final skeletonCenter = tester.getCenter(skeletonTrailingCircle);

      // Dismiss the skeleton so the actual session card appears
      await tester.pump();
      await tester.pump(kPlaceholderContentTransitionDuration);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      final actualCard = find.byType(SessionListCard);
      expect(actualCard, findsOneWidget);
      final playButton = find.descendant(
        of: actualCard,
        matching: find.byType(IconButton),
      );
      expect(playButton, findsOneWidget);
      final actualCenter = tester.getCenter(playButton);

      expect(skeletonCenter.dx, closeTo(actualCenter.dx, 0.01));
      expect(skeletonCenter.dy, closeTo(actualCenter.dy, 0.01));
    },
  );

  testWidgets('expanded console consumes the downward detail dismiss gesture', (
    tester,
  ) async {
    final pumped = await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: SubtitleTrack(
        sourcePath: '/library/subtitles/track.vtt',
        cues: <SubtitleCue>[],
      ),
      initialPosition: Duration.zero,
      physicalSize: const Size(1290, 2700),
    );

    await tester.tap(
      find.byTooltip(pumped.fixture.languageProvider.tr('audio_features')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('playback_expanded_control_panel')),
      findsOneWidget,
    );

    await tester.drag(find.byType(SessionDetailPage), const Offset(0, 220));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('playback_expanded_control_panel')),
      findsOneWidget,
    );
    expect(find.byType(SessionDetailPage), findsOneWidget);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'console pages switch directly in 300 ms on $platform',
      (tester) async {
        final pumped = await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.vtt', cues: []),
          initialPosition: Duration.zero,
          physicalSize: platform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1290, 2700),
        );
        final i18n = pumped.fixture.languageProvider;
        await tester.tap(find.byTooltip(i18n.tr('audio_features')));
        await tester.pumpAndSettle();
        final stack = find.byKey(const ValueKey('playback_console_page_stack'));
        final header = find.byType(SegmentPanelPageHeader);
        final speed = find.byType(SpeedWheelPage, skipOffstage: false);
        final speedState = tester.state(speed);
        final speedWidget = tester.widget(speed);
        expect(
          tester.widget<AppFadeThroughIndexedStack>(stack).duration,
          const Duration(milliseconds: 300),
        );
        expect(find.byType(EqualizerPage, skipOffstage: false), findsNothing);
        expect(
          find.byType(AudioFeaturesPage, skipOffstage: false),
          findsNothing,
        );

        Offset translation(int index) => tester
            .widget<FractionalTranslation>(
              find
                  .descendant(
                    of: find.descendant(
                      of: stack,
                      matching: find.byKey(ValueKey('app_indexed_page_$index')),
                    ),
                    matching: find.byType(FractionalTranslation),
                  )
                  .first,
            )
            .translation;

        bool excludesSemantics(Finder page) {
          var excluding = false;
          tester.element(page).visitAncestorElements((element) {
            final widget = element.widget;
            if (widget is ExcludeSemantics) {
              excluding = widget.excluding;
              return false;
            }
            return true;
          });
          return excluding;
        }

        await tester.tap(find.text(i18n.tr('equalizer')));
        await tester.pump();
        final equalizer = find.byType(EqualizerPage);
        final equalizerWidget = tester.widget(equalizer);
        expect(translation(0).dx, -1);
        expect(excludesSemantics(equalizer), isTrue);
        expect(excludesSemantics(speed), isTrue);
        expect(
          find.byType(AudioFeaturesPage, skipOffstage: false),
          findsNothing,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(translation(0).dx, allOf(greaterThan(-1), lessThan(0)));
        expect(tester.widget(equalizer), same(equalizerWidget));
        expect(tester.widget(speed), same(speedWidget));
        await tester.pump(const Duration(milliseconds: 149));
        expect(excludesSemantics(equalizer), isTrue);
        await tester.pump(const Duration(milliseconds: 2));
        expect(translation(0), Offset.zero);
        expect(excludesSemantics(equalizer), isFalse);
        expect(TickerMode.valuesOf(tester.element(speed)).enabled, isFalse);

        tester.widget<SegmentPanelPageHeader>(header).onSelected(2);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(excludesSemantics(speed), isTrue);
        await tester.pump(const Duration(milliseconds: 151));
        expect(translation(2), Offset.zero);
        expect(tester.state(speed), same(speedState));
        expect(excludesSemantics(speed), isFalse);

        tester.widget<SegmentPanelPageHeader>(header).onSelected(0);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        tester.widget<SegmentPanelPageHeader>(header).onSelected(4);
        await tester.pumpAndSettle();
        expect(find.byType(VolumeBalancePage), findsOneWidget);
        expect(tester.widget<SegmentPanelPageHeader>(header).pageIndex, 4);
        expect(
          find.byType(AudioFeaturesPage, skipOffstage: false),
          findsNothing,
        );
        expect(find.byTooltip(i18n.tr('segment_add')), findsNothing);

        if (platform == TargetPlatform.windows) {
          final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
          await tester.sendEventToBinding(
            pointer.hover(tester.getCenter(stack)),
          );
          await tester.sendEventToBinding(pointer.scroll(const Offset(0, -40)));
        } else {
          await tester.dragFrom(
            tester.getTopLeft(stack) + const Offset(100, 60),
            const Offset(160, 0),
          );
        }
        await tester.pumpAndSettle();
        expect(tester.widget<SegmentPanelPageHeader>(header).pageIndex, 3);
        expect(find.byTooltip(i18n.tr('segment_add')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'console pages respect reduced motion on $platform',
      (tester) async {
        final nameController = TextEditingController();
        addTearDown(nameController.dispose);
        await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.vtt', cues: []),
          initialPosition: Duration.zero,
          detailBuilder: (session) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: TimeSegmentPanel(
                session: session,
                playback: ProviderScope.containerOf(
                  context,
                ).read(playbackFacadeProvider),
                labels: const [],
                selectedId: null,
                showEditor: false,
                loading: false,
                nameController: nameController,
                draftStart: null,
                draftEnd: null,
                draftColorValue: null,
                loopSegmentId: null,
                onSelect: (_) {},
                onAdd: () {},
                onSetStart: () {},
                onSetEnd: () {},
                onEditStart: () {},
                onEditEnd: () {},
                onDelete: () {},
                onToggleLoop: () {},
                onClose: () {},
              ),
            ),
          ),
        );
        final header = find.byType(SegmentPanelPageHeader);
        tester.widget<SegmentPanelPageHeader>(header).onSelected(0);
        await tester.pump();
        expect(find.byType(EqualizerPage), findsOneWidget);
        expect(find.byType(SpeedWheelPage), findsNothing);
        expect(
          TickerMode.valuesOf(
            tester.element(find.byType(EqualizerPage)),
          ).enabled,
          isTrue,
        );
        tester.widget<SegmentPanelPageHeader>(header).onSelected(2);
        await tester.pump();
        expect(find.byType(SpeedWheelPage), findsOneWidget);
        expect(find.byType(EqualizerPage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('session reset actions share style and disable at defaults', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const nativePlaybackChannel = MethodChannel(NativePlaybackChannel.name);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          nativePlaybackChannel,
          (_) async => <String, Object?>{'ok': true, 'value': null},
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, null);
    });

    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;
    final track = testMusicTrack(
      name: 'Balance track',
      path: '/library/balance/track.mp3',
      groupKey: '/library/balance',
      groupTitle: 'Balance',
    );
    final session = PlaybackSession(
      id: 'balance-session',
      currentTrackPath: track.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(false, ProcessingState.ready),
    )..audioEffects = AudioEffectsState.flat.copyWith(panning: 0.6);
    addTearDown(session.shutdown);
    runtimeGraph.library.addTracks(
      <MusicTrack>[track],
      notify: false,
      persist: false,
    );
    playbackService.registerSession(session);
    playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        undoableRemovalService: fixture.undoableRemovalService,
        child: const PlaylistTab(),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: session.id)),
    );
    await tester.pumpAndSettle();
    final artwork = find.byKey(ValueKey<String>('artwork_${session.id}'));
    const expandedPanel = ValueKey<String>('playback_expanded_control_panel');
    expect(artwork, findsOneWidget);
    expect(find.byKey(expandedPanel), findsNothing);

    await tester.tap(find.byTooltip(languageProvider.tr('audio_features')));
    await tester.pumpAndSettle();
    expect(artwork, findsNothing);
    final panelSurface = find.byKey(
      const ValueKey<String>('playback_expanded_control_panel_surface'),
    );
    final panelDecoration =
        tester.widget<DecoratedBox>(panelSurface).decoration as BoxDecoration;
    expect(panelDecoration.color, isNotNull);
    expect(panelDecoration.border, isNotNull);
    expect(tester.getSize(find.byKey(expandedPanel)).width, 398);
    expect(
      panelDecoration.borderRadius,
      const BorderRadius.only(
        topLeft: Radius.circular(19),
        topRight: Radius.circular(19),
        bottomLeft: Radius.circular(16),
        bottomRight: Radius.circular(16),
      ),
    );
    expect(find.byType(SessionSubtitlePanel), findsOneWidget);
    expect(
      tester.getSize(find.byType(SessionSubtitlePanel)).height,
      greaterThan(0),
    );
    expect(tester.getSize(find.byKey(expandedPanel)).height, closeTo(486, 1));
    expect(
      tester.getRect(find.byKey(expandedPanel)).top,
      closeTo(tester.getRect(find.byKey(const ValueKey('controls'))).bottom, 1),
    );
    expect(
      tester.getRect(find.byKey(expandedPanel)).bottom,
      closeTo(tester.getRect(find.byType(SessionDetailContent)).bottom - 8, 1),
    );

    final closeButtonFinder = find.byKey(
      const ValueKey<String>('close_console_panel'),
    );
    expect(closeButtonFinder, findsOneWidget);
    final header = find.byType(SegmentPanelPageHeader);
    final capsule = find.descendant(
      of: header,
      matching: find.byType(HeaderFloatingSurface),
    );
    expect(capsule, findsOneWidget);
    final capsuleWidget = tester.widget<HeaderFloatingSurface>(capsule);
    expect(capsuleWidget.radius, 19);
    expect(capsuleWidget.height, 38);
    final capsuleFill = tester.widget<Material>(
      find.descendant(of: capsule, matching: find.byType(Material)).first,
    );
    expect(capsuleFill.color, Colors.transparent);
    final panelRect = tester.getRect(panelSurface);
    final capsuleRect = tester.getRect(capsule);
    expect(panelRect.contains(tester.getCenter(closeButtonFinder)), isTrue);
    expect(panelRect.contains(capsuleRect.center), isTrue);
    expect(
      tester.getRect(find.byKey(expandedPanel)).contains(capsuleRect.center),
      isTrue,
    );
    expect(capsuleRect.top, closeTo(panelRect.top, 1));
    expect(capsuleRect.left, closeTo(panelRect.left, 1));
    expect(capsuleRect.right, closeTo(panelRect.right, 1));
    final tabScrollClip = tester.widget<ClipRRect>(
      find.byKey(const ValueKey<String>('console_tab_scroll_clip')),
    );
    expect(
      tabScrollClip.borderRadius,
      BorderRadius.circular(19),
    );
    final tabListView = tester.widget<ListView>(
      find.descendant(of: header, matching: find.byType(ListView)),
    );
    expect(tabListView.physics, isA<ClampingScrollPhysics>());
    final tabTaps = find.descendant(of: header, matching: find.byType(InkWell));
    expect(tabTaps, findsNWidgets(6));
    expect(
      tester.widget<InkWell>(tabTaps.at(0)).borderRadius,
      BorderRadius.circular(15),
    );
    final firstTabRect = tester.getRect(tabTaps.at(0));
    final secondTabRect = tester.getRect(tabTaps.at(1));
    await tester.tapAt(capsuleRect.topLeft + const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentPanelPageHeader>(header).pageIndex, 2);
    await tester.tapAt(
      Offset(
        (firstTabRect.right + secondTabRect.left) / 2,
        firstTabRect.center.dy,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentPanelPageHeader>(header).pageIndex, 2);
    expect(
      tester.getCenter(closeButtonFinder).dx,
      greaterThan(tester.getCenter(find.byKey(expandedPanel)).dx),
    );
    expect(
      tester.getTopLeft(closeButtonFinder).dx,
      greaterThan(
        tester.getTopRight(find.text(languageProvider.tr('equalizer'))).dx,
      ),
    );
    await tester.tap(closeButtonFinder);
    await tester.pumpAndSettle();
    expect(artwork, findsOneWidget);
    expect(find.byKey(expandedPanel), findsNothing);
    await tester.tap(find.byTooltip(languageProvider.tr('audio_features')));
    await tester.pumpAndSettle();

    const portraitDividerKey = ValueKey<String>('portrait_console_divider');
    expect(find.byKey(portraitDividerKey), findsNothing);
    tester.view.physicalSize = const Size(900, 430);
    await tester.pumpAndSettle();
    expect(find.byKey(portraitDividerKey), findsNothing);
    tester.view.physicalSize = const Size(430, 900);
    await tester.pumpAndSettle();

    expect(find.text(formatSpeedValue(1.0)), findsNWidgets(2));
    final speedRestoreButton = find.byKey(
      const ValueKey<String>('restore_playback_speed'),
    );
    _expectThemeSessionResetButtonStyle(tester, speedRestoreButton);
    expect(
      tester.getSize(speedRestoreButton).width,
      closeTo(tester.getSize(find.byKey(expandedPanel)).width - 32, 1),
    );
    expect(tester.widget<FilledButton>(speedRestoreButton).onPressed, isNull);

    await tester.tap(find.text(languageProvider.tr('equalizer')));
    await tester.pumpAndSettle();
    final equalizerList = find.descendant(
      of: find.byType(EqualizerPage),
      matching: find.byType(ListView),
    );
    expect(tester.getRect(equalizerList).top, closeTo(panelRect.top, 1));
    expect(
      find.descendant(
        of: find.byKey(expandedPanel),
        matching: find.byType(DragOnlyScrollbar),
      ),
      findsNothing,
    );
    final equalizerResetButton = find.byKey(
      const ValueKey<String>('reset_equalizer'),
    );
    final saveEqualizerPresetButton = find.byKey(
      const ValueKey<String>('save_equalizer_preset'),
    );
    _expectThemeSessionResetButtonStyle(tester, equalizerResetButton);
    _expectThemeSessionResetButtonStyle(tester, saveEqualizerPresetButton);
    final resetRect = tester.getRect(equalizerResetButton);
    final saveRect = tester.getRect(saveEqualizerPresetButton);
    expect(resetRect.width, closeTo(saveRect.width, 1));
    expect(saveRect.left - resetRect.right, closeTo(10, 1));
    expect(
      resetRect.width + saveRect.width + 10,
      closeTo(tester.getSize(find.byKey(expandedPanel)).width - 32, 1),
    );
    expect(tester.widget<FilledButton>(equalizerResetButton).onPressed, isNull);
    expect(
      tester.widget<FilledButton>(saveEqualizerPresetButton).onPressed,
      isNull,
    );

    unawaited(
      runtimeGraph.playback.applySessionEqPreset(
        session.id,
        builtInEqPresets[1],
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(equalizerResetButton).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<FilledButton>(saveEqualizerPresetButton).onPressed,
      isNotNull,
    );

    await tester.tap(equalizerResetButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(equalizerResetButton).onPressed, isNull);
    expect(
      tester.widget<FilledButton>(saveEqualizerPresetButton).onPressed,
      isNull,
    );

    // Save and delete a custom EQ preset
    runtimeGraph.settings.customEqPresets = [
      EqPreset(
        id: 'custom_test_1',
        labelKey: 'MyCustomPreset',
        bandLevels: const <int, double>{60: 2.0},
      ),
    ];
    runtimeGraph.settings.syncSlice();
    await tester.pumpAndSettle();
    final customPreset = runtimeGraph.settings.customEqPresets.first;
    unawaited(
      runtimeGraph.playback.applySessionEqPreset(session.id, customPreset),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    final deleteEqualizerPresetButton = find.byKey(
      const ValueKey<String>('delete_equalizer_preset'),
    );
    expect(deleteEqualizerPresetButton, findsOneWidget);
    expect(find.text(languageProvider.tr('eq_delete_preset')), findsOneWidget);

    await tester.tap(deleteEqualizerPresetButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('delete_equalizer_preset')), findsNothing);
    expect(find.byKey(const ValueKey('save_equalizer_preset')), findsOneWidget);
    expect(runtimeGraph.settings.customEqPresets, contains(customPreset));
    expect(session.audioEffects.eqPresetId, customPreset.id);
    expect(session.audioEffects.eqBandLevels, customPreset.bandLevels);
    final presetDropdown = find.descendant(
      of: find.byType(EqualizerPage),
      matching: find.byType(DropdownButtonFormField<String>),
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(presetDropdown)
          .initialValue,
      isNull,
    );

    await tester.tap(find.textContaining(languageProvider.tr('undo')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(runtimeGraph.settings.customEqPresets, contains(customPreset));
    expect(session.audioEffects.eqPresetId, customPreset.id);
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(EqualizerPage)),
      ).read(undoableRemovalServiceProvider).state.hiddenKeys,
      isEmpty,
    );
    expect(deleteEqualizerPresetButton, findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(presetDropdown)
          .initialValue,
      customPreset.id,
    );

    await tester.tap(find.text(languageProvider.tr('volume_balance')));
    await tester.pumpAndSettle();

    final restoreButton = find.byKey(
      const ValueKey<String>('restore_volume_balance'),
    );
    _expectThemeSessionResetButtonStyle(tester, restoreButton);
    expect(
      tester.getSize(restoreButton).width,
      closeTo(tester.getSize(find.byKey(expandedPanel)).width - 80, 1),
    );
    expect(tester.widget<FilledButton>(restoreButton).onPressed, isNotNull);
    expect(find.text(languageProvider.tr('restore_default')), findsOneWidget);
    await tester.tap(restoreButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(session.audioEffects.panning, 0.0);
    expect(tester.widget<FilledButton>(restoreButton).onPressed, isNull);
  });

  testWidgets(
    'time segment endpoints use live position and save localized default label',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const nativePlaybackChannel = MethodChannel(NativePlaybackChannel.name);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            nativePlaybackChannel,
            (_) async => <String, Object?>{'ok': true, 'value': null},
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, null);
      });

      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = testMusicTrack(
        name: 'Segment track',
        path: '/library/segments/live-position.mp3',
        groupKey: '/library/segments',
        groupTitle: 'Segments',
      );
      final session =
          PlaybackSession(
              id: 'segment-live-position-session',
              currentTrackPath: track.path,
              loopMode: SessionLoopMode.single,
              nonSingleLoopMode: SessionLoopMode.single,
              volume: 1,
              createdAt: DateTime(2026),
              state: const PlayerState(false, ProcessingState.ready),
            )
            ..setOptimisticPosition(const Duration(seconds: 2))
            ..setOptimisticDuration(const Duration(minutes: 2));
      addTearDown(session.shutdown);
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final trackKey = TimeSegmentLabel.trackKeyFor(track);
      final existingTimestamp = DateTime(2026);
      await tester.runAsync(
        () => fixture.persistenceRepository.upsertTimeSegmentLabel(
          TimeSegmentLabel(
            id: 'existing-segment',
            trackKey: trackKey,
            name: '标签2',
            start: const Duration(seconds: 5),
            end: const Duration(seconds: 10),
            colorValue: kTimeSegmentLabelPalette.first,
            createdAt: existingTimestamp,
            updatedAt: existingTimestamp,
          ),
        ),
      );
      fixture.playbackService.registerSession(session);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pumpAndSettle();
      unawaited(
        Navigator.of(
          tester.element(find.byType(PlaylistTab)),
        ).push(buildSessionDetailRoute(sessionId: session.id)),
      );
      await tester.pumpAndSettle();

      final i18n = fixture.languageProvider;
      await tester.tap(find.byTooltip(i18n.tr('audio_features')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(i18n.tr('audio_detail_tags')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(i18n.tr('segment_add')));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '标签3',
      );

      session.setOptimisticPosition(const Duration(seconds: 18));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, i18n.tr('segment_start')),
      );
      await tester.pump();
      final startRow = find
          .ancestor(
            of: find.widgetWithText(FilledButton, i18n.tr('segment_start')),
            matching: find.byType(Row),
          )
          .first;
      expect(
        find.descendant(of: startRow, matching: find.text('00:18')),
        findsOneWidget,
      );

      session.setOptimisticPosition(const Duration(seconds: 42));
      await tester.pump();
      final firstSaveGate = Completer<void>();
      addTearDown(() {
        if (!firstSaveGate.isCompleted) firstSaveGate.complete();
      });
      fixture.persistenceRepository.beforeTimeSegmentLabelUpsert = () =>
          firstSaveGate.future;
      await tester.tap(
        find.widgetWithText(FilledButton, i18n.tr('segment_end')),
      );
      await tester.pump();
      final endRow = find
          .ancestor(
            of: find.widgetWithText(FilledButton, i18n.tr('segment_end')),
            matching: find.byType(Row),
          )
          .first;
      expect(
        find.descendant(of: endRow, matching: find.text('00:42')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip(i18n.tr('segment_add')));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '标签4',
      );
      fixture.persistenceRepository.beforeTimeSegmentLabelUpsert = null;
      firstSaveGate.complete();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      final labelsAfterFirst = await tester.runAsync(
        () => fixture.persistenceRepository.loadTimeSegmentLabels(trackKey),
      );
      expect(labelsAfterFirst, hasLength(2));
      expect(labelsAfterFirst![0].name, '标签2');
      expect(labelsAfterFirst[1].name, '标签3');
      expect(labelsAfterFirst[1].start, const Duration(seconds: 18));
      expect(labelsAfterFirst[1].end, const Duration(seconds: 42));

      var backupFinished = false;
      unawaited(
        fixture.library.detailCacheService.waitForPendingOperations().then(
          (_) => backupFinished = true,
        ),
      );
      for (var attempt = 0; !backupFinished && attempt < 100; attempt++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(backupFinished, isTrue);
      await tester.pump();

      session.setOptimisticPosition(const Duration(seconds: 80));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, i18n.tr('segment_end')),
      );
      await tester.pump();
      expect(
        find.descendant(of: endRow, matching: find.text('01:20')),
        findsOneWidget,
      );

      session.setOptimisticPosition(const Duration(seconds: 50));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, i18n.tr('segment_start')),
      );
      await tester.pump();
      expect(
        find.descendant(of: startRow, matching: find.text('00:50')),
        findsOneWidget,
      );

      final labelsAfterSecond = await tester.runAsync(
        () => fixture.persistenceRepository.loadTimeSegmentLabels(trackKey),
      );
      expect(labelsAfterSecond, hasLength(3));
      expect(labelsAfterSecond![0].name, '标签2');
      expect(labelsAfterSecond[1].name, '标签3');
      expect(labelsAfterSecond[1].start, const Duration(seconds: 18));
      expect(labelsAfterSecond[1].end, const Duration(seconds: 42));
      expect(labelsAfterSecond[2].name, '标签4');
      expect(labelsAfterSecond[2].start, const Duration(seconds: 50));
      expect(labelsAfterSecond[2].end, const Duration(seconds: 80));

      final sliderFinder = find.byType(Slider);
      expect(sliderFinder, findsOneWidget);
      final sliderCenter = tester.getCenter(sliderFinder);
      final gesture = await tester.startGesture(sliderCenter);
      await tester.pump();
      expect(find.byType(OverlayPortal), findsWidgets);
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'deleting a segment survives a pending name save and supports undo',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = testMusicTrack(
        name: 'Segment race track',
        path: '/library/segments/delete-race.mp3',
        groupKey: '/library/segments',
        groupTitle: 'Segments',
      );
      final session = PlaybackSession(
        id: 'segment-delete-race-session',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(session.shutdown);
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final trackKey = TimeSegmentLabel.trackKeyFor(track);
      await tester.runAsync(
        () => fixture.persistenceRepository.upsertTimeSegmentLabel(
          TimeSegmentLabel(
            id: 'label-to-delete',
            trackKey: trackKey,
            name: 'Original',
            start: const Duration(seconds: 5),
            end: const Duration(seconds: 10),
            colorValue: kTimeSegmentLabelPalette.first,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        ),
      );
      fixture.playbackService.registerSession(session);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pumpAndSettle();
      unawaited(
        Navigator.of(
          tester.element(find.byType(PlaylistTab)),
        ).push(buildSessionDetailRoute(sessionId: session.id)),
      );
      await tester.pumpAndSettle();
      final i18n = fixture.languageProvider;
      await tester.tap(find.byTooltip(i18n.tr('audio_features')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(i18n.tr('audio_detail_tags')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Original'));
      await tester.pump();

      final saveStarted = Completer<void>();
      final releaseSave = Completer<void>();
      addTearDown(() {
        if (!releaseSave.isCompleted) releaseSave.complete();
      });
      fixture.persistenceRepository.beforeTimeSegmentLabelUpsert = () {
        saveStarted.complete();
        return releaseSave.future;
      };
      await tester.enterText(find.byType(TextField), 'Renamed');
      await tester.pump(const Duration(milliseconds: 350));
      await saveStarted.future;

      await tester.tap(find.widgetWithText(FilledButton, i18n.tr('remove')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      fixture.persistenceRepository.beforeTimeSegmentLabelUpsert = null;
      releaseSave.complete();
      await tester.pump();
      await tester.runAsync(
        () => fixture.library.detailCacheService.waitForPendingOperations(),
      );
      List<TimeSegmentLabel>? remaining;
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump();
        remaining = await tester.runAsync(
          () => fixture.persistenceRepository.loadTimeSegmentLabels(trackKey),
        );
        if (remaining!.isEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(remaining, isEmpty);
      final undo = find.textContaining(i18n.tr('undo'));
      for (var attempt = 0; attempt < 100 && undo.evaluate().isEmpty; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await tester.pump();
      for (var attempt = 0;
          attempt < 100 && find.text('Renamed').evaluate().isEmpty;
          attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }

      final restored = await tester.runAsync(
        () => fixture.persistenceRepository.loadTimeSegmentLabels(trackKey),
      );
      expect(restored, hasLength(1));
      expect(restored!.single.id, 'label-to-delete');
      expect(restored.single.name, 'Renamed');
      expect(restored.single.start, const Duration(seconds: 5));
      expect(restored.single.end, const Duration(seconds: 10));
      expect(restored.single.colorValue, kTimeSegmentLabelPalette.first);
      expect(find.text('Renamed'), findsOneWidget);
    },
  );

  testWidgets(
    'playlist cards render circular covers without duration overlays',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final persistenceRepository = fixture.persistenceRepository;
      final nativePlaybackRepository = fixture.nativePlaybackRepository;
      const playbackCommandRunner =
          AppRuntimeWidgetTestFixture.playbackCommandRunner;
      final libraryService = fixture.libraryService;
      final playbackService = fixture.playbackService;
      final timerService = fixture.timerService;
      final notificationCoordinatorService =
          fixture.notificationCoordinatorService;
      final settingsRepository = fixture.settings;
      final languageProvider = fixture.languageProvider;
      final workTrack = testMusicTrack(
        name: 'Work track',
        path: Platform.isWindows
            ? r'C:\library\duration\work-track.mp3'
            : '/library/duration/work-track.mp3',
        groupKey: Platform.isWindows
            ? r'C:\library\duration'
            : '/library/duration',
        groupTitle: 'Duration',
      );
      final singleTrack = testMusicTrack(
        name: 'Single track',
        path: Platform.isWindows
            ? r'C:\imports\single-track.mp3'
            : '/imports/single-track.mp3',
        groupKey: Platform.isWindows
            ? r'C:\imports\single-track.mp3'
            : '/imports/single-track.mp3',
        groupTitle: 'Single track',
        isSingle: true,
      ).copyWith(manualCoverPath: '/covers/single.jpg');
      final workSession = PlaybackSession(
        id: 'work-duration-session',
        currentTrackPath: workTrack.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      final singleSession = PlaybackSession(
        id: 'single-duration-session',
        currentTrackPath: singleTrack.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026, 1, 2),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(workSession.shutdown);
      addTearDown(singleSession.shutdown);
      runtimeGraph.library.addTracks([workTrack, singleTrack], persist: false);
      playbackService.registerSession(workSession);
      playbackService.registerSession(singleSession);
      playbackService.syncSlice(
        activeSessions: [workSession, singleSession],
        playingSessionCount: 0,
        focusedSessionId: workSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: runtimeGraph,
          persistenceRepository: persistenceRepository,
          nativePlaybackRepository: nativePlaybackRepository,
          playbackCommandRunner: playbackCommandRunner,
          libraryService: libraryService,
          playbackService: playbackService,
          timerService: timerService,
          notificationCoordinatorService: notificationCoordinatorService,
          settingsRepository: settingsRepository,
          languageProvider: languageProvider,
          child: const PlaylistTab(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('02:05'), findsNothing);

      final workRow = find.byWidgetPredicate(
        (widget) =>
            widget is SwipeRevealCard &&
            widget.key == const ValueKey('work-duration-session'),
      );
      final singleRow = find.byWidgetPredicate(
        (widget) =>
            widget is SwipeRevealCard &&
            widget.key == const ValueKey('single-duration-session'),
      );
      final rowsByTop = [workRow, singleRow]
        ..sort(
          (a, b) => tester.getTopLeft(a).dy.compareTo(tester.getTopLeft(b).dy),
        );
      expect(
        tester.getBottomLeft(rowsByTop.first).dy,
        closeTo(tester.getTopLeft(rowsByTop.last).dy, 0.01),
        reason: 'Playlist rows should form one continuous list.',
      );
      expect(
        tester.getSize(
          find.byKey(const ValueKey('playlist_cover_single-duration-session')),
        ),
        const Size.square(52),
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('playlist_cover_single-duration-session'),
          ),
          matching: find.byType(ClipOval),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('playlist_cover_work-duration-session'),
          ),
          matching: find.byType(ClipOval),
        ),
        findsOneWidget,
      );

      workSession.setOptimisticDuration(const Duration(minutes: 2, seconds: 5));
      singleSession.setOptimisticDuration(
        const Duration(minutes: 1, seconds: 10),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DurationOverlay), findsNothing);
      expect(find.text('02:05'), findsNothing);
      expect(find.text('01:10'), findsNothing);

      final workDetailTarget = AudioDetailTarget.libraryRootFolder(
        workTrack.groupKey,
      );
      final singleDetailTarget = AudioDetailTarget.singleAudioFile(
        singleTrack.path,
      );
      await tester.runAsync(() async {
        await runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            workDetailTarget,
          ).copyWith(duration: const Duration(minutes: 3, seconds: 40)),
        );
        await runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            singleDetailTarget,
          ).copyWith(duration: const Duration(minutes: 4, seconds: 50)),
        );
      });
      playbackService.syncSlice(
        activeSessions: [workSession, singleSession],
        playingSessionCount: 0,
        focusedSessionId: workSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpAndSettle();

      expect(
        runtimeGraph.library.resolvedAudioDetail(workDetailTarget)?.duration,
        const Duration(minutes: 3, seconds: 40),
      );
      expect(
        runtimeGraph.library.resolvedAudioDetail(singleDetailTarget)?.duration,
        const Duration(minutes: 4, seconds: 50),
      );
      expect(find.byType(DurationOverlay), findsNothing);
      expect(find.text('02:05'), findsNothing);
      expect(find.text('04:50'), findsNothing);
      expect(find.text('03:40'), findsNothing);
      expect(find.text('01:10'), findsNothing);
    },
  );

  for (final dismissal in ['outside', 'back', 'nested editor']) {
    testWidgets('queue stays revealed until edit menu closes via $dismissal', (
      tester,
    ) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final session = fixture.playback.createPlaybackQueue('Queue');
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pumpAndSettle();
      final row = find.byKey(
        ValueKey('playback_queue_row_surface_${session.id}'),
        skipOffstage: false,
      );
      final initialLeft = tester.getTopLeft(row).dx;
      await tester.drag(find.byType(PlaybackQueueCard), const Offset(-180, 0));
      await tester.pumpAndSettle();
      final revealedLeft = tester.getTopLeft(row).dx;
      expect(revealedLeft, lessThan(initialLeft));
      await tester.tap(
        find.byTooltip(fixture.languageProvider.tr('edit_playback_queue')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackQueueEditPage), findsOneWidget);
      expect(tester.getTopLeft(row).dx, closeTo(revealedLeft, 0.1));

      if (dismissal == 'nested editor') {
        final i18n = fixture.languageProvider;
        await tester.tap(find.text(i18n.tr('edit_queue_audio')));
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackQueueAudioEditPage), findsOneWidget);
        expect(tester.getTopLeft(row).dx, closeTo(revealedLeft, 0.1));
        Navigator.of(
          tester.element(find.byType(PlaybackQueueAudioEditPage)),
        ).pop();
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackQueueEditPage), findsOneWidget);
        expect(tester.getTopLeft(row).dx, closeTo(revealedLeft, 0.1));
      }
      if (dismissal == 'outside') {
        await tester.tapAt(const Offset(10, 10));
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackQueueEditPage), findsNothing);
      expect(tester.getTopLeft(row).dx, closeTo(initialLeft, 0.1));
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'queue menus fit their panel in ${brightness.name} mode',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize =
            defaultTargetPlatform == TargetPlatform.windows
            ? const Size(960, 600)
            : const Size(375, 812);
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          notificationsChannel,
          (_) async => <String, Object?>{'ok': true, 'value': null},
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(notificationsChannel, null),
        );
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final session = fixture.playback.createPlaybackQueue('Queue');
        fixture.playbackService.syncSlice(
          activeSessions: [session],
          playingSessionCount: 0,
          focusedSessionId: session.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        await tester.pumpWidget(fixture.build(const PlaylistTab()));
        await tester.pumpAndSettle();
        unawaited(
          showPlaybackQueueEditPanel(
            tester.element(find.byType(PlaylistTab)),
            session.id,
          ),
        );
        await tester.pumpAndSettle();
        final i18n = fixture.languageProvider;
        final editRect = tester.getRect(
          find.byKey(const ValueKey('playback_queue_edit_panel')),
        );
        await tester.tap(find.text(i18n.tr('edit_queue_color')));
        await tester.pumpAndSettle();
        final colorRect = tester.getRect(
          find.byKey(const ValueKey('playback_queue_color_panel')),
        );
        expect(colorRect, editRect);
        for (final channel in ['R', 'G', 'B']) {
          final labelRect = tester.getRect(find.text(channel));
          expect(colorRect.contains(labelRect.topLeft), isTrue);
          expect(colorRect.contains(labelRect.bottomRight), isTrue);
        }
        final sliders = find.byType(Slider);
        expect(sliders, findsNWidgets(3));
        tester.widget<Slider>(sliders.first).onChanged!(160);
        await tester.pump();
        expect(
          (Color(session.playbackQueue!.colorValue!).r * 255).round(),
          160,
        );
        await tester.tap(find.text(i18n.tr('reset_to_default')));
        await tester.pump();
        expect(session.playbackQueue!.colorValue, isNull);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('queue cover lookup is reused across card rebuilds', (
    tester,
  ) async {
    final coverCache = _RecordingPlaybackCoverCacheService();
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: coverCache,
    );
    addTearDown(fixture.dispose);
    final track = testMusicTrack(
      name: 'Queue track',
      path: '/library/queue/track.mp3',
      groupKey: '/library/queue',
      groupTitle: 'Queue work',
    );
    final session = fixture.runtimeGraph.playback.createPlaybackQueue('Queue')
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
      );
    addTearDown(session.shutdown);
    void syncCoverGeneration(int generation) {
      while (coverCache.generation < generation) {
        coverCache.invalidateAll();
      }
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: generation,
        isInitialized: true,
      );
    }

    Widget card() => fixture.build(
      Center(
        child: SizedBox(
          width: 400,
          child: PlaybackQueueCard(
            session: PlaybackSessionSnapshot.fromRuntime(session),
            library: fixture.runtimeGraph.library,
            playback: fixture.runtimeGraph.playback,
            coverCacheWidth: 96,
            onOpen: () {},
            onEdit: () {},
          ),
        ),
      ),
    );

    syncCoverGeneration(0);
    await tester.pumpWidget(card());
    await tester.pump();
    expect(coverCache.requestedPaths, [track.path]);

    await tester.pumpWidget(card());
    await tester.pump();
    expect(coverCache.requestedPaths, [track.path]);

    syncCoverGeneration(1);
    await tester.pump();
    await tester.pumpWidget(card());
    await tester.pump();
    expect(coverCache.requestedPaths, [track.path, track.path]);
    await tester.pump(const Duration(milliseconds: 200));
  });

  for (final cached in [false, true]) {
    testWidgets(
      'queue cover defers cold decoding and reuses decoded artwork during navigation (cached: $cached)',
      (tester) async {
        final interaction = UiInteractionCoordinator.instance;
        interaction.resetForTest();
        addTearDown(interaction.resetForTest);
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('queue-cover-navigation-'),
        ))!;
        final file = File('${directory.path}/cover.png');
        await tester.runAsync(
          () => file.writeAsBytes(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            ),
          ),
        );
        final provider = resizeFileImageIfNeeded(
          path: file.path,
          cacheWidth: 8,
        );
        final key = await provider.obtainKey(ImageConfiguration.empty);
        addTearDown(() async {
          releaseRetainedCoverImage(provider);
          await provider.evict();
          await tester.runAsync(() => file.delete());
          await tester.runAsync(() => directory.delete());
        });
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        if (cached) {
          await tester.pumpWidget(fixture.build(const SizedBox.shrink()));
          await tester.runAsync(
            () =>
                precacheImage(provider, tester.element(find.byType(Scaffold))),
          );
          await tester.pump();
        }
        final imageCache = PaintingBinding.instance.imageCache;
        expect(imageCache.statusForKey(key).tracked, cached);
        expect(imageCache.statusForKey(key).pending, isFalse);
        final navigation = Object();
        interaction.beginNavigation(navigation);
        final track = testMusicTrack(
          name: 'Queue artwork',
          path: '/library/queue/artwork.mp3',
          groupKey: '/library/queue',
          groupTitle: 'Queue work',
        );
        await tester.pumpWidget(
          fixture.build(
            Center(
              child: SizedBox.square(
                dimension: 52,
                child: QueueTrackCover(
                  track: track,
                  coverPath: file.path,
                  coverCacheWidth: 8,
                  future: SynchronousFuture<String?>(file.path),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final decodedArtwork = find.descendant(
          of: find.descendant(
            of: find.byType(QueueTrackCover),
            matching: find.byWidgetPredicate(
              (widget) => widget is Image && widget.image == provider,
            ),
          ),
          matching: find.byWidgetPredicate(
            (widget) => widget is RawImage && widget.image != null,
          ),
        );
        expect(interaction.navigationAllowed.value, isFalse);
        expect(imageCache.statusForKey(key).tracked, cached);
        expect(imageCache.statusForKey(key).pending, isFalse);
        expect(decodedArtwork, cached ? findsOneWidget : findsNothing);

        interaction.endNavigation(navigation);
        await tester.pump();
        expect(imageCache.statusForKey(key).tracked, isTrue);
        await pumpUntilFound(tester, decodedArtwork);
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

  for (final count in [1, 2, 3, 4]) {
    testWidgets('$count queue covers fill equal sectors at their centroids', (
      tester,
    ) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final tracks = List.generate(
        count,
        (index) => testMusicTrack(
          name: 'Queue track $index',
          path: '/library/queue/track-$index.mp3',
          groupKey: '/library/queue',
          groupTitle: 'Queue work',
        ),
      );
      final session = fixture.runtimeGraph.playback.createPlaybackQueue('Queue')
        ..currentTrackPath = tracks.first.path
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'Queue',
          entries: [
            for (var index = 0; index < tracks.length; index++)
              PlaybackQueueEntry(
                id: 'track-$index',
                kind: PlaybackQueueEntryKind.track,
                title: tracks[index].displayName,
                tracks: [tracks[index]],
              ),
          ],
        );
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(
        fixture.build(
          Center(
            child: PlaybackQueueCard(
              session: PlaybackSessionSnapshot.fromRuntime(session),
              library: fixture.runtimeGraph.library,
              playback: fixture.runtimeGraph.playback,
              coverCacheWidth: 96,
              onOpen: () {},
              onEdit: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final grid = find.byKey(const ValueKey('playback_queue_cover_grid'));
      final gridCenter = tester.getCenter(grid);
      const sectorPoints = <int, List<Offset>>{
        1: [Offset(26, 26)],
        2: [Offset(8, 26), Offset(44, 26)],
        3: [Offset(26, 8), Offset(42, 35), Offset(10, 35)],
        4: [Offset(12, 12), Offset(40, 12), Offset(12, 40), Offset(40, 40)],
      };
      const centerOffsets = <int, List<Offset>>{
        1: [Offset.zero],
        2: [Offset(-11.0347, 0), Offset(11.0347, 0)],
        3: [
          Offset(0, -14.3346),
          Offset(12.4141, 7.1673),
          Offset(-12.4141, 7.1673),
        ],
        4: [
          Offset(-11.0347, -11.0347),
          Offset(11.0347, -11.0347),
          Offset(-11.0347, 11.0347),
          Offset(11.0347, 11.0347),
        ],
      };
      expect(
        find.byKey(ValueKey('playback_queue_cover_cell_$count')),
        findsNothing,
      );
      for (var index = 0; index < count; index++) {
        final cell = find.byKey(ValueKey('playback_queue_cover_cell_$index'));
        expect(cell, findsOneWidget);
        final expectedCenter = gridCenter + centerOffsets[count]![index];
        final actualCenter = tester.getCenter(cell);
        expect(actualCenter.dx, closeTo(expectedCenter.dx, 0.01));
        expect(actualCenter.dy, closeTo(expectedCenter.dy, 0.01));
        if (count == 1) continue;
        final clip = tester.widget<ClipPath>(
          find.ancestor(of: cell, matching: find.byType(ClipPath)).first,
        );
        final path = clip.clipper!.getClip(const Size.square(52));
        for (var pointIndex = 0; pointIndex < count; pointIndex++) {
          expect(
            path.contains(sectorPoints[count]![pointIndex]),
            pointIndex == index,
          );
        }
      }
      final dividers = find.byKey(
        const ValueKey('playback_queue_cover_dividers'),
      );
      if (count == 1) {
        expect(dividers, findsNothing);
      } else {
        expect(dividers, findsOneWidget);
        final customPaint = tester.widget<CustomPaint>(dividers);
        expect(customPaint.painter, isNotNull);
      }
      await tester.pump(const Duration(milliseconds: 200));
    });
  }

  testWidgets('playlist more menu and sort button remain available', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;

    playbackService.syncSlice(
      activeSessions: const [],
      playingSessionCount: 0,
      focusedSessionId: null,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: const PlaylistTab(),
      ),
    );
    await tester.pump();

    final headerBottom = tester.getBottomLeft(find.byType(TopPageHeader)).dy;
    final emptyCardRect = tester.getRect(
      find.byKey(const ValueKey('playlist_empty_state_card')),
    );
    final viewportHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final topGap = emptyCardRect.top - headerBottom;
    final bottomGap = viewportHeight - 16 - emptyCardRect.bottom;
    expect(topGap, greaterThanOrEqualTo(0));
    expect(topGap, closeTo(bottomGap, 5));

    expect(find.byTooltip(languageProvider.tr('sort_by')), findsOneWidget);
    await tester.tap(find.byTooltip(languageProvider.tr('sort_by')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(languageProvider.tr('sort_by_title')), findsOneWidget);
    expect(find.text(languageProvider.tr('sort_release_date')), findsOneWidget);
    expect(find.text(languageProvider.tr('cancel')), findsOneWidget);
    expect(find.text(languageProvider.tr('confirm')), findsOneWidget);
    final viewportSize =
        tester.view.physicalSize / tester.view.devicePixelRatio;
    final cancelRect = tester.getRect(
      find.byKey(const ValueKey('sort_options_cancel')),
    );
    final confirmRect = tester.getRect(
      find.byKey(const ValueKey('sort_options_confirm')),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('sort_options_confirm'))),
      isA<TextButton>(),
    );
    expect(confirmRect.bottom, lessThanOrEqualTo(viewportSize.height));
    expect(cancelRect.center.dx, greaterThan(viewportSize.width / 2));
    expect(confirmRect.left, greaterThan(cancelRect.right));
    expect(confirmRect.center.dy, closeTo(cancelRect.center.dy, 0.01));
    expect(confirmRect.width, lessThan(120));
    await tester.ensureVisible(
      find.text(languageProvider.tr('sort_descending')),
    );
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('sort_descending')));
    await tester.pump();
    await tester.ensureVisible(
      find.text(languageProvider.tr('sort_group_by_library')),
    );
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('sort_group_by_library')));
    await tester.pump();
    tester
        .widget<RadioGroup<PlaylistSortCriterion>>(
          find.byType(RadioGroup<PlaylistSortCriterion>),
        )
        .onChanged(PlaylistSortCriterion.releaseDate);
    await tester.pump();
    expect(settingsRepository.playlistSortAscending, isTrue);
    expect(settingsRepository.playlistGroupByLibrary, isFalse);
    expect(
      settingsRepository.playlistSortCriterion,
      PlaylistSortCriterion.name,
    );
    await tester.tap(find.text(languageProvider.tr('cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip(languageProvider.tr('sort_by')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<RadioGroup<PlaylistSortCriterion>>(
            find.byType(RadioGroup<PlaylistSortCriterion>),
          )
          .groupValue,
      PlaylistSortCriterion.name,
    );
    expect(_selectedSortControls(tester), <String>{'ascending'});
    tester
        .widget<RadioGroup<PlaylistSortCriterion>>(
          find.byType(RadioGroup<PlaylistSortCriterion>),
        )
        .onChanged(PlaylistSortCriterion.releaseDate);
    await tester.ensureVisible(
      find.text(languageProvider.tr('sort_descending')),
    );
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('sort_descending')));
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('sort_group_by_library')));
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(settingsRepository.playlistSortAscending, isFalse);
    expect(settingsRepository.playlistGroupByLibrary, isTrue);
    expect(
      settingsRepository.playlistSortCriterion,
      PlaylistSortCriterion.releaseDate,
    );

    expect(
      find.byTooltip(languageProvider.tr('pause_all_sessions')),
      findsOneWidget,
    );
    expect(
      find.byTooltip(languageProvider.tr('clear_all_sessions')),
      findsOneWidget,
    );
    expect(
      find.byTooltip(languageProvider.tr('add_playback_queue')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip(languageProvider.tr('add_playback_queue')));
    await tester.pumpAndSettle();

    expect(
      runtimeGraph.playback.activeSessions.where(
        (session) => session.isPlaybackQueue,
      ),
      hasLength(1),
    );
    expect(
      runtimeGraph.playback.activeSessions
          .singleWhere((session) => session.isPlaybackQueue)
          .playbackQueue
          ?.name,
      languageProvider.tr('default_playback_queue_name', {'number': 1}),
    );
    final queueSession = runtimeGraph.playback.activeSessions.singleWhere(
      (session) => session.isPlaybackQueue,
    );
    const queueCardColor = Color(0xFF2E9C8B);
    final queueTrack = testMusicTrack(
      name: 'Queue track',
      path: '/library/queue/track.mp3',
      groupKey: '/library/queue',
      groupTitle: 'Queue work',
    ).copyWith(duration: const Duration(minutes: 2, seconds: 35));
    final secondQueueTrack = testMusicTrack(
      name: 'Queue second track',
      path: '/library/queue/second-track.mp3',
      groupKey: '/library/queue',
      groupTitle: 'Queue work',
    );
    runtimeGraph.library.addTracks(
      <MusicTrack>[queueTrack, secondQueueTrack],
      notify: false,
      persist: false,
    );
    queueSession
      ..currentTrackPath = queueTrack.path
      ..playbackQueue = PlaybackQueueDefinition(
        name: queueSession.playbackQueue!.name,
        colorValue: queueCardColor.toARGB32(),
        entries: <PlaybackQueueEntry>[
          PlaybackQueueEntry(
            id: 'queue-entry',
            kind: PlaybackQueueEntryKind.track,
            title: queueTrack.displayName,
            tracks: <MusicTrack>[queueTrack],
          ),
          PlaybackQueueEntry(
            id: 'queue-second-entry',
            kind: PlaybackQueueEntryKind.track,
            title: secondQueueTrack.displayName,
            tracks: <MusicTrack>[secondQueueTrack],
          ),
        ],
      );
    playbackService.markActiveSessionsDirty();
    playbackService.syncSlice(
      activeSessions: <PlaybackSession>[queueSession],
      playingSessionCount: 0,
      focusedSessionId: queueSession.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pumpAndSettle();

    final queueCard = tester
        .widgetList<SwipeRevealCard>(find.byType(SwipeRevealCard))
        .singleWhere((card) => card.key == ValueKey(queueSession.id));
    expect(queueCard.shape, same(playlistRowShape));
    expect(queueCard.margin, EdgeInsets.zero);
    final queueCoverGrid = find.byKey(
      const ValueKey('playback_queue_cover_grid'),
    );
    expect(queueCoverGrid, findsOneWidget);
    expect(tester.widget(queueCoverGrid), isA<ClipOval>());
    expect(
      queueCard.closedColor,
      Theme.of(tester.element(find.byType(PlaylistTab))).colorScheme.surface,
    );
    final queueName = tester.widget<Text>(
      find.byKey(ValueKey('playback_queue_name_${queueSession.id}')),
    );
    final firstTrackName = tester.widget<Text>(
      find.byKey(ValueKey('playback_queue_track_0_${queueSession.id}')),
    );
    expect(queueName.data, queueSession.playbackQueue!.name);
    expect(queueName.style?.fontSize, 12);
    expect(queueName.style?.fontWeight, FontWeight.w600);
    expect(
      queueName.style?.color,
      Theme.of(
        tester.element(find.byType(PlaylistTab)),
      ).colorScheme.onSurfaceVariant,
    );
    expect(firstTrackName.data, queueTrack.displayName);
    expect(firstTrackName.style?.fontSize, 14);
    expect(firstTrackName.style?.fontWeight, FontWeight.w800);
    expect(firstTrackName.style?.height, 1.12);
    expect(firstTrackName.maxLines, 2);
    expect(
      find.byKey(ValueKey('playback_queue_track_1_${queueSession.id}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('playback_queue_duration_${queueSession.id}')),
      findsNothing,
    );
    expect(find.text('02:35'), findsNothing);

    final remoteCurrentTrack = testMusicTrack(
      name: 'Remote current track name',
      path: 'https://example.com/audio/current-track.mp3',
      groupKey: 'remote-work',
      groupTitle: 'Remote work',
    ).copyWith(duration: const Duration(minutes: 5, seconds: 12));
    queueSession
      ..currentTrackPath = remoteCurrentTrack.path
      ..currentQueueIndex = 1
      ..playbackQueue = PlaybackQueueDefinition(
        name: queueSession.playbackQueue!.name,
        colorValue: queueCardColor.toARGB32(),
        entries: <PlaybackQueueEntry>[
          PlaybackQueueEntry(
            id: 'queue-entry',
            kind: PlaybackQueueEntryKind.track,
            title: queueTrack.displayName,
            tracks: <MusicTrack>[queueTrack],
          ),
          PlaybackQueueEntry(
            id: 'remote-current-entry',
            kind: PlaybackQueueEntryKind.track,
            title: remoteCurrentTrack.displayName,
            tracks: <MusicTrack>[remoteCurrentTrack],
          ),
          PlaybackQueueEntry(
            id: 'queue-second-entry',
            kind: PlaybackQueueEntryKind.track,
            title: secondQueueTrack.displayName,
            tracks: <MusicTrack>[secondQueueTrack],
          ),
        ],
      );
    playbackService.markActiveSessionsDirty();
    playbackService.syncSlice(
      activeSessions: <PlaybackSession>[queueSession],
      playingSessionCount: 0,
      focusedSessionId: queueSession.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
            find.byKey(ValueKey('playback_queue_track_0_${queueSession.id}')),
          )
          .data,
      remoteCurrentTrack.displayName,
    );
    expect(
      find.byKey(ValueKey('playback_queue_track_1_${queueSession.id}')),
      findsNothing,
    );
    expect(find.text('05:12'), findsNothing);
    expect(
      find.byKey(ValueKey('playback_queue_loop_mode_${queueSession.id}')),
      findsNothing,
    );
    queueSession.state = const PlayerState(true, ProcessingState.ready);
    playbackService.markSessionStateDirty();
    playbackService.syncSlice(
      activeSessions: <PlaybackSession>[queueSession],
      playingSessionCount: 1,
      focusedSessionId: queueSession.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pumpAndSettle();

    final queueRowMaterial = tester.widget<Material>(
      find.byKey(ValueKey('playback_queue_row_surface_${queueSession.id}')),
    );
    expect(queueRowMaterial.color, Colors.transparent);
    final activeHighlight = tester.widget<DecoratedBox>(
      find.byKey(
        ValueKey('playback_queue_active_highlight_${queueSession.id}'),
      ),
    );
    final activeGradient =
        (activeHighlight.decoration as ShapeDecoration).gradient!
            as LinearGradient;
    final playlistTheme = Theme.of(tester.element(find.byType(PlaylistTab)));
    expect(activeGradient.colors, <Color>[
      queueCardColor.withValues(
        alpha: playlistTheme.brightness == Brightness.dark ? 0.16 : 0.12,
      ),
      Colors.transparent,
      Colors.transparent,
      Colors.transparent,
    ]);
    expect(activeGradient.begin, Alignment.topLeft);
    expect(activeGradient.end, Alignment.bottomRight);

    expect(
      find.descendant(
        of: find.byType(PlaybackQueueCard),
        matching: find.byIcon(Icons.subtitles_rounded),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(PlaybackQueueCard),
        matching: find.byIcon(Icons.speed_rounded),
      ),
      findsNothing,
    );

    ProviderScope.containerOf(tester.element(find.byType(PlaylistTab)))
        .read(subtitleSettingsProvider.notifier)
        .setGlobalEnabled(queueSession.id, true);
    queueSession.speed = 1.25;
    playbackService.markActiveSessionsDirty();
    playbackService.syncSlice(
      activeSessions: <PlaybackSession>[queueSession],
      playingSessionCount: 1,
      focusedSessionId: queueSession.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(PlaybackQueueCard),
        matching: find.byIcon(Icons.subtitles_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(PlaybackQueueCard),
        matching: find.byIcon(Icons.speed_rounded),
      ),
      findsOneWidget,
    );

    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: queueSession.id)),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(SessionDetailPage),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Theme &&
              widget.child is Material &&
              widget.data.colorScheme.primary == queueCardColor,
        ),
      ),
      findsOneWidget,
    );
    Navigator.of(tester.element(find.byType(SessionDetailPage))).pop();
    await tester.pumpAndSettle();

    unawaited(
      showPlaybackQueueEditPanel(
        tester.element(find.byType(PlaylistTab)),
        queueSession.id,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text(languageProvider.tr('edit_queue_audio')), findsOneWidget);
    expect(find.text(languageProvider.tr('edit_queue_name')), findsOneWidget);
    expect(find.text(languageProvider.tr('edit_queue_color')), findsOneWidget);
    expect(find.text(languageProvider.tr('remove_queue')), findsOneWidget);
    final queueTrackCountText = languageProvider.tr('audio_count', {
      'count': queueSession.playbackQueue!.expandedTracks.length.toString(),
    });
    expect(
      find.descendant(
        of: find.byType(PlaybackQueueEditPage),
        matching: find.text(queueTrackCountText),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(PlaybackQueueEditPage),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byType(PlaybackQueueEditPage),
        matching: find.byType(BottomSheet),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(PlaybackQueueEditPage),
        matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
      ),
      findsNothing,
    );
    final headerIcon = find.byKey(
      const ValueKey('playback_queue_edit_header_icon'),
    );
    expect(headerIcon, findsOneWidget);
    expect(tester.widget<Icon>(headerIcon).icon, Icons.edit_note_rounded);
    expect(tester.widget<Icon>(headerIcon).size, 22);
    expect(
      find.ancestor(
        of: headerIcon,
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.decoration != null,
        ),
      ),
      findsOneWidget,
    );
    final editAudioIcon = find.byKey(
      ValueKey(
        'playback_queue_edit_tile_icon_${Icons.playlist_play_rounded.codePoint}',
      ),
    );
    expect(editAudioIcon, findsOneWidget);
    expect(
      tester.widget<Icon>(editAudioIcon).icon,
      Icons.playlist_play_rounded,
    );
    expect(
      find.ancestor(
        of: editAudioIcon,
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.decoration != null,
        ),
      ),
      findsOneWidget,
    );
    final audioTileCenterY = tester.getCenter(find.text(languageProvider.tr('edit_queue_audio'))).dy;
    final nameTileCenterY = tester.getCenter(find.text(languageProvider.tr('edit_queue_name'))).dy;
    final colorTileCenterY = tester.getCenter(find.text(languageProvider.tr('edit_queue_color'))).dy;
    expect(nameTileCenterY - audioTileCenterY, closeTo(68.0, 0.5));
    expect(colorTileCenterY - nameTileCenterY, closeTo(68.0, 0.5));

    final removeQueueText = find.text(languageProvider.tr('remove_queue'));
    expect(removeQueueText, findsOneWidget);
    final removeQueueButton = tester.widget<TextButton>(
      find
          .ancestor(of: removeQueueText, matching: find.byType(TextButton))
          .first,
    );
    expect(
      removeQueueButton.style?.shape?.resolve({}) is StadiumBorder,
      isTrue,
    );
    final removeQueueCenter = tester.getCenter(removeQueueText);
    final editPanelRect = tester.getRect(
      find.byKey(const ValueKey('playback_queue_edit_panel')),
    );
    final headerIconRect = tester.getRect(headerIcon);
    expect(headerIconRect.size, const Size(40, 40));
    expect(headerIconRect.left - editPanelRect.left, closeTo(20, 0.5));
    expect(headerIconRect.top - editPanelRect.top, closeTo(20, 0.5));
    final audioTileRect = tester.getRect(
      find.ancestor(
        of: find.text(languageProvider.tr('edit_queue_audio')),
        matching: find.byType(InkWell),
      ).first,
    );
    expect(audioTileRect.top - headerIconRect.bottom, closeTo(18, 0.5));
    final editAudioIconRect = tester.getRect(editAudioIcon);
    expect(editAudioIconRect.size, const Size(36, 36));
    expect(editAudioIconRect.left - audioTileRect.left, closeTo(12, 0.5));
    expect(editAudioIconRect.top - audioTileRect.top, closeTo(10, 0.5));
    expect(removeQueueCenter.dx, greaterThan(editPanelRect.center.dx));
    final removeQueueBottomRight = tester.getBottomRight(removeQueueText);
    expect(
      editPanelRect.bottom - removeQueueBottomRight.dy,
      greaterThanOrEqualTo(16.0),
    );
    expect(
      editPanelRect.right - removeQueueBottomRight.dx,
      greaterThanOrEqualTo(20.0),
    );
    final editPageHeight = editPanelRect.height;

    await tester.tap(find.text(languageProvider.tr('edit_queue_color')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text(languageProvider.tr('edit_queue_audio')), findsOneWidget);
    final colorFade = find
        .ancestor(
          of: find.byKey(const ValueKey('playback_queue_color_panel')),
          matching: find.byType(FadeTransition),
        )
        .first;
    expect(
      tester.widget<FadeTransition>(colorFade).opacity.value,
      closeTo(0.5, 0.03),
    );
    await tester.pumpAndSettle();
    final colorPanelFinder = find.byKey(
      const ValueKey('playback_queue_color_panel'),
    );
    expect(colorPanelFinder, findsOneWidget);
    final colorPanelRect = tester.getRect(colorPanelFinder);
    expect(colorPanelRect.height, closeTo(editPageHeight, 0.5));
    expect(colorPanelRect.width, closeTo(editPanelRect.width, 0.5));
    final resetText = find.text(languageProvider.tr('reset_to_default'));
    final resetButton = tester.widget<TextButton>(
      find.ancestor(of: resetText, matching: find.byType(TextButton)).first,
    );
    expect(resetButton.style?.shape?.resolve({}) is StadiumBorder, isTrue);
    final resetBottomRight = tester.getBottomRight(resetText);
    expect(
      colorPanelRect.bottom - resetBottomRight.dy,
      greaterThanOrEqualTo(16.0),
    );
    expect(
      colorPanelRect.right - resetBottomRight.dx,
      greaterThanOrEqualTo(20.0),
    );
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Slider), findsNWidgets(3));
    final rCenterY = tester.getCenter(find.text('R')).dy;
    final gCenterY = tester.getCenter(find.text('G')).dy;
    final bCenterY = tester.getCenter(find.text('B')).dy;
    expect(gCenterY - rCenterY, closeTo(50.0, 0.5));
    expect(bCenterY - gCenterY, closeTo(50.0, 0.5));
    final colorPanelThemeCs = Theme.of(
      tester.element(colorPanelFinder),
    ).colorScheme;
    for (final channel in ['R', 'G', 'B']) {
      final channelText = find.text(channel);
      expect(channelText, findsOneWidget);
      expect(
        tester.widget<Text>(channelText).style?.color,
        colorPanelThemeCs.primary,
      );
      expect(
        find.ancestor(
          of: channelText,
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.decoration != null,
          ),
        ),
        findsNothing,
      );
    }
    final presetColorButtons = find.descendant(
      of: colorPanelFinder,
      matching: find.byWidgetPredicate(
        (w) =>
            w is InkWell &&
            w.customBorder is CircleBorder &&
            w.child is AnimatedContainer,
      ),
    );
    expect(presetColorButtons, findsNWidgets(5));
    final colorHeaderIconRect = tester.getRect(
      find.byKey(const ValueKey('playback_queue_color_header_icon')),
    );
    expect(colorHeaderIconRect.size, const Size(40, 40));
    expect(colorHeaderIconRect.left - colorPanelRect.left, closeTo(20, 0.5));
    expect(colorHeaderIconRect.top - colorPanelRect.top, closeTo(20, 0.5));
    expect(
      tester.getTopLeft(presetColorButtons.first).dy - colorHeaderIconRect.bottom,
      closeTo(28, 0.5),
    );
    final row1Y = tester.getCenter(presetColorButtons.at(0)).dy;
    for (var i = 1; i < 5; i++) {
      expect(
        tester.getCenter(presetColorButtons.at(i)).dy,
        closeTo(row1Y, 0.5),
      );
    }
    expect(find.text(languageProvider.tr('edit_queue_audio')), findsOneWidget);
    expect(
      find.text(languageProvider.tr('edit_queue_audio')).hitTestable(),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('playback_queue_color_back')));
    await tester.pump();
    expect(find.text(languageProvider.tr('edit_queue_audio')), findsOneWidget);
    expect(colorPanelFinder, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 1));
    expect(colorPanelFinder, findsNothing);
    await tester.tap(find.text(languageProvider.tr('edit_queue_audio')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackQueueAudioEditPage), findsOneWidget);
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsWidgets);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
    'queue edit rows arrange 44px actions horizontally and provide haptics',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platformCalls = <MethodCall>[];
      final previousHaptics = AppInteractionFeedback.hapticFeedbackEnabled;
      AppInteractionFeedback.hapticFeedbackEnabled = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            platformCalls.add(call);
            return null;
          });
      addTearDown(() {
        AppInteractionFeedback.hapticFeedbackEnabled = previousHaptics;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = MusicTrack(
        path: '/library/work/track.mp3',
        displayName: 'Track',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: '/library/work',
        isSingle: false,
      );
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final sourceSession = PlaybackSession(
        id: 'queue-source',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(sourceSession.shutdown);
      final queueSession = fixture.runtimeGraph.playback.createPlaybackQueue(
        'Queue',
      );
      addTearDown(queueSession.shutdown);
      fixture.playbackService.registerSession(sourceSession);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[sourceSession, queueSession],
        playingSessionCount: 0,
        focusedSessionId: sourceSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        fixture.build(PlaybackQueueAudioEditPage(sessionId: queueSession.id)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TopPageHeader), findsOneWidget);

      final addAudio = find.byTooltip(
        fixture.languageProvider.tr('add_audio_to_queue'),
      );
      final addWork = find.byTooltip(
        fixture.languageProvider.tr('add_work_to_queue'),
      );
      expect(tester.getSize(addAudio), const Size(44, 44));
      expect(tester.getSize(addWork), const Size(44, 44));
      expect(tester.getCenter(addAudio).dy, tester.getCenter(addWork).dy);
      expect(
        tester.getCenter(addAudio).dx,
        lessThan(tester.getCenter(addWork).dx),
      );
      final sourceCard = tester.widget<Card>(
        find.ancestor(of: addAudio, matching: find.byType(Card)).first,
      );
      final sourceElement = tester.element(addAudio);
      final isDark = Theme.of(sourceElement).brightness == Brightness.dark;
      final cs = Theme.of(sourceElement).colorScheme;
      expect(
        sourceCard.color,
        isDark ? cs.surfaceContainerLowest : cs.surfaceContainer,
      );
      expect(
        (sourceCard.shape! as RoundedRectangleBorder).side,
        BorderSide.none,
      );

      await tester.tap(addAudio);
      await tester.pump();
      expect(
        platformCalls.where((call) => call.method == 'HapticFeedback.vibrate'),
        hasLength(1),
      );
      final removeAudio = find.byTooltip(fixture.languageProvider.tr('remove'));
      expect(removeAudio, findsOneWidget);
      final dragHandle = find.byIcon(Icons.drag_handle_rounded);
      expect(dragHandle, findsOneWidget);
      expect(
        tester.getCenter(removeAudio).dy,
        closeTo(tester.getCenter(dragHandle).dy, 1.0),
      );
      expect(
        tester.getCenter(removeAudio).dx,
        lessThan(tester.getCenter(dragHandle).dx),
      );
      expect(find.text('Work'), findsWidgets);
      expect(find.text('Track'), findsWidgets);
      await tester.tap(removeAudio);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 800));
      expect(
        platformCalls.where((call) => call.method == 'HapticFeedback.vibrate'),
        hasLength(3),
      );
      await tester.tap(
        find.textContaining(fixture.languageProvider.tr('undo')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'playback queue audio edit page renders floating capsule section headers and scrolls on add',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        notificationsChannel,
        (_) async => <String, Object?>{'ok': true, 'value': null},
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(notificationsChannel, null),
      );
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
      );
      addTearDown(fixture.dispose);
      final track1 = testMusicTrack(
        name: 'Track 1',
        path: '/library/work/track1.mp3',
        groupKey: '/library/work',
        groupTitle: 'Work',
        isSingle: true,
      );
      final track2 = testMusicTrack(
        name: 'Track 2',
        path: '/library/work/track2.mp3',
        groupKey: '/library/work',
        groupTitle: 'Work',
        isSingle: true,
      );
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track1, track2],
        notify: false,
        persist: false,
      );
      final sourceSession1 = PlaybackSession(
        id: 'source-1',
        currentTrackPath: track1.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      final sourceSession2 = PlaybackSession(
        id: 'source-2',
        currentTrackPath: track2.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(sourceSession1.shutdown);
      addTearDown(sourceSession2.shutdown);
      final queueSession = fixture.runtimeGraph.playback.createPlaybackQueue(
        'Test Queue',
      );
      addTearDown(queueSession.shutdown);
      fixture.playbackService.registerSession(sourceSession1);
      fixture.playbackService.registerSession(sourceSession2);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[
          sourceSession1,
          sourceSession2,
          queueSession,
        ],
        playingSessionCount: 0,
        focusedSessionId: sourceSession1.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        fixture.build(PlaybackQueueAudioEditPage(sessionId: queueSession.id)),
      );
      await tester.pumpAndSettle();

      // Check section header floating capsules
      expect(
        find.text(fixture.languageProvider.tr('queue_added_audio')),
        findsOneWidget,
      );
      expect(
        find.text(fixture.languageProvider.tr('playback_list_audio')),
        findsOneWidget,
      );
      expect(find.byType(HeaderFloatingSurface), findsNWidgets(4));
      final placeholders = find.byType(CoverFallbackArtwork);
      expect(placeholders, findsNWidgets(2));
      for (final placeholder in placeholders.evaluate()) {
        final cover = find.byElementPredicate(
          (element) => identical(element, placeholder),
        );
        final labels = find.descendant(
          of: find.ancestor(of: cover, matching: find.byType(Card)).first,
          matching: find.byType(Text),
        );
        expect(tester.getSize(cover), const Size.square(52));
        expect(
          tester.getRect(cover).right,
          lessThan(tester.getRect(labels.first).left),
        );
      }

      // Add audio to queue
      final addButtons = find.byTooltip(
        fixture.languageProvider.tr('add_audio_to_queue'),
      );
      expect(addButtons, findsNWidgets(2));
      await tester.tap(addButtons.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byTooltip(fixture.languageProvider.tr('remove')),
        findsOneWidget,
      );
      expect(placeholders, findsNWidgets(3));
      final primary = Theme.of(
        tester.element(find.byType(PlaybackQueueAudioEditPage)),
      ).colorScheme.primary;
      for (final icon in tester.widgetList<AppBrandIcon>(
        find.byType(AppBrandIcon),
      )) {
        expect(icon.color, primary);
      }
      await tester.pump(const Duration(seconds: 10));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'queue audio edit page displays work title instead of folder name',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.runtimeGraph.library.addWatchedLibrary('/library');
      final track = MusicTrack(
        path: '/library/RJ123456_Work/Disc 1/track1.mp3',
        displayName: 'Track 1',
        groupKey: '/library/RJ123456_Work/Disc 1',
        groupTitle: 'Disc 1',
        groupSubtitle: '/library/RJ123456_Work/Disc 1',
        isSingle: false,
      );
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final sourceSession = PlaybackSession(
        id: 'source-session',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(sourceSession.shutdown);
      final queueSession = fixture.runtimeGraph.playback.createPlaybackQueue(
        'Queue',
      );
      addTearDown(queueSession.shutdown);
      fixture.playbackService.registerSession(sourceSession);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[sourceSession, queueSession],
        playingSessionCount: 0,
        focusedSessionId: sourceSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        fixture.build(PlaybackQueueAudioEditPage(sessionId: queueSession.id)),
      );
      await tester.pumpAndSettle();

      // Top line should display work title ('RJ123456_Work'), not folder name ('Disc 1')
      expect(find.text('RJ123456_Work'), findsOneWidget);
      expect(find.text('Disc 1'), findsNothing);
      expect(find.text('Track 1'), findsOneWidget);

      // Add to queue and verify added entry also displays work title
      final addAudio = find.byTooltip(
        fixture.languageProvider.tr('add_audio_to_queue'),
      );
      await tester.tap(addAudio);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('RJ123456_Work'), findsWidgets);
      expect(find.text('Disc 1'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('playlist resolves ASMR metadata from the session queue', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final track = MusicTrack(
      path: 'https://api.asmr-300.com/api/media/stream/f3d4baa6ec96a6ad',
      displayName: '本編トラック 01',
      groupKey: 'asmr-work-123456',
      groupTitle: 'ASMR 作品タイトル',
      groupSubtitle: 'RJ123456',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: const <String, Object?>{
        'subtitleUrl': 'https://asmr.one/media/work/track.vtt',
      },
    );
    var subtitleLoadCount = 0;
    final subtitleLoad = Completer<SubtitleTrack?>();
    final subtitleService = PlaybackSubtitleService(
      trackResolver: (path) => path == track.path ? track : null,
      subtitleLoader: (_, _) {
        subtitleLoadCount++;
        return subtitleLoad.future;
      },
    );
    final session = fixture.runtimeGraph.playback.createTrackSession(
      track,
      loopMode: SessionLoopMode.single,
      customQueueTracks: <MusicTrack>[track],
    );
    addTearDown(session.shutdown);
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      fixture.build(const PlaylistTab(), subtitleService: subtitleService),
    );
    await tester.pump();

    expect(find.text(track.displayName), findsOneWidget);
    expect(find.text(track.groupTitle), findsOneWidget);
    expect(find.text('f3d4baa6ec96a6ad'), findsNothing);
    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: session.id)),
    );
    await tester.pumpAndSettle();

    expect(subtitleLoadCount, 1);
    expect(subtitleService.trackSync(track.path), isNull);
    final subtitleMenuButton = find.byKey(
      const ValueKey('session_subtitle_menu_button'),
    );
    expect(subtitleMenuButton, findsOneWidget);
    await tester.tap(subtitleMenuButton);
    await tester.pumpAndSettle();
    expect(
      find.text(fixture.languageProvider.tr('turn_off_subtitle')),
      findsOneWidget,
    );
    expect(
      find.text(fixture.languageProvider.tr('subtitle_global_display')),
      findsOneWidget,
    );
    final importTile = tester.widget<ListTile>(
      find.byKey(const ValueKey('subtitle_import_tile')),
    );
    expect(importTile.enabled, isFalse);
    expect(importTile.onTap, isNull);
    subtitleLoad.complete(null);
    await tester.pump();
    expect(subtitleService.trackSync(track.path), isNull);
    expect(
      find.text(fixture.languageProvider.tr('turn_off_subtitle')),
      findsOneWidget,
    );
    expect(
      find.text(fixture.languageProvider.tr('subtitle_global_display')),
      findsOneWidget,
    );
    await tester.tap(
      find.text(fixture.languageProvider.tr('turn_off_subtitle')),
    );
    await tester.pump();
    expect(
      find.text(fixture.languageProvider.tr('turn_on_subtitle')),
      findsOneWidget,
    );
    expect(
      find.text(fixture.languageProvider.tr('subtitle_global_display')),
      findsOneWidget,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('local library playlist shows the work card name', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    const libraryRoot = '/library/Library';
    const workRoot = '$libraryRoot/Work A';
    final track = MusicTrack(
      path: '$workRoot/Disc 1/01.mp3',
      displayName: '01',
      groupKey: workRoot,
      groupTitle: 'Work A',
      groupSubtitle: workRoot,
      isSingle: false,
    ).copyWith(manualCoverPath: '/covers/work.jpg');
    fixture.runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[track],
      notify: false,
      persist: false,
    );
    final session = fixture.runtimeGraph.playback.createTrackSession(
      track,
      customQueueTracks: <MusicTrack>[track],
    );
    addTearDown(session.shutdown);
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      fixture.build(
        const MobileOverlayInset(bottomInset: 132, child: PlaylistTab()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Work A'), findsOneWidget);
    expect(find.text('Library'), findsNothing);
    final playlistList = tester.widget<ListView>(
      find.byKey(const PageStorageKey<String>('playlist_list')),
    );
    expect(playlistList.padding!.resolve(TextDirection.ltr).bottom, 148);
    final swipeCard = tester.widget<SwipeRevealCard>(
      find.byType(SwipeRevealCard),
    );
    expect(swipeCard.color, isNull);
    expect(swipeCard.margin, EdgeInsets.zero);
    expect(swipeCard.shape, same(playlistRowShape));
    expect(
      swipeCard.closedColor,
      Theme.of(tester.element(find.byType(PlaylistTab))).colorScheme.surface,
    );
    expect(swipeCard.primaryActionIcon, Icons.delete_outline_rounded);
    expect(swipeCard.destructive, isTrue);
    final cardContent = tester.widget<Padding>(
      find.byKey(ValueKey<String>('playlist_card_content_${session.id}')),
    );
    final visualCard = tester.widget<Card>(
      find
          .ancestor(
            of: find.byKey(
              ValueKey<String>('playlist_card_content_${session.id}'),
            ),
            matching: find.byType(Card),
          )
          .first,
    );
    expect(visualCard.clipBehavior, Clip.antiAlias);
    expect(visualCard.shape, same(playlistRowShape));
    expect(cardContent.padding, playlistRowPadding);
    final cardContentRow = cardContent.child! as Row;
    expect(
      cardContentRow.children.whereType<SizedBox>().any(
        (child) => child.width == 8,
      ),
      isTrue,
    );
    expect(
      tester
          .widget<AsyncLocalCoverImage>(find.byType(AsyncLocalCoverImage))
          .fit,
      BoxFit.cover,
    );

    final errorColor = Theme.of(
      tester.element(find.byType(PlaylistTab)),
    ).colorScheme.error;
    await tester.drag(find.byType(SwipeRevealCard), const Offset(-180, 0));
    await tester.pumpAndSettle();
    final revealPane = tester.widget<DecoratedBox>(
      find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        return widget.child is Stack &&
            decoration is ShapeDecoration &&
            decoration.gradient != null;
      }).first,
    );
    expect(
      (revealPane.decoration as ShapeDecoration).gradient!.colors.last,
      errorColor,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('swiping right pins item to top and swiping right again unpins', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);

    final trackA = MusicTrack(
      path: '/library/Work A/01.mp3',
      displayName: 'Track A',
      groupKey: '/library/Work A',
      groupTitle: 'Work A',
      groupSubtitle: '/library/Work A',
      isSingle: false,
    );
    final trackB = MusicTrack(
      path: '/library/Work B/01.mp3',
      displayName: 'Track B',
      groupKey: '/library/Work B',
      groupTitle: 'Work B',
      groupSubtitle: '/library/Work B',
      isSingle: false,
    );
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[trackA, trackB],
      notify: false,
      persist: false,
    );
    final sessionA = fixture.runtimeGraph.playback.createTrackSession(
      trackA,
      customQueueTracks: <MusicTrack>[trackA],
    );
    final sessionB = fixture.runtimeGraph.playback.createTrackSession(
      trackB,
      customQueueTracks: <MusicTrack>[trackB],
    );
    addTearDown(sessionA.shutdown);
    addTearDown(sessionB.shutdown);

    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[sessionA, sessionB],
      playingSessionCount: 0,
      focusedSessionId: sessionA.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      fixture.build(
        const MobileOverlayInset(bottomInset: 132, child: PlaylistTab()),
      ),
    );
    await tester.pumpAndSettle();

    // Initially, Work A comes before Work B alphabetically.
    expect(find.text('Work A'), findsOneWidget);
    expect(find.text('Work B'), findsOneWidget);
    expect(
      find.byKey(ValueKey<String>('playlist_session_pinned_${sessionB.id}')),
      findsNothing,
    );

    // Swipe right on Work B
    await tester.drag(find.text('Work B'), const Offset(180, 0));
    await tester.pumpAndSettle();

    // The "置顶" button should be revealed
    final pinButtonFinder = find.byTooltip('置顶');
    expect(pinButtonFinder, findsOneWidget);
    final pinIconFinder = find.descendant(
      of: pinButtonFinder,
      matching: find.byIcon(Icons.push_pin_rounded),
    );
    expect(pinIconFinder, findsOneWidget);

    // Tap "置顶"
    await tester.tap(pinButtonFinder);
    await tester.pumpAndSettle();

    // Work B should now have the pinned chip
    expect(
      find.byKey(ValueKey<String>('playlist_session_pinned_${sessionB.id}')),
      findsOneWidget,
    );

    // Work B is now pinned to the top (its Y position is less than Work A)
    final topB = tester.getTopLeft(find.text('Work B')).dy;
    final topA = tester.getTopLeft(find.text('Work A')).dy;
    expect(topB < topA, isTrue);

    // Swipe right on Work B again
    await tester.drag(find.text('Work B'), const Offset(180, 0));
    await tester.pumpAndSettle();

    // The "取消置顶" button should be revealed
    final unpinButtonFinder = find.byTooltip('取消置顶');
    expect(unpinButtonFinder, findsOneWidget);
    expect(
      find.descendant(
        of: unpinButtonFinder,
        matching: find.byIcon(Icons.vertical_align_bottom_rounded),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: unpinButtonFinder,
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );

    // Tap "取消置顶"
    await tester.tap(unpinButtonFinder);
    await tester.pumpAndSettle();

    // Pinned chip is gone
    expect(
      find.byKey(ValueKey<String>('playlist_session_pinned_${sessionB.id}')),
      findsNothing,
    );

    // Work A is back to being before Work B
    final topBAfter = tester.getTopLeft(find.text('Work B')).dy;
    final topAAfter = tester.getTopLeft(find.text('Work A')).dy;
    expect(topAAfter < topBAfter, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'playlist pins and selection use cover corners including placeholders',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
      );
      addTearDown(fixture.dispose);

      final trackWithCover = MusicTrack(
        path: '/library/CoverWork/01.mp3',
        displayName: 'Track With Cover',
        groupKey: '/library/CoverWork',
        groupTitle: 'CoverWork',
        groupSubtitle: '/library/CoverWork',
        isSingle: false,
      );
      final trackWithoutCover = MusicTrack(
        path: '/library/SingleTrack/single.mp3',
        displayName: 'Track No Cover',
        groupKey: '/library/SingleTrack',
        groupTitle: 'SingleTrack',
        groupSubtitle: '',
        isSingle: true,
      );

      final sessionCover = fixture.runtimeGraph.playback.createTrackSession(
        trackWithCover,
        customQueueTracks: <MusicTrack>[trackWithCover],
      );
      final sessionNoCover = fixture.runtimeGraph.playback.createTrackSession(
        trackWithoutCover,
        customQueueTracks: <MusicTrack>[trackWithoutCover],
      );
      final sessionQueueCover =
          fixture.runtimeGraph.playback.createPlaybackQueue('Cover Queue')
            ..currentTrackPath = trackWithCover.path
            ..playbackQueue = PlaybackQueueDefinition(
              name: 'Cover Queue',
              entries: <PlaybackQueueEntry>[
                PlaybackQueueEntry(
                  id: 'cover-entry',
                  kind: PlaybackQueueEntryKind.track,
                  title: trackWithCover.displayName,
                  tracks: <MusicTrack>[trackWithCover],
                ),
              ],
            );
      addTearDown(sessionCover.shutdown);
      addTearDown(sessionNoCover.shutdown);
      addTearDown(sessionQueueCover.shutdown);

      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[
          sessionCover,
          sessionNoCover,
          sessionQueueCover,
        ],
        playingSessionCount: 0,
        focusedSessionId: sessionCover.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      // Pin all three sessions
      await fixture.settingsRepository.togglePlaylistSessionPinned(
        sessionCover.id,
      );
      await fixture.settingsRepository.togglePlaylistSessionPinned(
        sessionNoCover.id,
      );
      await fixture.settingsRepository.togglePlaylistSessionPinned(
        sessionQueueCover.id,
      );

      await tester.pumpWidget(
        fixture.build(
          const MobileOverlayInset(bottomInset: 132, child: PlaylistTab()),
        ),
      );
      await tester.pumpAndSettle();

      // Session with cover: pushpin indicator is at top-right of the cover.
      final pinCoverFinder = find.byKey(
        ValueKey<String>('playlist_session_pinned_${sessionCover.id}'),
      );
      expect(pinCoverFinder, findsOneWidget);
      final coverFinder = find.byKey(
        ValueKey<String>('playlist_cover_${sessionCover.id}'),
      );
      expect(coverFinder, findsOneWidget);
      final coverRect = tester.getRect(coverFinder);
      final pinCoverRect = tester.getRect(pinCoverFinder);
      expect(pinCoverRect.center.dx > coverRect.center.dx, isTrue);
      expect(pinCoverRect.center.dy < coverRect.center.dy, isTrue);

      // Queue cover grid uses the same corner.
      final pinQueueFinder = find.byKey(
        ValueKey<String>('playlist_session_pinned_${sessionQueueCover.id}'),
      );
      expect(pinQueueFinder, findsOneWidget);
      final queueCoverFinder = find.byKey(
        const ValueKey('playback_queue_cover_grid'),
      );
      expect(queueCoverFinder, findsOneWidget);
      final queueCoverRect = tester.getRect(queueCoverFinder);
      final pinQueueRect = tester.getRect(pinQueueFinder);
      expect(pinQueueRect.center.dx > queueCoverRect.center.dx, isTrue);
      expect(pinQueueRect.center.dy < queueCoverRect.center.dy, isTrue);

      // Verify icon is push_pin_rounded
      final pushPinIcon = tester.widget<Icon>(
        find.descendant(of: pinCoverFinder, matching: find.byType(Icon)),
      );
      expect(pushPinIcon.icon, Icons.push_pin_rounded);

      // Verify it is NOT displayed with text '置顶' next to loop mode
      expect(find.text('置顶'), findsNothing);

      final placeholderCover = find.byKey(
        ValueKey<String>('playlist_cover_${sessionNoCover.id}'),
      );
      expect(placeholderCover, findsOneWidget);
      expect(tester.getSize(placeholderCover), const Size.square(52));
      expect(
        find.descendant(
          of: placeholderCover,
          matching: find.byType(CoverFallbackArtwork),
        ),
        findsOneWidget,
      );
      final placeholderIcon = tester.widget<AppBrandIcon>(
        find.descendant(
          of: placeholderCover,
          matching: find.byType(AppBrandIcon),
        ),
      );
      expect(
        placeholderIcon.color,
        Theme.of(tester.element(placeholderCover)).colorScheme.primary,
      );
      final pinNoCoverFinder = find.byKey(
        ValueKey<String>('playlist_session_pinned_${sessionNoCover.id}'),
      );
      expect(pinNoCoverFinder, findsOneWidget);
      final noCoverTextFinder = find.text('Track No Cover');
      final pinNoCoverRect = tester.getRect(pinNoCoverFinder);
      final noCoverTextRect = tester.getRect(noCoverTextFinder);
      final placeholderRect = tester.getRect(placeholderCover);
      expect(pinNoCoverRect.center.dx, greaterThan(placeholderRect.center.dx));
      expect(pinNoCoverRect.center.dy, lessThan(placeholderRect.center.dy));
      expect(noCoverTextRect.left > pinNoCoverRect.right, isTrue);

      // 3. In selection mode (更多模式), select the session without cover
      // Enter selection mode by long-pressing session without cover
      await tester.longPress(noCoverTextFinder);
      await tester.pumpAndSettle();

      final checkmarkFinder = find.byKey(
        ValueKey<String>('playlist_selection_indicator_${sessionNoCover.id}'),
      );
      expect(checkmarkFinder, findsOneWidget);
      final checkmarkRect = tester.getRect(checkmarkFinder);
      final pinNoCoverRectAfter = tester.getRect(pinNoCoverFinder);

      expect(pinNoCoverRectAfter.bottom < checkmarkRect.top, isTrue);
      expect(checkmarkRect.center.dx, pinNoCoverRectAfter.center.dx);
      expect(checkmarkRect.center.dy, greaterThan(placeholderRect.center.dy));

      // 4. In selection mode, select session with cover and verify symmetry
      final trackCoverCardFinder = find.byKey(
        ValueKey<String>('playlist_card_content_${sessionCover.id}'),
      );
      await tester.tap(trackCoverCardFinder, warnIfMissed: false);
      await tester.pumpAndSettle();

      final selectionCoverFinder = find.byKey(
        ValueKey<String>('playlist_selection_indicator_${sessionCover.id}'),
      );
      expect(selectionCoverFinder, findsOneWidget);
      final selectionCoverRect = tester.getRect(selectionCoverFinder);
      final pinCoverRectAfter = tester.getRect(pinCoverFinder);

      expect(pinCoverRectAfter.center.dx, selectionCoverRect.center.dx);
      expect(
        (coverRect.center.dy - pinCoverRectAfter.center.dy).abs(),
        closeTo(
          (selectionCoverRect.center.dy - coverRect.center.dy).abs(),
          0.01,
        ),
      );
      expect(pinCoverRectAfter.width, selectionCoverRect.width);
      expect(pinCoverRectAfter.height, selectionCoverRect.height);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    },
  );

  testWidgets(
    'empty and uncovered playback queues keep a themed placeholder cover',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        notificationsChannel,
        (_) async => <String, Object?>{'ok': true, 'value': null},
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(notificationsChannel, null),
      );
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
      );
      addTearDown(fixture.dispose);
      final session = fixture.runtimeGraph.playback.createPlaybackQueue(
        'Empty queue',
      );
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pumpAndSettle();
      final cover = find.byKey(const ValueKey('playback_queue_cover_grid'));
      expect(cover, findsOneWidget);
      expect(tester.getSize(cover), const Size.square(52));
      final icon = tester.widget<AppBrandIcon>(
        find.descendant(of: cover, matching: find.byType(AppBrandIcon)),
      );
      expect(icon.color, Theme.of(tester.element(cover)).colorScheme.primary);
      expect(
        find.byKey(const ValueKey('playback_queue_cover_dividers')),
        findsNothing,
      );
      expect(
        tester.getRect(cover).right,
        lessThan(tester.getRect(find.text('Empty queue')).left),
      );
      final track = testMusicTrack(
        name: 'Uncovered audio',
        path: '/imports/uncovered.mp3',
        groupKey: '__single_files__',
        groupTitle: 'Imported files',
        isSingle: true,
      );
      session
        ..currentTrackPath = track.path
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'Empty queue',
          entries: [
            PlaybackQueueEntry(
              id: 'uncovered',
              kind: PlaybackQueueEntryKind.track,
              title: track.displayName,
              tracks: [track],
            ),
          ],
        );
      fixture.playbackService.markActiveSessionsDirty();
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: cover, matching: find.byType(AppBrandIcon)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('playback_queue_cover_dividers')),
        findsNothing,
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('PlaylistSelectionIndicator performs 450ms fade-in and fade-out', (
    tester,
  ) async {
    final checkmarkFinder = find.byKey(
      const ValueKey<String>('playlist_selection_indicator_session-fade-test'),
    );

    // Initial state: not selected, indicator child is hidden
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaylistSelectionIndicator(
            sessionId: 'session-fade-test',
            isSelected: false,
          ),
        ),
      ),
    );

      expect(checkmarkFinder, findsNothing);

    // Transition to selected
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaylistSelectionIndicator(
            sessionId: 'session-fade-test',
            isSelected: true,
          ),
        ),
      ),
    );

    // First frame after change: AnimatedSwitcher creates the child
    await tester.pump();
    expect(checkmarkFinder, findsOneWidget);

    final animatedSwitcherFinder = find.byType(AnimatedSwitcher);
    final switcher = tester.widget<AnimatedSwitcher>(animatedSwitcherFinder);
    expect(switcher.duration, const Duration(milliseconds: 450));
    expect(switcher.reverseDuration, const Duration(milliseconds: 450));

    // Mid-animation: at 225ms, opacity is partial (0 < opacity < 1)
    await tester.pump(const Duration(milliseconds: 225));
    final fadeTransitionFinder = find
        .ancestor(of: checkmarkFinder, matching: find.byType(FadeTransition))
        .first;
    expect(fadeTransitionFinder, findsOneWidget);
    final midOpacity = tester
        .widget<FadeTransition>(fadeTransitionFinder)
        .opacity
        .value;
    expect(midOpacity, greaterThan(0.0));
    expect(midOpacity, lessThan(1.0));

    // After remaining 225ms (450ms total), opacity reaches 1.0
    await tester.pump(const Duration(milliseconds: 225));
    final fullOpacity = tester
        .widget<FadeTransition>(fadeTransitionFinder)
        .opacity
        .value;
    expect(fullOpacity, closeTo(1.0, 0.001));

    // Now deselect: transition to isSelected = false
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaylistSelectionIndicator(
            sessionId: 'session-fade-test',
            isSelected: false,
          ),
        ),
      ),
    );

    // Mid reverse-animation: at 225ms, checkmark is still present and fading out
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 225));
    expect(checkmarkFinder, findsOneWidget);
    final fadeOutOpacity = tester
        .widget<FadeTransition>(fadeTransitionFinder)
        .opacity
        .value;
    expect(fadeOutOpacity, greaterThan(0.0));
    expect(fadeOutOpacity, lessThan(1.0));

    // After remaining reverse duration (total 475ms > 450ms), checkmark finishes fading out and is removed
    await tester.pump(const Duration(milliseconds: 250));
    expect(checkmarkFinder, findsNothing);

    // Verify reduced motion uses Duration.zero
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: PlaylistSelectionIndicator(
              sessionId: 'session-fade-test',
              isSelected: true,
            ),
          ),
        ),
      ),
    );
    final disabledSwitcher = tester.widget<AnimatedSwitcher>(
      animatedSwitcherFinder,
    );
    expect(disabledSwitcher.duration, Duration.zero);
    expect(disabledSwitcher.reverseDuration, Duration.zero);
  });

  testWidgets('playlist cards show loading spinners without loading text', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final track = MusicTrack(
      path: '/library/work/loading.mp3',
      displayName: 'Loading track',
      groupKey: '/library/work',
      groupTitle: 'Work',
      groupSubtitle: '/library/work',
      isSingle: false,
    );
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[track],
      notify: false,
      persist: false,
    );
    final trackSession = fixture.runtimeGraph.playback.createTrackSession(track)
      ..state = const PlayerState(true, ProcessingState.buffering)
      ..beginPreparation(showLoading: true, autoPlay: true);
    final queueSession =
        fixture.runtimeGraph.playback.createPlaybackQueue('Loading queue')
          ..state = const PlayerState(true, ProcessingState.buffering)
          ..currentTrackPath = track.path
          ..playbackQueue = PlaybackQueueDefinition(
            name: 'Loading queue',
            entries: <PlaybackQueueEntry>[
              PlaybackQueueEntry(
                id: 'loading-entry',
                kind: PlaybackQueueEntryKind.track,
                title: track.displayName,
                tracks: <MusicTrack>[track],
              ),
            ],
          )
          ..beginPreparation(showLoading: true, autoPlay: true);
    addTearDown(trackSession.shutdown);
    addTearDown(queueSession.shutdown);
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[trackSession, queueSession],
      playingSessionCount: 2,
      focusedSessionId: trackSession.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pump();

    expect(
      find.text(fixture.languageProvider.tr('playback_loading')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('loading')), findsNothing);
    await tester.pump(PlaybackSession.loadingIndicatorThreshold);
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[trackSession, queueSession],
      playingSessionCount: 2,
      focusedSessionId: trackSession.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('loading')), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('failed playlist item keeps play control without retry text', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
    );
    addTearDown(fixture.dispose);
    final track = MusicTrack(
      path: '/library/work/failed.mp3',
      displayName: 'Failed track',
      groupKey: '/library/work',
      groupTitle: 'Work',
      groupSubtitle: '',
      isSingle: false,
    );
    fixture.library.addTracks([track], notify: false, persist: false);
    final session = fixture.playback.createTrackSession(track)
      ..finishPreparation(
        0,
        prepared: false,
        autoPlay: false,
        error: 'playback failed',
      );
    addTearDown(session.shutdown);
    fixture.playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('playlist_card_content_${session.id}')),
      findsOneWidget,
    );
    expect(find.byTooltip(fixture.languageProvider.tr('play')), findsOneWidget);
    expect(
      find.text(fixture.languageProvider.tr('playback_failed_retry')),
      findsNothing,
    );
  });

  testWidgets('playlist card, playback card and detail share a decoded cover', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
    );
    addTearDown(fixture.dispose);
    final track = testMusicTrack(
      name: 'Shared cover',
      path: '/library/track.mp3',
      groupKey: '/library',
      groupTitle: 'Library',
    );
    fixture.runtimeGraph.library.addTracks(
      [track],
      notify: false,
      persist: false,
    );
    final session = fixture.runtimeGraph.playback.createTrackSession(
      track,
      customQueueTracks: [track],
    );
    addTearDown(session.shutdown);
    fixture.playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pumpAndSettle();
    Future<Object> imageKey(AsyncLocalCoverImage cover) =>
        resizeFileImageIfNeeded(
          path: '/covers/shared.png',
          cacheWidth: cover.cacheWidth,
          cacheHeight: cover.cacheHeight,
          useDefaultCacheWidth: cover.useDefaultCacheWidth,
        ).obtainKey(ImageConfiguration.empty);
    final cardKey = await imageKey(
      tester.widget<AsyncLocalCoverImage>(
        find.byType(AsyncLocalCoverImage).first,
      ),
    );
    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: session.id)),
    );
    await tester.pumpAndSettle();
    final detailKey = await imageKey(
      tester.widget<AsyncLocalCoverImage>(
        find.byType(AsyncLocalCoverImage).first,
      ),
    );
    expect(detailKey, cardKey);
    await tester.pumpWidget(
      fixture.build(
        ActiveSessionCarousel(
          sessions: [PlaybackSessionSnapshot.fromRuntime(session)],
          onOpenSession: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      await imageKey(
        tester.widget<AsyncLocalCoverImage>(
          find.byType(AsyncLocalCoverImage).first,
        ),
      ),
      cardKey,
    );
  });

  testWidgets('temporary video detail updates when only loadedPath changes', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
    );
    addTearDown(fixture.dispose);
    final tracks = [
      for (final name in ['first', 'second'])
        testMusicTrack(
          name: name,
          path: PathMatcher.normalize('/videos/$name.mp4'),
          groupKey: PathMatcher.normalize('/videos'),
          groupTitle: 'Videos',
        ).copyWith(isVideo: true),
    ];
    fixture.runtimeGraph.library.addTracks(
      tracks,
      notify: false,
      persist: false,
    );
    final session = fixture.runtimeGraph.playback.createTrackSession(tracks[0])
      ..isTemporary = true
      ..setOptimisticState(playing: true);
    void sync() => fixture.playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    sync();
    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pumpAndSettle();
    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: session.id)),
    );
    await tester.pumpAndSettle();
    final subtitleMenuButton = find.byKey(
      const ValueKey('session_subtitle_menu_button'),
    );
    expect(
      tester
          .widget<IconButton>(
            find.descendant(
              of: subtitleMenuButton,
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNotNull,
    );
    bool videoReady() => tester
        .widget<SessionVideoViewport>(find.byType(SessionVideoViewport))
        .videoReady;
    expect(videoReady(), isFalse);

    session.loadedPath = tracks[0].path;
    sync();
    await tester.pumpAndSettle();
    expect(videoReady(), isTrue);

    session.currentTrackPath = tracks[1].path;
    sync();
    await tester.pumpAndSettle();
    expect(videoReady(), isFalse);
    session.loadedPath = tracks[1].path;
    sync();
    await tester.pumpAndSettle();
    expect(videoReady(), isTrue);

    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = originalPlatform);
    await tester.tap(
      find.byKey(const ValueKey<String>('session_video_tap_target')),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(
      find.byType(NativeSessionVideoSurface, skipOffstage: false),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('fullscreen_video_exit')),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    // The outgoing fullscreen route still owns the only video surface.
    expect(
      find.byType(NativeSessionVideoSurface, skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(SessionVideoViewport, skipOffstage: false),
        matching: find.byType(NativeSessionVideoSurface, skipOffstage: false),
      ),
      findsNothing,
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(SessionVideoViewport),
        matching: find.byType(NativeSessionVideoSurface),
      ),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = originalPlatform;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'portrait video fullscreen returns its only surface to landscape detail',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final track = testMusicTrack(
        name: 'Video',
        path: '/videos/rotation.mp4',
        groupKey: '/videos',
        groupTitle: 'Videos',
      ).copyWith(isVideo: true);
      final setup = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
        queueTracks: [track],
        physicalSize: const Size(2880, 3840),
        overrides: [
          appOrientationControllerProvider.overrideWithValue(
            AppOrientationController(
              setPreferredOrientations: (_) async {},
              setSystemUiMode: (_) async {},
            ),
          ),
        ],
      );
      final session = setup.session
        ..loadedPath = track.path
        ..setOptimisticState(playing: true);
      setup.fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 1,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpAndSettle();
      final inlineViewport = find.byType(
        SessionVideoViewport,
        skipOffstage: false,
      );
      final originalState = tester.state(inlineViewport);
      expect(
        tester.widget<SessionDetailContent>(find.byType(SessionDetailContent))
            .isLandscape,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('session_video_tap_target')));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(SessionVideoFullscreenPage), findsOneWidget);
      expect(
        find.byType(NativeSessionVideoSurface, skipOffstage: false),
        findsOneWidget,
      );

      tester.view.physicalSize = const Size(3840, 2880);
      await tester.pumpAndSettle();
      expect(tester.state(inlineViewport), same(originalState));
      expect(
        find.descendant(
          of: inlineViewport,
          matching: find.byType(NativeSessionVideoSurface, skipOffstage: false),
        ),
        findsNothing,
      );
      expect(
        find.byType(NativeSessionVideoSurface, skipOffstage: false),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('fullscreen_video_exit')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SessionVideoFullscreenPage), findsNothing);
      expect(
        tester.widget<SessionDetailContent>(find.byType(SessionDetailContent))
            .isLandscape,
        isTrue,
      );
      expect(
        find.descendant(
          of: inlineViewport,
          matching: find.byType(NativeSessionVideoSurface),
        ),
        findsOneWidget,
      );
      expect(tester.state(inlineViewport), same(originalState));
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'single-file queue cover fills the card and switcher shows an audio entry',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final persistenceRepository = fixture.persistenceRepository;
      final nativePlaybackRepository = fixture.nativePlaybackRepository;
      const playbackCommandRunner =
          AppRuntimeWidgetTestFixture.playbackCommandRunner;
      final libraryService = fixture.libraryService;
      final playbackService = fixture.playbackService;
      final timerService = fixture.timerService;
      final notificationCoordinatorService =
          fixture.notificationCoordinatorService;
      final settingsRepository = fixture.settings;
      final languageProvider = fixture.languageProvider;
      final track = MusicTrack(
        path: '/imports/standalone.mp4',
        displayName: 'Standalone clip',
        groupKey: '__single_files__',
        groupTitle: 'Imported files',
        groupSubtitle: 'Manually selected files',
        isSingle: true,
        isVideo: true,
      );
      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final queueSession = runtimeGraph.playback.createPlaybackQueue('Queue 1');
      addTearDown(queueSession.shutdown);
      queueSession
        ..currentTrackPath = track.path
        ..currentQueueIndex = 0
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'Queue 1',
          entries: <PlaybackQueueEntry>[
            PlaybackQueueEntry(
              id: 'legacy-single-work',
              kind: PlaybackQueueEntryKind.work,
              title: 'Imported files',
              tracks: <MusicTrack>[track],
            ),
          ],
        );
      playbackService.syncSlice(
        activeSessions: <PlaybackSession>[queueSession],
        playingSessionCount: 0,
        focusedSessionId: queueSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: runtimeGraph,
          persistenceRepository: persistenceRepository,
          nativePlaybackRepository: nativePlaybackRepository,
          playbackCommandRunner: playbackCommandRunner,
          libraryService: libraryService,
          playbackService: playbackService,
          timerService: timerService,
          notificationCoordinatorService: notificationCoordinatorService,
          settingsRepository: settingsRepository,
          languageProvider: languageProvider,
          child: const PlaylistTab(),
        ),
      );
      await tester.pumpAndSettle();

      final grid = find.byKey(const ValueKey('playback_queue_cover_grid'));
      final firstCell = find.byKey(
        const ValueKey('playback_queue_cover_cell_0'),
      );
      expect(tester.getSize(grid), const Size.square(52));
      expect(tester.getSize(firstCell), const Size.square(52));

      unawaited(
        Navigator.of(
          tester.element(find.byType(PlaylistTab)),
        ).push(buildSessionDetailRoute(sessionId: queueSession.id)),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(find.byType(SessionVideoBlurredBackdrop), findsOneWidget);
      await settingsRepository.setAllowVideoPlayback(false);
      expect(settingsRepository.slice.state.allowVideoPlayback, isFalse);
      await tester.pumpAndSettle();
      expect(find.byType(SessionVideoBlurredBackdrop), findsNothing);
      expect(queueSession.currentTrackPath, track.path);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('playback_secondary_controls')))
            .width,
        366,
      );
      final secondaryControls = find.byKey(
        const ValueKey('playback_secondary_controls'),
      );
      final secondaryButtons = find.descendant(
        of: secondaryControls,
        matching: find.byType(IconButton),
      );
      expect(secondaryButtons, findsNWidgets(6));
      final buttonCenters = List<double>.generate(
        6,
        (index) => tester.getCenter(secondaryButtons.at(index)).dx,
      );
      final intervals = List<double>.generate(
        buttonCenters.length - 1,
        (index) => buttonCenters[index + 1] - buttonCenters[index],
      );
      for (final interval in intervals) {
        expect(interval, closeTo(intervals.first, 1.0));
      }
      expect(
        tester.getTopLeft(secondaryButtons.first).dx,
        greaterThanOrEqualTo(tester.getTopLeft(secondaryControls).dx),
      );
      expect(find.byType(ImageFiltered), findsNothing);
      await tester.tap(find.byTooltip(languageProvider.tr('switch_audio')));
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text(track.displayName)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(languageProvider.tr('imported_files')),
        ),
        findsNothing,
      );
      final selectedMaterial = tester.widget<Material>(
        find.byKey(ValueKey<String>('queue_switcher_track_${track.path}')),
      );
      expect(
        selectedMaterial.borderRadius,
        const BorderRadius.all(Radius.circular(12)),
      );
      expect(selectedMaterial.clipBehavior, Clip.antiAlias);
    },
  );

  testWidgets('timeline subtitle follows native progress without input', (
    tester,
  ) async {
    final harness = await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: SubtitleTrack(
        sourcePath: 'automatic.srt',
        cues: List.generate(
          4,
          (index) => SubtitleCue(
            start: Duration(seconds: index * 2),
            end: Duration(seconds: (index + 1) * 2),
            text: 'Automatic cue $index',
          ),
        ),
      ),
      initialPosition: Duration.zero,
    );
    for (var index = 1; index < 4; index++) {
      harness.session.applyNativeProgress(
        NativePlaybackProgressUpdate(
          sessionId: harness.session.id,
          position: Duration(seconds: index * 2),
          bufferedPosition: const Duration(seconds: 8),
          nativeElapsedRealtimeMs: index * 2000,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      final cue = find.byKey(ValueKey('subtitle_timeline_cue_$index'));
      final viewport = find.byKey(const ValueKey('subtitle_timeline_viewport'));
      expect(
        tester.getCenter(cue).dy,
        closeTo(tester.getCenter(viewport).dy, 0.5),
      );
    }
  });

  testWidgets(
    'standalone subtitle panel ignores stale paths and late completion',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final session = PlaybackSession(
        id: 'standalone-subtitle',
        currentTrackPath: '/subtitle/old.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(session.shutdown);
      final pending = <String, Completer<SubtitleTrack?>>{};
      var loadCalls = 0;
      final subtitleService = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitleLoader: (path, _) {
          loadCalls++;
          return pending
              .putIfAbsent(path, Completer<SubtitleTrack?>.new)
              .future;
        },
      );
      Widget panel() => fixture.build(
        SessionSubtitlePanel(
          key: const ValueKey('standalone-subtitle-panel'),
          session: PlaybackSessionSnapshot.fromRuntime(session),
        ),
        subtitleService: subtitleService,
      );
      await tester.pumpWidget(panel());
      expect(pending.keys, ['/subtitle/old.mp3']);
      session.currentTrackPath = '/subtitle/latest.mp3';
      await tester.pumpWidget(panel());
      pending['/subtitle/latest.mp3']!.complete(
        SubtitleTrack(
          sourcePath: '/subtitle/latest.srt',
          cues: const [
            SubtitleCue(
              start: Duration.zero,
              end: Duration(seconds: 5),
              text: 'Latest subtitle',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Latest subtitle'), findsOneWidget);
      pending['/subtitle/old.mp3']!.complete(
        SubtitleTrack(
          sourcePath: '/subtitle/old.srt',
          cues: const [
            SubtitleCue(
              start: Duration.zero,
              end: Duration(seconds: 5),
              text: 'Stale subtitle',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Latest subtitle'), findsOneWidget);
      expect(find.text('Stale subtitle'), findsNothing);
      await tester.pumpWidget(panel());
      expect(pending, hasLength(2));
      expect(loadCalls, 2);

      session.currentTrackPath = '/subtitle/exited.mp3';
      await tester.pumpWidget(panel());
      expect(pending, hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
      pending['/subtitle/exited.mp3']!.complete(null);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail loading subtitle fades while the cover remains fixed at 4:3',
    (tester) async {
      final subtitleTrack = SubtitleTrack(
        sourcePath: '/library/subtitles/empty.srt',
        cues: <SubtitleCue>[],
      );
      final result = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: subtitleTrack,
        initialPosition: Duration.zero,
      );
      final placeholderFinder = find.byKey(const ValueKey('subtitle_loading'));
      final cover = find.byKey(
        const ValueKey('session_detail_cover_subtitle-session'),
      );
      final initialCoverHeight = tester.getSize(cover).height;
      expect(initialCoverHeight, 270.0);

      result.session.beginPreparation(showLoading: true, autoPlay: true);
      result.fixture.playbackService.markActiveSessionsDirty();
      result.fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[result.session],
        playingSessionCount: 1,
        focusedSessionId: result.session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await pumpUntilFound(tester, placeholderFinder);
      await tester.pump(const Duration(milliseconds: 110));

      final fadeIn = tester.widget<FadeTransition>(
        find.byKey(
          const ValueKey<Object>((
            'subtitle_fade',
            ValueKey<String>('subtitle_loading'),
          )),
        ),
      );
      expect(fadeIn.opacity.value, greaterThan(0));
      expect(fadeIn.opacity.value, lessThan(1));
      final midCoverHeight = tester.getSize(cover).height;
      expect(midCoverHeight, 270.0);

      await tester.pump(const Duration(milliseconds: 350));
      final loadingCoverHeight = tester.getSize(cover).height;
      expect(loadingCoverHeight, 270.0);

      result.session.finishPreparation(
        result.session.loadGeneration,
        prepared: false,
        autoPlay: true,
      );
      result.fixture.playbackService.markActiveSessionsDirty();
      result.fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[result.session],
        playingSessionCount: 0,
        focusedSessionId: result.session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey('subtitle_empty')),
      );
      await tester.pump(const Duration(milliseconds: 110));

      expect(placeholderFinder, findsOneWidget);
      final fadeOut = tester.widget<FadeTransition>(
        find.byKey(
          const ValueKey<Object>((
            'subtitle_fade',
            ValueKey<String>('subtitle_loading'),
          )),
        ),
      );
      expect(fadeOut.opacity.value, greaterThan(0));
      expect(fadeOut.opacity.value, lessThan(1));

      await tester.pump(const Duration(milliseconds: 400));
      expect(placeholderFinder, findsNothing);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.getSize(cover).height, 270.0);
    },
  );

  testWidgets(
    'detail subtitle prioritizes placeholder while loading and transitions when ready',
    (tester) async {
      final pendingSubtitle = Completer<SubtitleTrack?>();
      await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: '', cues: []),
        subtitleResult: pendingSubtitle.future,
        initialPosition: Duration.zero,
      );

      final placeholderFinder = find.byKey(const ValueKey('subtitle_loading'));
      final emptyFinder = find.byKey(const ValueKey('subtitle_empty'));

      // Initially, subtitle is pending; placeholder must be shown, not empty text.
      await pumpUntilFound(tester, placeholderFinder);
      expect(placeholderFinder, findsOneWidget);
      expect(emptyFinder, findsNothing);

      // Complete the subtitle with cues
      pendingSubtitle.complete(
        SubtitleTrack(
          sourcePath: '/library/subtitles/ready.srt',
          cues: const [
            SubtitleCue(
              start: Duration.zero,
              end: Duration(seconds: 4),
              text: 'Loaded cue line',
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.text('Loaded cue line'), findsOneWidget);
      expect(placeholderFinder, findsNothing);
      expect(emptyFinder, findsNothing);
    },
  );

  testWidgets(
    'timeline subtitles scroll, snap, return, and seek while paused',
    (tester) async {
      final subtitleTrack = SubtitleTrack(
        sourcePath: '/library/subtitles/track.srt',
        cues: <SubtitleCue>[
          const SubtitleCue(
            start: Duration.zero,
            end: Duration(seconds: 2),
            text: 'Cue zero',
          ),
          const SubtitleCue(
            start: Duration(seconds: 2),
            end: Duration(seconds: 4),
            text: 'Cue one wraps onto a centered second line',
          ),
          const SubtitleCue(
            start: Duration(seconds: 4),
            end: Duration(seconds: 6),
            text: 'Cue two',
          ),
        ],
      );
      final result = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: subtitleTrack,
        initialPosition: const Duration(milliseconds: 2500),
      );
      void syncSession({required bool playing}) {
        result.fixture.playbackService
          ..markActiveSessionsDirty()
          ..syncSlice(
            activeSessions: <PlaybackSession>[result.session],
            playingSessionCount: playing ? 1 : 0,
            focusedSessionId: result.session.id,
            coverGeneration: 0,
            isInitialized: true,
          );
      }

      final viewport = find.byKey(
        const ValueKey<String>('subtitle_timeline_viewport'),
      );
      await pumpUntilFound(tester, viewport);
      await tester.pumpAndSettle();

      final cue0 = find.byKey(
        const ValueKey<String>('subtitle_timeline_cue_0'),
      );
      final cue1 = find.byKey(
        const ValueKey<String>('subtitle_timeline_cue_1'),
      );
      final cue2 = find.byKey(
        const ValueKey<String>('subtitle_timeline_cue_2'),
      );
      Opacity opacityFor(Finder cue) => tester.widget<Opacity>(
        find.ancestor(of: cue, matching: find.byType(Opacity)).first,
      );

      expect(tester.getSize(viewport).height, 288.0);
      expect(opacityFor(cue0).opacity, 0.30);
      expect(opacityFor(cue1).opacity, 1);
      expect(opacityFor(cue2).opacity, 0.30);
      expect(
        tester.getCenter(cue1).dy,
        closeTo(tester.getCenter(viewport).dy, 0.1),
      );
      expect(
        find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
        findsNothing,
      );
      expect(
        tester.widget<Text>(find.text(subtitleTrack.cues[1].text)).textAlign,
        TextAlign.center,
      );
      final focusedText = tester.widget<Text>(
        find.byKey(const ValueKey<String>('subtitle_timeline_text_1')),
      );
      final unfocusedText = tester.widget<Text>(
        find.byKey(const ValueKey<String>('subtitle_timeline_text_0')),
      );
      final textPadding = tester.widget<Padding>(
        find.byKey(const ValueKey<String>('subtitle_timeline_text_padding_1')),
      );
      expect(focusedText.style?.fontSize, 16);
      expect(unfocusedText.style?.fontSize, 14);
      expect(focusedText.maxLines, isNull);
      expect(focusedText.overflow, isNull);
      expect(
        textPadding.padding,
        const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      );

      final list = find.byKey(const ValueKey<String>('subtitle_timeline_list'));
      expect(
        tester.widget<ListView>(list).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
      );
      final fixedCenter = tester.getCenter(cue1);
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -70));
      await tester.pump();
      expect(tester.getCenter(cue1).dy, lessThan(fixedCenter.dy));
      expect(opacityFor(cue2).opacity, 1);
      await gesture.up();
      await tester.pump();
      expect(opacityFor(cue2).opacity, 1);
      expect(
        tester.getCenter(cue2).dy,
        closeTo(tester.getCenter(viewport).dy, 1.0),
      );
      expect(
        find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 2500));
      expect(opacityFor(cue2).opacity, 1);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(opacityFor(cue1).opacity, 1);

      result.session
        ..setOptimisticState(playing: true)
        ..setOptimisticPosition(const Duration(milliseconds: 3900));
      syncSession(playing: true);
      await tester.pump();
      final playingGesture = await tester.startGesture(tester.getCenter(list));
      await playingGesture.moveBy(const Offset(0, -30));
      await tester.pump();
      final draggedCueCenter = tester.getCenter(cue1);
      result.session.setOptimisticPosition(const Duration(milliseconds: 4100));
      syncSession(playing: true);
      await tester.pump();
      expect(opacityFor(cue1).opacity, 1);
      expect(tester.getCenter(cue1), draggedCueCenter);
      await playingGesture.moveBy(const Offset(0, -36));
      await playingGesture.up();
      await tester.pump();
      expect(opacityFor(cue2).opacity, 1);
      result.session
        ..setOptimisticState(playing: false)
        ..setOptimisticPosition(const Duration(milliseconds: 2500));
      syncSession(playing: false);
      await tester.pump(const Duration(milliseconds: 40));

      await tester.drag(list, const Offset(0, -100));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
      );
      await tester.pump();

      expect(result.session.position, const Duration(seconds: 4));
      expect(result.session.state.playing, isFalse);
      expect(
        find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
        findsNothing,
      );
      await tester.pump(PlaybackSession.loadingIndicatorThreshold);
    },
  );

  for (final browsingDelta in [null, -24, 24]) {
    testWidgets(
      'timeline preloads cues before reaching the window edge ($browsingDelta)',
      (tester) async {
        const initialIndex = 120;
        final harness = await _pumpSubtitleDetail(
          tester: tester,
          physicalSize: defaultTargetPlatform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1080, 2400),
          subtitleTrack: SubtitleTrack(
            sourcePath: 'preload.srt',
            cues: List.generate(
              240,
              (index) => SubtitleCue(
                start: Duration(seconds: index * 2),
                end: Duration(seconds: (index + 1) * 2),
                text: 'Preload cue $index',
              ),
            ),
          ),
          initialPosition: const Duration(seconds: initialIndex * 2),
        );
        final listFinder = find.byKey(const ValueKey('subtitle_timeline_list'));
        int itemCount() => tester
            .widget<ListView>(listFinder)
            .childrenDelegate
            .estimatedChildCount!;
        final initialCount = itemCount();
        final targetIndex = initialIndex + (browsingDelta ?? 24);
        TestGesture? gesture;
        if (browsingDelta == null) {
          harness.session.applyNativeProgress(
            NativePlaybackProgressUpdate(
              sessionId: harness.session.id,
              position: Duration(seconds: targetIndex * 2),
              bufferedPosition: const Duration(seconds: 480),
              nativeElapsedRealtimeMs: targetIndex * 2000,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
        } else {
          gesture = await tester.startGesture(tester.getCenter(listFinder));
          final controller = tester.widget<ListView>(listFinder).controller!;
          final extent = tester
              .getSize(
                find.byKey(
                  const ValueKey('subtitle_timeline_cue_$initialIndex'),
                ),
              )
              .height;
          controller.jumpTo(controller.offset + browsingDelta * extent);
          await tester.pump();
          await tester.pump();
        }
        expect(itemCount(), greaterThan(initialCount));
        expect(itemCount(), lessThan(240));
        final viewport = find.byKey(
          const ValueKey('subtitle_timeline_viewport'),
        );
        final focused = find.byKey(
          ValueKey('subtitle_timeline_cue_$targetIndex'),
        );
        expect(
          tester.getCenter(focused).dy,
          closeTo(tester.getCenter(viewport).dy, 0.5),
        );
        await gesture?.up();
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('timeline subtitles lazily expand a bounded cue window', (
    tester,
  ) async {
    const cueCount = 240;
    const playbackIndex = 120;
    final subtitleTrack = SubtitleTrack(
      sourcePath: '/library/subtitles/large-track.srt',
      cues: List<SubtitleCue>.generate(cueCount, (index) {
        final start = Duration(seconds: index * 2);
        return SubtitleCue(
          start: start,
          end: start + const Duration(seconds: 2),
          text: 'Cue $index',
        );
      }),
    );
    await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: subtitleTrack,
      initialPosition: const Duration(seconds: playbackIndex * 2),
    );
    final listFinder = find.byKey(
      const ValueKey<String>('subtitle_timeline_list'),
    );
    await pumpUntilFound(tester, listFinder);
    await tester.pumpAndSettle();

    final initialItemCount = tester
        .widget<ListView>(listFinder)
        .childrenDelegate
        .estimatedChildCount!;
    expect(initialItemCount, lessThan(cueCount));
    expect(
      find.byKey(
        const ValueKey<String>('subtitle_timeline_text_$playbackIndex'),
      ),
      findsOneWidget,
    );

    await tester.drag(listFinder, const Offset(0, -10000));
    await tester.pumpAndSettle();

    final expandedItemCount = tester
        .widget<ListView>(listFinder)
        .childrenDelegate
        .estimatedChildCount!;
    expect(expandedItemCount, greaterThan(initialItemCount));
    expect(expandedItemCount, lessThan(cueCount));

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('timeline subtitles expand beyond two lines without clipping', (
    tester,
  ) async {
    const subtitleText = 'Line one\nLine two\nLine three\nLine four\nLine five';
    final subtitleTrack = SubtitleTrack(
      sourcePath: '/library/subtitles/long-track.srt',
      cues: <SubtitleCue>[
        const SubtitleCue(
          start: Duration.zero,
          end: Duration(seconds: 5),
          text: subtitleText,
        ),
      ],
    );
    await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: subtitleTrack,
      initialPosition: const Duration(seconds: 1),
    );

    final viewport = find.byKey(
      const ValueKey<String>('subtitle_timeline_viewport'),
    );
    final cue = find.byKey(const ValueKey<String>('subtitle_timeline_cue_0'));
    final text = tester.widget<Text>(
      find.byKey(const ValueKey<String>('subtitle_timeline_text_0')),
    );

    expect(text.maxLines, isNull);
    expect(text.overflow, isNull);
    expect(tester.getSize(cue).height, greaterThan(96));
    expect(
      tester.getSize(viewport).height,
      greaterThanOrEqualTo(tester.getSize(cue).height),
    );
  });

  testWidgets('timeline subtitle focus changes provide rate-limited haptics', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    AppInteractionFeedback.resetContinuous();
    AppInteractionFeedback.hapticFeedbackEnabled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      AppInteractionFeedback.resetContinuous();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final subtitleTrack = SubtitleTrack(
      sourcePath: '/library/subtitles/track.srt',
      cues: <SubtitleCue>[
        const SubtitleCue(
          start: Duration.zero,
          end: Duration(seconds: 2),
          text: 'Cue zero',
        ),
        const SubtitleCue(
          start: Duration(seconds: 2),
          end: Duration(seconds: 4),
          text: 'Cue one',
        ),
        const SubtitleCue(
          start: Duration(seconds: 4),
          end: Duration(seconds: 6),
          text: 'Cue two',
        ),
      ],
    );
    await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: subtitleTrack,
      initialPosition: const Duration(seconds: 2),
    );

    final list = find.byKey(const ValueKey<String>('subtitle_timeline_list'));
    await tester.drag(list, const Offset(0, -52));
    await tester.pumpAndSettle();

    expect(
      calls.where((call) => call.method == 'HapticFeedback.vibrate'),
      hasLength(1),
    );
  });

  testWidgets(
    'playlist multiselect overlays indicators and swaps batch transport actions',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
      );
      addTearDown(fixture.dispose);
      final nativeCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            nativeCalls.add(call);
            return <String, Object?>{'ok': true, 'value': null};
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, null);
      });

      final track = testMusicTrack(
        name: 'Selection track',
        path: PathMatcher.normalize('/library/regular/track.mp3'),
        groupKey: PathMatcher.normalize('/library/regular'),
        groupTitle: 'Selection work',
      );
      final queueTrack = testMusicTrack(
        name: 'Queue selection track',
        path: PathMatcher.normalize('/library/queue/queue.mp3'),
        groupKey: PathMatcher.normalize('/library/queue'),
        groupTitle: 'Queue selection work',
      );
      final queueWorkTrack = testMusicTrack(
        name: 'Queue work first track',
        path: PathMatcher.normalize('/library/queue-work/first.mp3'),
        groupKey: PathMatcher.normalize('/library/queue-work'),
        groupTitle: 'Queue source work',
      );
      final secondQueueWorkTrack = testMusicTrack(
        name: 'Queue work second track',
        path: PathMatcher.normalize('/library/queue-work/second.mp3'),
        groupKey: PathMatcher.normalize('/library/queue-work'),
        groupTitle: 'Queue source work',
      );
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track, queueTrack, queueWorkTrack, secondQueueWorkTrack],
        notify: false,
        persist: false,
      );
      final trackSession = fixture.runtimeGraph.playback.createTrackSession(
        track,
      )..state = const PlayerState(false, ProcessingState.ready);
      final queueSession =
          fixture.runtimeGraph.playback.createPlaybackQueue('Selection queue')
            ..currentTrackPath = queueTrack.path
            ..state = const PlayerState(true, ProcessingState.ready)
            ..playbackQueue = PlaybackQueueDefinition(
              name: 'Selection queue',
              entries: <PlaybackQueueEntry>[
                PlaybackQueueEntry(
                  id: 'selection-queue-entry',
                  kind: PlaybackQueueEntryKind.track,
                  title: queueTrack.displayName,
                  tracks: <MusicTrack>[queueTrack],
                ),
                PlaybackQueueEntry(
                  id: 'selection-queue-work-entry',
                  kind: PlaybackQueueEntryKind.work,
                  title: 'Queue source work',
                  workRootPath: PathMatcher.normalize('/library/queue-work'),
                  tracks: <MusicTrack>[queueWorkTrack, secondQueueWorkTrack],
                ),
              ],
            );
      fixture.playbackService.markSessionStateDirty();
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[trackSession, queueSession],
        playingSessionCount: 1,
        focusedSessionId: queueSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      final trackTitle = find.text(track.displayName);
      final queueTitle = find.text('Selection queue');
      await pumpUntilFound(tester, trackTitle);
      await pumpUntilFound(tester, queueTitle);
      await tester.pumpAndSettle();

      final trackContentFinder = find.byKey(
        ValueKey<String>('playlist_card_content_${trackSession.id}'),
      );
      final queueContentFinder = find.byKey(
        ValueKey<String>('playback_queue_card_content_${queueSession.id}'),
      );
      final trackCardRect = tester.getRect(trackContentFinder);
      final queueCardRect = tester.getRect(queueContentFinder);
      final trackButton = find.descendant(
        of: trackContentFinder,
        matching: find.byType(IconButton),
      );
      final queueButton = find.descendant(
        of: queueContentFinder,
        matching: find.byType(IconButton),
      );
      final trackButtonRect = tester.getRect(trackButton);
      final queueButtonRect = tester.getRect(queueButton);

      expect(queueCardRect.height, closeTo(trackCardRect.height, 0.01));
      expect(
        queueButtonRect.center.dx,
        closeTo(trackButtonRect.center.dx, 0.01),
      );
      expect(
        queueButtonRect.right - queueCardRect.right,
        closeTo(trackButtonRect.right - trackCardRect.right, 0.01),
      );
      expect(
        queueButtonRect.center.dy - queueCardRect.top,
        closeTo(trackButtonRect.center.dy - trackCardRect.top, 0.01),
      );

      final trackTitleX = tester.getTopLeft(trackTitle).dx;
      final queueTitleX = tester.getTopLeft(queueTitle).dx;
      const batchHeaderKey = ValueKey<String>(
        'playlist_batch_selection_header',
      );

      await tester.longPress(trackTitle);

      final batchHeader = find.byKey(batchHeaderKey);
      expect(batchHeader, findsOneWidget);
      expect(
        find.text(fixture.languageProvider.tr('multi_select')),
        findsOneWidget,
      );
      expect(
        find.text(
          fixture.languageProvider.tr('selected_count', {'count': '1'}),
        ),
        findsOneWidget,
      );
      final headerSwitcher = find.ancestor(
        of: batchHeader,
        matching: find.byType(AnimatedSwitcher),
      );
      expect(headerSwitcher, findsOneWidget);
      expect(
        tester.widget<AnimatedSwitcher>(headerSwitcher).duration,
        kAppMotionFast,
      );
      expect(find.byType(TopPageHeader), findsNWidgets(2));
      expect(
        find.descendant(
          of: batchHeader,
          matching: find.byType(TweenAnimationBuilder<double>),
        ),
        findsNothing,
      );

      await tester.pumpAndSettle();

      final batchActions = find.descendant(
        of: batchHeader,
        matching: find.byType(HeaderActionPill),
      );
      final exitSelectionButton = find.byKey(
        const ValueKey<String>('exit_selection_button'),
      );
      expect(batchActions, findsOneWidget);
      expect(exitSelectionButton, findsOneWidget);
      expect(
        tester.getTopLeft(batchActions).dy,
        greaterThan(
          tester
              .getTopLeft(
                find.text(fixture.languageProvider.tr('multi_select')),
              )
              .dy,
        ),
      );
      expect(
        tester.getTopLeft(exitSelectionButton).dx,
        greaterThan(tester.getTopLeft(batchActions).dx),
      );

      final trackIndicator = find.byKey(
        ValueKey<String>('playlist_selection_indicator_${trackSession.id}'),
      );
      final queueIndicator = find.byKey(
        ValueKey<String>('playlist_selection_indicator_${queueSession.id}'),
      );
      expect(trackIndicator, findsOneWidget);
      expect(queueIndicator, findsNothing);
      expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
      expect(tester.getTopLeft(trackTitle).dx, trackTitleX);
      expect(tester.getTopLeft(queueTitle).dx, queueTitleX);
      final trackContent = find.byKey(
        ValueKey<String>('playlist_card_content_${trackSession.id}'),
      );
      expect(
        tester.getTopLeft(trackIndicator).dx,
        tester.getTopLeft(trackContent).dx + 40,
      );
      expect(
        tester.getBottomLeft(trackIndicator).dy,
        tester.getBottomLeft(trackContent).dy - (playlistRowPadding.bottom - 2),
      );
      final indicatorContainer = tester.widget<Container>(trackIndicator);
      final indicatorDecoration =
          indicatorContainer.decoration as BoxDecoration;
      expect(indicatorDecoration.color, const Color(0xFF4CAF50));
      expect(indicatorDecoration.shape, BoxShape.circle);
      final colorScheme = Theme.of(
        tester.element(find.byType(PlaylistTab)),
      ).colorScheme;
      final trackCard = tester.widget<Card>(
        find.ancestor(of: trackContent, matching: find.byType(Card)).first,
      );
      expect(
        trackCard.color,
        colorScheme.primaryContainer.withValues(alpha: 0.15),
      );
      expect(trackCard.shape, same(playlistRowShape));
      final trackSemantics = tester
          .widgetList<Semantics>(
            find.ancestor(of: trackTitle, matching: find.byType(Semantics)),
          )
          .firstWhere((widget) => widget.properties.selected != null);
      expect(trackSemantics.properties.selected, isTrue);
      expect(trackSemantics.properties.onTap, isNotNull);

      await tester.tap(queueTitle);
      await tester.pumpAndSettle();

      expect(trackIndicator, findsOneWidget);
      expect(queueIndicator, findsOneWidget);
      expect(tester.getTopLeft(trackTitle).dx, trackTitleX);
      expect(tester.getTopLeft(queueTitle).dx, queueTitleX);
      final queueSurface = tester.widget<Material>(
        find.byKey(ValueKey('playback_queue_row_surface_${queueSession.id}')),
      );
      expect(
        queueSurface.color,
        colorScheme.primaryContainer.withValues(alpha: 0.15),
      );

      final pauseIconButton = find.byKey(
        const ValueKey<String>('batch_pause_button'),
      );
      final playIconButton = find.byKey(
        const ValueKey<String>('batch_play_button'),
      );
      final removeIconButton = find.byKey(
        const ValueKey<String>('batch_remove_button'),
      );
      final createQueueIconButton = find.byKey(
        const ValueKey<String>('batch_create_queue_button'),
      );
      final pinIconButton = find.byKey(
        const ValueKey<String>('batch_pin_button'),
      );
      expect(createQueueIconButton, findsOneWidget);
      expect(
        tester.widget<IconButton>(createQueueIconButton).tooltip,
        fixture.languageProvider.tr('add_playback_queue'),
      );
      expect(
        tester.widget<IconButton>(createQueueIconButton).onPressed,
        isNotNull,
      );
      expect(pinIconButton, findsOneWidget);
      expect(
        tester.widget<IconButton>(pinIconButton).tooltip,
        fixture.languageProvider.tr('pin_to_top'),
      );
      expect(tester.widget<IconButton>(pinIconButton).onPressed, isNotNull);
      expect(
        tester.widget<IconButton>(playIconButton).tooltip,
        fixture.languageProvider.tr('play'),
      );
      expect(
        find.descendant(
          of: playIconButton,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );
      for (final actionButton in [
        playIconButton,
        pauseIconButton,
        pinIconButton,
        removeIconButton,
      ]) {
        expect(tester.widget<IconButton>(actionButton).iconSize, 20);
        expect(
          tester.widget<IconButton>(actionButton).constraints,
          HeaderActionPill.buttonConstraints,
        );
      }
      expect(
        tester.widget<IconButton>(pauseIconButton).tooltip,
        fixture.languageProvider.tr('pause'),
      );
      expect(
        find.descendant(
          of: pauseIconButton,
          matching: find.byIcon(Icons.pause_rounded),
        ),
        findsOneWidget,
      );

      nativeCalls.clear();
      await tester.tap(playIconButton);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(kAppMotionFast);
      expect(
        nativeCalls.where(
          (call) =>
              call.method == NativePlaybackMethod.play &&
              (call.arguments as Map<Object?, Object?>)['sessionId'] ==
                  trackSession.id,
        ),
        hasLength(1),
      );
      expect(batchHeader, findsOneWidget);

      nativeCalls.clear();
      await tester.tap(pauseIconButton);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(kAppMotionFast);
      expect(
        nativeCalls.where(
          (call) =>
              call.method == NativePlaybackMethod.pause &&
              (call.arguments as Map<Object?, Object?>)['sessionId'] ==
                  queueSession.id,
        ),
        hasLength(1),
      );
      expect(batchHeader, findsOneWidget);

      await tester.tap(trackTitle);
      await tester.pumpAndSettle();
      expect(trackIndicator, findsNothing);
      expect(queueIndicator, findsOneWidget);
      await tester.tap(queueTitle);
      await tester.pump();
      expect(find.byType(TopPageHeader), findsNWidgets(2));
      await tester.pumpAndSettle();
      expect(batchHeader, findsNothing);
      expect(find.byType(TopPageHeader), findsOneWidget);

      await tester.longPress(queueTitle);
      await tester.pumpAndSettle();
      expect(queueIndicator, findsOneWidget);
      await tester.tap(trackTitle);
      await tester.pumpAndSettle();
      expect(trackIndicator, findsOneWidget);
      final sourceQueueIsFirst =
          tester.getTopLeft(queueTitle).dy < tester.getTopLeft(trackTitle).dy;
      await tester.tap(createQueueIconButton);
      await tester.pumpAndSettle();
      final createdQueue = fixture.runtimeGraph.playback.activeSessions
          .where(
            (session) =>
                session.isPlaybackQueue && session.id != queueSession.id,
          )
          .single;
      final createdEntries = createdQueue.playbackQueue!.entries;
      expect(
        createdEntries.map((entry) => entry.kind).toList(growable: false),
        sourceQueueIsFirst
            ? <PlaybackQueueEntryKind>[
                PlaybackQueueEntryKind.track,
                PlaybackQueueEntryKind.work,
                PlaybackQueueEntryKind.work,
              ]
            : <PlaybackQueueEntryKind>[
                PlaybackQueueEntryKind.work,
                PlaybackQueueEntryKind.track,
                PlaybackQueueEntryKind.work,
              ],
      );
      final copiedQueueTrack = createdEntries.firstWhere(
        (entry) => entry.kind == PlaybackQueueEntryKind.track,
      );
      expect(copiedQueueTrack.tracks, <MusicTrack>[queueTrack]);
      final copiedQueueWork = createdEntries.firstWhere(
        (entry) => entry.title == 'Queue source work',
      );
      expect(copiedQueueWork.kind, PlaybackQueueEntryKind.work);
      expect(
        copiedQueueWork.workRootPath,
        PathMatcher.normalize('/library/queue-work'),
      );
      expect(copiedQueueWork.tracks, <MusicTrack>[
        queueWorkTrack,
        secondQueueWorkTrack,
      ]);
      expect(batchHeader, findsNothing);
      fixture.playbackService.removeSessions(<String>[queueSession.id]);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[trackSession],
        playingSessionCount: trackSession.effectivePlaying ? 1 : 0,
        focusedSessionId: trackSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpAndSettle();
      expect(batchHeader, findsNothing);
      expect(find.byType(TopPageHeader), findsOneWidget);
    },
  );

  testWidgets(
    'temporary playback stays above saved items without a pin action',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
      );
      addTearDown(fixture.dispose);
      final tracks = [
        testMusicTrack(
          name: 'Saved audio',
          path: PathMatcher.normalize('/saved/01.mp3'),
          groupKey: PathMatcher.normalize('/saved'),
          groupTitle: 'Saved',
        ),
        testMusicTrack(
          name: 'Temporary audio',
          path: PathMatcher.normalize('/temporary/01.mp3'),
          groupKey: PathMatcher.normalize('/temporary'),
          groupTitle: 'Temporary',
        ),
      ];
      fixture.runtimeGraph.library.addTracks(
        tracks,
        notify: false,
        persist: false,
      );
      final saved = fixture.runtimeGraph.playback.createTrackSession(tracks[0]);
      final temporary = fixture.runtimeGraph.playback.createTrackSession(
        tracks[1],
      )..isTemporary = true;
      fixture.playbackService.syncSlice(
        activeSessions: [saved, temporary],
        playingSessionCount: 0,
        focusedSessionId: temporary.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pumpAndSettle();

      final temporaryCard = find.byKey(
        ValueKey<String>('playlist_card_content_${temporary.id}'),
      );
      final savedCard = find.byKey(
        ValueKey<String>('playlist_card_content_${saved.id}'),
      );
      expect(
        find.byKey(const ValueKey('playlist_temporary_session_divider')),
        findsNothing,
      );
      final temporaryHighlight = tester.widget<DecoratedBox>(
        find.byKey(ValueKey('playlist_card_highlight_${temporary.id}')),
      );
      final savedHighlight = tester.widget<DecoratedBox>(
        find.byKey(ValueKey('playlist_card_highlight_${saved.id}')),
      );
      expect(
        ((temporaryHighlight.decoration as ShapeDecoration).shape
                as RoundedRectangleBorder)
            .side,
        BorderSide.none,
      );
      expect(
        ((savedHighlight.decoration as ShapeDecoration).shape
                as RoundedRectangleBorder)
            .side,
        BorderSide.none,
      );
      expect(
        find.byKey(ValueKey<String>('playlist_card_raised_${temporary.id}')),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey<String>('playlist_card_raised_${saved.id}')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(savedCard).dy -
            tester.getBottomLeft(temporaryCard).dy,
        0.0,
      );
      final temporaryCardWidget = tester.widget<Card>(
        find.ancestor(of: temporaryCard, matching: find.byType(Card)),
      );
      final savedCardWidget = tester.widget<Card>(
        find.ancestor(of: savedCard, matching: find.byType(Card)),
      );
      final theme = Theme.of(tester.element(temporaryCard));
      final isDark = theme.brightness == Brightness.dark;
      final expectedBorderSide = BorderSide(
        color: theme.colorScheme.outlineVariant.withValues(
          alpha: isDark ? 0.24 : 0.42,
        ),
      );
      expect(
        (temporaryCardWidget.shape! as RoundedRectangleBorder).side,
        expectedBorderSide,
      );
      expect(
        (savedCardWidget.shape! as RoundedRectangleBorder).side,
        BorderSide.none,
      );
      final temporarySwipe = tester.widget<SwipeRevealCard>(
        find.ancestor(
          of: temporaryCard,
          matching: find.byType(SwipeRevealCard),
        ),
      );
      final savedSwipe = tester.widget<SwipeRevealCard>(
        find.ancestor(of: savedCard, matching: find.byType(SwipeRevealCard)),
      );
      final expectedTemporaryCardColor = isDark
          ? theme.colorScheme.surfaceBright
          : theme.colorScheme.surfaceContainerHigh;
      expect(temporarySwipe.closedColor, expectedTemporaryCardColor);
      expect(savedSwipe.closedColor, theme.colorScheme.surface);
      expect(temporaryCardWidget.color, Colors.transparent);
      expect(temporaryCardWidget.color, savedCardWidget.color);
      expect(temporarySwipe.onLeadingAction, isNull);
      await tester.longPress(find.text('Temporary audio'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('playlist_batch_selection_header')),
        findsNothing,
      );
    },
  );

  testWidgets('playlist multiselect batch pin pins and unpins selected sessions', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
    );
    addTearDown(fixture.dispose);

    final track1 = testMusicTrack(
      name: 'Track 1',
      path: PathMatcher.normalize('/library/work1/01.mp3'),
      groupKey: PathMatcher.normalize('/library/work1'),
      groupTitle: 'Work 1',
    );
    final track2 = testMusicTrack(
      name: 'Track 2',
      path: PathMatcher.normalize('/library/work2/02.mp3'),
      groupKey: PathMatcher.normalize('/library/work2'),
      groupTitle: 'Work 2',
    );
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[track1, track2],
      notify: false,
      persist: false,
    );
    final session1 = fixture.runtimeGraph.playback.createTrackSession(track1);
    final session2 = fixture.runtimeGraph.playback.createTrackSession(track2);
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session1, session2],
      playingSessionCount: 0,
      focusedSessionId: session1.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pumpAndSettle();

    final track1Title = find.text('Track 1');
    final track2Title = find.text('Track 2');

    // 1. Long press Track 1 to enter selection mode
    await tester.longPress(track1Title);
    await tester.pumpAndSettle();

    final batchHeader = find.byKey(
      const ValueKey<String>('playlist_batch_selection_header'),
    );
    expect(batchHeader, findsOneWidget);

    // Select Track 2 as well
    await tester.tap(track2Title);
    await tester.pumpAndSettle();

    final batchPinButton = find.byKey(
      const ValueKey<String>('batch_pin_button'),
    );
    expect(batchPinButton, findsOneWidget);
    expect(
      tester.widget<IconButton>(batchPinButton).tooltip,
      fixture.languageProvider.tr('pin_to_top'),
    );

    // Tap batch pin button -> both sessions should be pinned and selection mode exits
    await tester.tap(batchPinButton);
    await tester.pumpAndSettle();

    expect(batchHeader, findsNothing);
    expect(
      fixture.settingsRepository.pinnedPlaylistSessionIds,
      containsAll(<String>[session1.id, session2.id]),
    );

    // 2. Long press Track 1 again and select Track 2
    await tester.longPress(track1Title);
    await tester.pumpAndSettle();
    expect(batchHeader, findsOneWidget);

    await tester.tap(track2Title);
    await tester.pumpAndSettle();

    // Since both are pinned, tooltip should be 'unpin_from_top'
    final batchUnpinButton = find.byKey(
      const ValueKey<String>('batch_pin_button'),
    );
    expect(batchUnpinButton, findsOneWidget);
    expect(
      tester.widget<IconButton>(batchUnpinButton).tooltip,
      fixture.languageProvider.tr('unpin_from_top'),
    );

    // Tap batch unpin button -> both should be unpinned and selection mode exits
    await tester.tap(batchUnpinButton);
    await tester.pumpAndSettle();

    expect(batchHeader, findsNothing);
    expect(
      fixture.settingsRepository.pinnedPlaylistSessionIds,
      isNot(contains(session1.id)),
    );
    expect(
      fixture.settingsRepository.pinnedPlaylistSessionIds,
      isNot(contains(session2.id)),
    );
  });

  testWidgets(
    'adding playback queue enters immediately without entrance animation',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = MusicTrack(
        path: '/music/track1.mp3',
        displayName: 'Track 1',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: 'Folder',
        isSingle: false,
      );
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final trackSession = PlaybackSession(
        id: 'source-1',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(trackSession.shutdown);
      fixture.playbackService.registerSession(trackSession);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[trackSession],
        playingSessionCount: 0,
        focusedSessionId: trackSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: fixture.runtimeGraph,
          persistenceRepository: fixture.persistenceRepository,
          nativePlaybackRepository: fixture.nativePlaybackRepository,
          playbackCommandRunner:
              AppRuntimeWidgetTestFixture.playbackCommandRunner,
          libraryService: fixture.libraryService,
          playbackService: fixture.playbackService,
          timerService: fixture.timerService,
          notificationCoordinatorService:
              fixture.notificationCoordinatorService,
          settingsRepository: fixture.settings,
          languageProvider: fixture.languageProvider,
          child: const PlaylistTab(),
        ),
      );
      await tester.pumpAndSettle();

      final addQueueButton = find.byKey(
        const ValueKey<String>('playlist_add_queue_button'),
      );
      expect(addQueueButton, findsOneWidget);

      await tester.tap(addQueueButton);
      await tester.pump();

      final queueEntrance = find.byWidgetPredicate(
        (widget) =>
            widget.key != null &&
            widget.key.toString().contains('queue_entrance_'),
      );
      expect(queueEntrance, findsNothing);

      final queueSessions = fixture.runtimeGraph.playback.activeSessions
          .where((session) => session.isPlaybackQueue)
          .toList();
      expect(queueSessions, hasLength(1));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SwipeRevealCard &&
              widget.key == ValueKey(queueSessions.first.id),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets('playback queue defaults to cross-folder loop mode', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);

    final queueSession = fixture.runtimeGraph.playback.createPlaybackQueue(
      'Test Queue',
    );
    addTearDown(queueSession.shutdown);
    expect(queueSession.loopMode, SessionLoopMode.crossSequential);
    expect(queueSession.nonSingleLoopMode, SessionLoopMode.crossSequential);

    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[queueSession],
      playingSessionCount: 0,
      focusedSessionId: queueSession.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(
      fixture.build(
        const MobileOverlayInset(bottomInset: 132, child: PlaylistTab()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('顺序 - 跨文件夹'), findsNothing);

    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: queueSession.id)),
    );
    await tester.pumpAndSettle();

    final compositeKey = ValueKey<String>(
      'composite_${Icons.repeat_rounded.codePoint}_${Icons.folder_copy_rounded.codePoint}',
    );
    expect(find.byKey(compositeKey), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final (platform, screenSize, headerHeight) in [
    (TargetPlatform.android, const Size(2400, 1080), 40.0),
    (TargetPlatform.windows, const Size(2880, 1800), 48.0),
    (TargetPlatform.windows, const Size(3840, 2400), 48.0),
  ]) {
    testWidgets(
      'landscape session detail displays 4:3 cover in equal columns on ${platform.name} at ${screenSize.width / 3}',
      (tester) async {
        await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: Duration.zero,
          physicalSize: screenSize,
        );

        final aspectRatioFinder = find.descendant(
          of: find.byType(SessionDetailPage),
          matching: find.byType(AspectRatio),
        );
        expect(aspectRatioFinder, findsOneWidget);
        final aspectRatioWidget = tester.widget<AspectRatio>(aspectRatioFinder);
        expect(aspectRatioWidget.aspectRatio, 4 / 3);

        final titleFinder = find.byKey(
          const ValueKey('title_marquee_subtitle-session'),
        );
        expect(titleFinder, findsOneWidget);

        final titleInsideCover = find.descendant(
          of: aspectRatioFinder,
          matching: titleFinder,
        );
        expect(titleInsideCover, findsNothing);

        final coverRect = tester.getRect(aspectRatioFinder);
        final titleRect = tester.getRect(titleFinder);

        // Title is in the right section (to the right of the cover)
        expect(titleRect.left, greaterThan(coverRect.right));
        // Title is at the top of the right section
        expect(
          titleRect.top,
          closeTo(
            tester.getRect(find.byType(SessionDetailContent)).top + headerHeight,
            0.5,
          ),
        );
        expect(coverRect.width / coverRect.height, closeTo(4 / 3, 0.001));
        final progressRect = tester.getRect(find.byType(SessionProgressBar));
        expect(progressRect.top - coverRect.bottom, closeTo(5, 0.5));
        final leftRect = tester.getRect(
          find.byKey(const ValueKey('session_detail_left_column')),
        );
        final coverAreaBottom = leftRect.bottom - progressRect.height - 5;
        expect(
          coverRect.center.dy,
          closeTo((leftRect.top + headerHeight + coverAreaBottom) / 2, 0.5),
        );
        final rightRect = tester.getRect(
          find.byKey(const ValueKey('session_detail_right_column')),
        );
        expect(leftRect.width, closeTo(rightRect.width, 0.5));
        expect(rightRect.left - leftRect.right, closeTo(12, 0.5));
        expect(coverRect.width, lessThanOrEqualTo(leftRect.width));
        expect(titleRect.left, closeTo(rightRect.left + 4, 0.5));
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'landscape session detail keeps progress bar below cover in the left column',
    (tester) async {
      await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
        physicalSize: const Size(2400, 1080),
      );

      final coverFinder = find.descendant(
        of: find.byType(SessionDetailPage),
        matching: find.byType(AspectRatio),
      );
      final progressBarFinder = find.descendant(
        of: find.byType(SessionDetailPage),
        matching: find.byType(SessionProgressBar),
      );
      expect(coverFinder, findsOneWidget);
      expect(progressBarFinder, findsOneWidget);

      final coverRect = tester.getRect(coverFinder);
      final progressRect = tester.getRect(progressBarFinder);

      // Progress bar is below the cover image
      expect(progressRect.top - coverRect.bottom, closeTo(5, 0.5));
      final leftRect = tester.getRect(
        find.byKey(const ValueKey('session_detail_left_column')),
      );
      expect(progressRect.left, closeTo(leftRect.left, 0.5));
      expect(progressRect.width, closeTo(leftRect.width, 0.5));

      // Right side contains subtitle panel and transport controls, but not progress bar
      final rightSideFinder = find.byKey(
        const ValueKey('session_detail_right_column'),
      );
      expect(rightSideFinder, findsWidgets);

      final subtitleInRightSide = find.descendant(
        of: rightSideFinder,
        matching: find.byType(SessionSubtitlePanel),
      );
      expect(subtitleInRightSide, findsOneWidget);

      final controlsInRightSide = find.descendant(
        of: rightSideFinder,
        matching: find.byType(TransportPlaybackControlPanel),
      );
      expect(controlsInRightSide, findsOneWidget);

      final progressInRightSide = find.descendant(
        of: rightSideFinder,
        matching: find.byType(SessionProgressBar),
      );
      expect(progressInRightSide, findsNothing);
    },
  );

  for (final (platform, screenSize, contentTop) in [
    (TargetPlatform.android, const Size(1080, 2400), 40.0),
    (TargetPlatform.android, const Size(2400, 1080), 0.0),
    (TargetPlatform.windows, const Size(3840, 2400), 0.0),
  ]) {
    for (final topInset in [0.0, 24.0]) {
      testWidgets(
        'detail close button floats without moving content on ${platform.name} '
        '${screenSize.width} with top inset $topInset',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          try {
            tester.view.padding = FakeViewPadding(top: topInset * 3);
            tester.view.viewPadding = FakeViewPadding(top: topInset * 3);
            addTearDown(tester.view.resetPadding);
            addTearDown(tester.view.resetViewPadding);
            await _pumpSubtitleDetail(
              tester: tester,
              subtitleTrack: SubtitleTrack(
                sourcePath: 'empty.srt',
                cues: const [],
              ),
              initialPosition: Duration.zero,
              physicalSize: screenSize,
            );

            final button = find.byKey(
              const ValueKey('session_detail_close_button'),
            );
            expect(button, findsOneWidget);
            final floatingButton = find.ancestor(
              of: button,
              matching: find.byType(HeaderFloatingButton),
            );
            final buttonRect = tester.getRect(floatingButton);
            expect(buttonRect.left, 16);
            expect(buttonRect.top, topInset + 6);
            expect(buttonRect.size, const Size.square(38));
            expect(
              tester.getRect(find.byType(SessionDetailContent)).top,
              contentTop,
            );
            final decorations = tester.widgetList<DecoratedBox>(
              find.descendant(
                of: floatingButton,
                matching: find.byType(DecoratedBox),
              ),
            );
            final background = decorations
                .map((widget) => widget.decoration)
                .whereType<BoxDecoration>()
                .firstWhere((decoration) => decoration.color != null)
                .color!;
            expect(background.a, closeTo(0.5, 0.01));
            if (topInset > 0 && contentTop > 0) {
              final artwork = find.byKey(
                const ValueKey('artwork_subtitle-session'),
              );
              expect(buttonRect.overlaps(tester.getRect(artwork)), isTrue);
            }
            if (contentTop == 0) {
              await tester.tap(find.byIcon(Icons.tune_rounded));
              await tester.pumpAndSettle();
              final menuHeaderRect = tester.getRect(
                find.byType(SegmentPanelPageHeader),
              );
              expect(menuHeaderRect.top, closeTo(buttonRect.top, 0.5));
              expect(menuHeaderRect.center.dy, closeTo(buttonRect.center.dy, 0.5));
              await tester.tap(
                find.byKey(const ValueKey<String>('close_console_panel')),
              );
              await tester.pumpAndSettle();
            }
            await tester.tap(button);
            await tester.pumpAndSettle();
            expect(find.byType(SessionDetailPage), findsNothing);
            expect(find.byType(PlaylistTab), findsOneWidget);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );
    }
  }

  for (final extension in ['mp3', 'mp4']) {
    testWidgets(
      'single $extension playback disables the work detail button',
      (tester) async {
        await _pumpSubtitleDetail(
          tester: tester,
          physicalSize: defaultTargetPlatform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1080, 2400),
          initialTrack: MusicTrack(
            path: '/library/single.$extension',
            displayName: 'Single $extension',
            groupKey: '__single_files__',
            groupTitle: '',
            groupSubtitle: '',
            isSingle: true,
          ),
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: Duration.zero,
        );
        final control = find.byKey(
          const ValueKey('session_work_detail_button'),
        );
        final buttonFinder = find.descendant(
          of: control,
          matching: find.byType(IconButton),
        );
        final button = tester.widget<IconButton>(buttonFinder);
        expect(button.onPressed, isNull);
        final cs = Theme.of(tester.element(buttonFinder)).colorScheme;
        expect(
          button.style!.foregroundColor!.resolve({WidgetState.disabled}),
          cs.onSurface.withValues(alpha: 0.35),
        );
        await tester.tap(control);
        await tester.pumpAndSettle();
        expect(find.byType(WorkDetailPage), findsNothing);
        expect(find.byType(SessionDetailPage), findsOneWidget);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'secondary controls has 6 evenly spaced buttons and navigates to work detail',
    (tester) async {
      await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
      );

      final workDetailButton = find.byKey(
        const ValueKey('session_work_detail_button'),
      );
      expect(workDetailButton, findsOneWidget);

      final loopButton = find.byKey(
        const ValueKey('session_loop_button_anchor'),
      );
      expect(loopButton, findsOneWidget);

      final capsuleFinder = find.byKey(
        const ValueKey('playback_secondary_controls'),
      );
      final capsuleRect = tester.getRect(capsuleFinder);
      final loopRect = tester.getRect(loopButton);
      final detailRect = tester.getRect(workDetailButton);

      expect(loopRect.width, 44.0);
      expect(loopRect.height, 44.0);
      expect(detailRect.width, 44.0);
      expect(detailRect.height, 44.0);

      expect(loopRect.center.dx, closeTo(capsuleRect.left + 26, 0.5));
      expect(detailRect.center.dx, closeTo(capsuleRect.right - 26, 0.5));

      await tester.tap(workDetailButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(WorkDetailPage), findsOneWidget);
      await pumpUntilNotFound(
        tester,
        find.byType(SessionDetailPage, skipOffstage: false),
      );
      expect(find.byType(SessionDetailPage, skipOffstage: false), findsNothing);

      // The work detail returns directly to the main page.
      final backButton = find.byKey(const ValueKey('work_detail_back_button'));
      expect(backButton, findsOneWidget);
      await pumpUntilFound(
        tester,
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.key == const ValueKey('work_detail_back_button') &&
              widget.onPressed != null,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(backButton);
      await pumpUntilNotFound(tester, find.byType(WorkDetailPage));
      expect(find.byType(WorkDetailPage), findsNothing);
      expect(find.byType(SessionDetailPage, skipOffstage: false), findsNothing);
      expect(find.byType(PlaylistTab), findsOneWidget);
      expect(
        Navigator.of(tester.element(find.byType(PlaylistTab))).canPop(),
        false,
      );
    },
  );

  for (final remote in [false, true]) {
    testWidgets(
      'work detail opened from playback removes intermediate routes on exit (remote: $remote)',
      (tester) async {
        final pumped = await _pumpSubtitleDetail(
          tester: tester,
          physicalSize: defaultTargetPlatform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1080, 2400),
          initialTrack: remote
              ? MusicTrack(
                  path: 'https://example.com/track.mp3',
                  displayName: 'Remote track',
                  groupKey: 'asmr-work-123456',
                  groupTitle: 'Remote work',
                  groupSubtitle: 'RJ123456',
                  isSingle: false,
                  remoteMetadataKind: 'asmr.one',
                  remoteMetadata: const {'id': 123456, 'title': 'Remote work'},
                )
              : null,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: Duration.zero,
        );
        final navigator = Navigator.of(
          tester.element(find.byType(SessionDetailPage)),
        );
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Intermediate page')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        unawaited(
          navigator.push(
            buildSessionDetailRoute(sessionId: 'subtitle-session'),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('session_work_detail_button')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byType(WorkDetailPage), findsOneWidget);
        await pumpUntilNotFound(
          tester,
          find.byType(SessionDetailPage, skipOffstage: false),
        );
        expect(
          find.byType(SessionDetailPage, skipOffstage: false),
          findsNothing,
        );
        expect(
          find.text('Intermediate page', skipOffstage: false),
          findsNothing,
        );
        expect(
          pumped.fixture.playbackService.sessionById(pumped.session.id),
          same(pumped.session),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();

        await pumpUntilFound(
          tester,
          find.byWidgetPredicate(
            (widget) =>
                widget is IconButton &&
                widget.key == const ValueKey('work_detail_back_button') &&
                widget.onPressed != null,
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));
        await tester.tap(find.byKey(const ValueKey('work_detail_back_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byType(PlaylistTab), findsOneWidget);
        expect(navigator.canPop(), false);
        expect(
          find.byType(SessionDetailPage, skipOffstage: false),
          findsNothing,
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'landscape session detail keeps secondary controls visible when feature menu is open',
    (tester) async {
      final pumped = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
        physicalSize: const Size(2400, 1080),
      );

      final secondaryControlsFinder = find.byKey(
        const ValueKey('playback_secondary_controls'),
      );
      expect(secondaryControlsFinder, findsOneWidget);
      final closeButton = find.byKey(
        const ValueKey('session_detail_close_button'),
      );
      expect(closeButton, findsOneWidget);
      final progressRect = tester.getRect(find.byType(SessionProgressBar));
      final detailCloseRect = tester.getRect(
        find.ancestor(of: closeButton, matching: find.byType(HeaderFloatingButton)),
      );

      final tuneButtonFinder = find.byIcon(Icons.tune_rounded);
      expect(tuneButtonFinder, findsOneWidget);

      // Open audio features panel
      await tester.tap(tuneButtonFinder);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('segments_landscape')), findsOneWidget);
      expect(closeButton, findsNothing);
      final headerRect = tester.getRect(find.byType(SegmentPanelPageHeader));
      final surfaceRect = tester.getRect(
        find.byKey(
          const ValueKey<String>(
            'playback_expanded_control_panel_landscape_surface',
          ),
        ),
      );
      expect(headerRect.top, closeTo(surfaceRect.top, 1));
      expect(
        tester.getRect(find.byType(SessionProgressBar)),
        progressRect,
      );
      expect(
        surfaceRect.top,
        closeTo(detailCloseRect.top, 0.5),
      );
      expect(surfaceRect.contains(headerRect.center), isTrue);
      final menuClip = tester.widget<ClipRRect>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('segments_landscape')),
              matching: find.byType(ClipRRect),
            )
            .first,
      );
      expect(
        (menuClip.borderRadius as BorderRadius).topLeft,
        const Radius.circular(19),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentPanelPageHeader),
          matching: find.text(pumped.fixture.languageProvider.tr('equalizer')),
        ),
      );
      await tester.pumpAndSettle();
      final equalizerList = find.descendant(
        of: find.byType(EqualizerPage),
        matching: find.byType(ListView),
      );
      final equalizerScroll = find
          .descendant(of: equalizerList, matching: find.byType(Scrollable))
          .first;
      expect(tester.getRect(equalizerList).top, closeTo(surfaceRect.top, 1));
      final scrollExtent = tester
          .state<ScrollableState>(equalizerScroll)
          .position
          .maxScrollExtent;
      if (scrollExtent > 0) {
        final equalizerTile = find
            .descendant(
              of: find.byType(EqualizerPage),
              matching: find.byType(SwitchListTile),
            )
            .first;
        final tileTopBeforeScroll = tester.getRect(equalizerTile).top;
        await tester.drag(equalizerList, const Offset(0, -120));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(equalizerTile).top,
          lessThan(tileTopBeforeScroll),
        );
        expect(tester.getRect(find.byType(SegmentPanelPageHeader)), headerRect);
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('segments_landscape')),
          matching: find.byType(DragOnlyScrollbar),
        ),
        findsNothing,
      );
      final panelPage = find.descendant(
        of: find.byKey(const ValueKey('segments_landscape')),
        matching: find.byKey(const ValueKey('playback_console_page_stack')),
      );
      final contentPaddings = tester
          .widgetList<Padding>(
            find.ancestor(of: panelPage, matching: find.byType(Padding)),
          )
          .map((padding) => padding.padding);
      expect(
        contentPaddings,
        contains(const EdgeInsets.fromLTRB(16, 0, 16, 16)),
      );
      // Secondary controls capsule remains visible in landscape
      expect(secondaryControlsFinder, findsOneWidget);

      final menuCloseButton = find.byKey(
        const ValueKey<String>('close_console_panel'),
      );
      expect(
        tester.getCenter(menuCloseButton).dx,
        greaterThan(headerRect.center.dx),
      );
      await tester.tap(menuCloseButton);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('segments_landscape')), findsNothing);
      expect(secondaryControlsFinder, findsOneWidget);
      expect(closeButton, findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'portrait session detail hides secondary controls when feature menu is open',
    (tester) async {
      await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
      );

      final secondaryControlsFinder = find.byKey(
        const ValueKey('playback_secondary_controls'),
      );
      expect(secondaryControlsFinder, findsOneWidget);
      final closeButton = find.byKey(
        const ValueKey('session_detail_close_button'),
      );
      expect(closeButton, findsOneWidget);

      final tuneButtonFinder = find.byIcon(Icons.tune_rounded);
      expect(tuneButtonFinder, findsOneWidget);

      // Open audio features panel
      await tester.tap(tuneButtonFinder);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('segments')), findsOneWidget);
      expect(find.byType(SessionSubtitlePanel), findsOneWidget);
      expect(
        tester
            .getSize(
              find.byKey(
                const ValueKey<String>('playback_expanded_control_panel'),
              ),
            )
            .height,
        closeTo(432, 1),
      );
      // Secondary controls capsule is hidden in portrait
      expect(secondaryControlsFinder, findsNothing);
      expect(closeButton, findsNothing);

      await tester.tap(find.byKey(const ValueKey('close_console_panel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('segments')), findsNothing);
      expect(secondaryControlsFinder, findsOneWidget);
      expect(closeButton, findsOneWidget);

      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(find.byType(SessionDetailPage), findsNothing);
      expect(find.byType(PlaylistTab), findsOneWidget);
    },
  );

  testWidgets(
    'playlist item row height is compact with semicircular ends and swipe-right underlayer is semicircular',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = MusicTrack(
        path: '/library/Work/01.mp3',
        displayName: 'Track Title Line 1\nTrack Title Line 2',
        groupKey: '/library/Work',
        groupTitle: 'Work Folder Line',
        groupSubtitle: '/library/Work',
        isSingle: false,
      );
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final session = fixture.runtimeGraph.playback.createTrackSession(
        track,
        customQueueTracks: <MusicTrack>[track],
      );
      addTearDown(session.shutdown);

      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        fixture.build(
          const MobileOverlayInset(bottomInset: 132, child: PlaylistTab()),
        ),
      );
      await tester.pumpAndSettle();

      final swipeCardFinder = find.byType(SwipeRevealCard);
      expect(swipeCardFinder, findsOneWidget);
      final swipeCard = tester.widget<SwipeRevealCard>(swipeCardFinder);

      // Verify row height is compact (64)
      final cardSize = tester.getSize(swipeCardFinder);
      expect(cardSize.height, 64.0);

      expect(swipeCard.shape, same(playlistRowShape));
      expect(
        tester
            .widgetList<ClipPath>(
              find.descendant(
                of: swipeCardFinder,
                matching: find.byType(ClipPath),
              ),
            )
            .any(
              (clip) =>
                  clip.clipper is ShapeBorderClipper &&
                  (clip.clipper! as ShapeBorderClipper).shape ==
                      playlistRowShape,
            ),
        isTrue,
      );

      // Swipe right to reveal leading action (pin)
      await tester.drag(swipeCardFinder, const Offset(180, 0));
      await tester.pump();

      // Find the revealed underlayer DecoratedBox
      final underlayerBoxes = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: swipeCardFinder,
          matching: find.byType(DecoratedBox),
        ),
      );
      final revealedUnderlayer = underlayerBoxes.firstWhere(
        (box) => box.decoration is ShapeDecoration,
      );
      final shapeDeco = revealedUnderlayer.decoration as ShapeDecoration;
      expect(shapeDeco.shape, same(playlistRowShape));
    },
  );

  test('playlist row ends stay semicircular at larger heights', () {
    for (final height in <double>[64, 96]) {
      final path = playlistRowShape.getOuterPath(
        Rect.fromLTWH(0, 0, 300, height),
      );
      expect(path.contains(Offset(0.5, height / 2)), isTrue);
      expect(path.contains(Offset(0.5, height / 2 - 15)), isFalse);
      expect(path.contains(Offset(299.5, height / 2)), isTrue);
      expect(path.contains(Offset(299.5, height / 2 - 15)), isFalse);
    }
  });

  test('formatSpeedValue formats 1, 2, and 3 to two decimal places', () {
    expect(formatSpeedValue(1.0), '1.00x');
    expect(formatSpeedValue(2.0), '2.00x');
    expect(formatSpeedValue(3.0), '3.00x');
    expect(formatSpeedValue(1.25), '1.25x');
    expect(formatSpeedValue(0.75), '0.75x');
  });
}
