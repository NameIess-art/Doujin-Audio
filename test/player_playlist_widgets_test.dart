import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/widgets/app_edit_panel.dart';
import 'package:doujin_audio/core/widgets/app_entry_ink_well.dart';
import 'package:doujin_audio/core/widgets/app_dialog.dart';
import 'package:doujin_audio/core/widgets/app_glass_surface.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/playlist_icon.dart';
import 'package:doujin_audio/core/widgets/unified_dropdown.dart';
import 'package:doujin_audio/features/player/presentation/playback_providers.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show Consumer, ProviderContainer, ProviderScope;
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
import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/application/playback_queue_resolver.dart';
import 'package:doujin_audio/features/player/application/session_switcher_tree.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_layout.dart';
import 'package:doujin_audio/features/player/presentation/bedtime_canvas_page.dart';
import 'package:doujin_audio/features/player/presentation/timer_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_theme.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_track_switcher_sheet.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_subtitle_panel.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playback_queue_cover.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_cover_transition.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/session_video_viewport.dart';
import 'package:doujin_audio/features/player/presentation/session_video_surface.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/app_brand_icon.dart';
import 'package:doujin_audio/core/widgets/duration_overlay.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:doujin_audio/core/widgets/file_tree_row.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/widgets/horizontal_edge_fade_scroll.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/app/presentation/windows_window_title_bar.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';
import 'support/test_persistence_repository.dart';
import 'support/test_playback_commands.dart';

class _QueueEditorAsmrController extends LoadedEmptyAsmrLibraryController {
  _QueueEditorAsmrController(this.tracks) : super(createTestAsmrServices());

  final List<MusicTrack> tracks;
  AsmrWork? requestedWork;
  bool isOffline = false;

  @override
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async {
    if (isOffline) throw StateError('Catalog is offline');
    requestedWork = work;
    return tracks;
  }
}

class _PagedQueueRepository extends TestPersistenceRepository
    implements PlaybackQueueStorage {
  _PagedQueueRepository({this.firstPageFails = true, this.allWorks = false});

  final bool firstPageFails;
  final bool allWorks;
  final List<(int, int)> requests = [];
  final List<String> entryLoads = [];
  int queueLoads = 0;
  Future<void>? queueLoadGate;
  Future<void>? nextPageGate;
  final workTrack = testMusicTrack(
    name: 'Saved work audio',
    path: '/library/saved-work/audio.mp3',
    groupKey: '/library/saved-work',
    groupTitle: 'Saved work',
  );

  @override
  Future<List<PlaybackQueueEntryPreview>> loadQueueEntryPage(
    String sessionId, {
    required int start,
    required int limit,
  }) async {
    requests.add((start, limit));
    if (firstPageFails && requests.length == 1) {
      throw StateError('Failed to read queue');
    }
    if (start > 0) await nextPageGate;
    return [
      for (var index = start; index < start + limit && index < 260; index++)
        (
          id: 'saved-entry-$index',
          kind: index == 0 || allWorks
              ? PlaybackQueueEntryKind.work
              : PlaybackQueueEntryKind.track,
          title: index == 0 ? 'Saved work' : 'Saved track $index',
          trackCount: 1,
          firstTrack: index == 0 ? workTrack : null,
        ),
    ];
  }

  @override
  Future<PlaybackQueueEntry?> loadQueueEntry(
    String sessionId,
    String entryId,
  ) async {
    entryLoads.add(entryId);
    return entryId == 'saved-entry-0'
        ? PlaybackQueueEntry(
            id: entryId,
            kind: PlaybackQueueEntryKind.work,
            title: 'Saved work',
            workRootPath: '/library/saved-work',
            tracks: [workTrack],
          )
        : null;
  }

  @override
  Future<PersistedPlaybackSession?> loadSessionQueue(String sessionId) async {
    queueLoads++;
    await queueLoadGate;
    return PersistedPlaybackSession(
      id: sessionId,
      trackPath: workTrack.path,
      loopModeIndex: SessionLoopMode.single.index,
      volume: 1,
      positionMs: 0,
      durationMs: 0,
      customQueueTracks: null,
      channelSwapEnabled: false,
      sortOrder: 0,
      playbackQueue: PlaybackQueueDefinition(
        name: 'Paged queue',
        entries: [
          PlaybackQueueEntry(
            id: 'saved-entry-0',
            kind: PlaybackQueueEntryKind.work,
            title: 'Saved work',
            tracks: [workTrack],
          ),
          for (var index = 1; index < 260; index++)
            PlaybackQueueEntry(
              id: 'saved-entry-$index',
              kind: PlaybackQueueEntryKind.track,
              title: 'Saved track $index',
              tracks: [workTrack],
            ),
        ],
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingPlaybackCoverCacheService extends CoverArtworkCacheService {
  _RecordingPlaybackCoverCacheService({
    this.fixedCoverPath,
    this.playbackCoverPaths = const {},
  }) : super(libraryService: LibraryService());

  final String? fixedCoverPath;
  final Map<String, String> playbackCoverPaths;
  final List<String> requestedPaths = <String>[];
  final List<String> resolvedPlaybackPaths = <String>[];

  @override
  String? resolvedForPlaybackTrack(MusicTrack? track, {String? trackPath}) {
    final resolvedPath = track?.path ?? trackPath;
    if (resolvedPath != null) resolvedPlaybackPaths.add(resolvedPath);
    return playbackCoverPaths[resolvedPath] ?? fixedCoverPath;
  }

  @override
  Future<String?>? cachedFutureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final coverPath =
        playbackCoverPaths[track?.path ?? trackPath] ?? fixedCoverPath;
    return coverPath == null
        ? super.cachedFutureForPlaybackTrack(track, trackPath: trackPath)
        : SynchronousFuture<String?>(coverPath);
  }

  @override
  Future<String?> futureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final path = track?.path ?? trackPath;
    if (path != null) {
      requestedPaths.add(path);
    }
    return SynchronousFuture<String?>(
      playbackCoverPaths[path] ?? fixedCoverPath,
    );
  }

  @override
  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) {
    return SynchronousFuture<String?>(fixedCoverPath);
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
  expect(style.shape!.resolve(enabled), const StadiumBorder());
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
  int? queueColorValue,
  bool preloadSubtitle = false,
  bool openDetail = true,
  VoidCallback? onSubtitleLoad,
  List<NavigatorObserver> navigatorObservers = const [],
  FutureOr<void> Function(AppRuntimeWidgetTestFixture)? configureFixture,
  NativePlaybackRepository? nativePlaybackRepository,
  ThemeProvider? themeProvider,
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
    providedNativePlaybackRepository: nativePlaybackRepository,
  );
  addTearDown(fixture.dispose);
  if (configureFixture != null) {
    await tester.runAsync(() async => await configureFixture(fixture));
  }
  fixture.runtimeGraph.library.addTracks(
    queueTracks ?? <MusicTrack>[track],
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
            colorValue: queueColorValue,
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
      themeProvider: themeProvider,
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
  final content = find.byType(SessionDetailContent);
  // Credits are only watched after the cover overlays become active.
  if (content.evaluate().singleOrNull?.widget
      case final SessionDetailContent detail
      when !track.isRemoteAsmr &&
          detail.showCoverOverlays &&
          detail.transitionActive?.value != true) {
    final target = fixture.runtimeGraph.library.audioDetailTargetForTrack(
      track,
    );
    final container = ProviderScope.containerOf(tester.element(content));
    await tester.runAsync(
      () => container.read(libraryDetailForTargetProvider(target).future),
    );
    await tester.pumpAndSettle();
  }

  return (fixture: fixture, session: session, coverCache: coverCache);
}

Future<List<int>> _subtitleEdgeAlpha(WidgetTester tester) async {
  final mask = tester.widget<ShaderMask>(
    find.byKey(const ValueKey('subtitle_timeline_edge_fade')),
  );
  return (await tester.runAsync(() async {
    const bounds = Rect.fromLTWH(0, 0, 4, 200);
    final recorder = ui.PictureRecorder();
    ui.Canvas(
      recorder,
    ).drawRect(bounds, ui.Paint()..shader = mask.shaderCallback(bounds));
    final picture = recorder.endRecording();
    final image = await picture.toImage(4, 200);
    final pixels = (await image.toByteData())!;
    final alpha = [
      for (final y in [0, 16, 100, 183, 199])
        pixels.getUint8((y * 4 + 2) * 4 + 3),
    ];
    image.dispose();
    picture.dispose();
    return alpha;
  }))!;
}

void main() {
  AppRuntimeTestFixture.initialize();
  late Database testDatabase;

  // Playing waveforms keep ticking while finite UI transitions finish.
  Future<void> pumpFiniteTransitions(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

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

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'speed wheel releases same-position adjustments (reduced: $reducedMotion)',
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
        tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reducedMotion);
        addTearDown(
          tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final result = await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: Duration.zero,
          physicalSize: defaultTargetPlatform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1080, 2400),
        );
        await tester.tap(find.byIcon(Icons.tune_rounded));
        await tester.pumpAndSettle();
        final wheel = find.byKey(const ValueKey('playback_speed_wheel'));
        await tester.tap(
          find.descendant(
            of: wheel,
            matching: find.text(formatSpeedValue(1.0)),
          ),
        );
        await tester.pumpAndSettle();
        final playback = result.fixture.runtimeGraph.playback;
        await playback.setSessionSpeed(result.session.id, 1.5, persist: false);
        await tester.pumpAndSettle();
        expect(result.session.speed, 1.5);
        expect(find.byKey(const ValueKey<double>(1.5)), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('restore_playback_speed')));
        await tester.pumpAndSettle();
        expect(result.session.speed, 1.0);
        await playback.setSessionSpeed(result.session.id, 1.25, persist: false);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey<double>(1.25)), findsOneWidget);

        if (defaultTargetPlatform == TargetPlatform.windows) {
          await playback.setSessionSpeed(
            result.session.id,
            0.25,
            persist: false,
          );
          await tester.pumpAndSettle();
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: tester.getCenter(wheel),
              scrollDelta: const Offset(0, -120),
            ),
          );
          await tester.pumpAndSettle();
          await playback.setSessionSpeed(
            result.session.id,
            1.5,
            persist: false,
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey<double>(1.5)), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'reduced motion speed selection and reset jump to their final item',
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
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final result = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
        physicalSize: defaultTargetPlatform == TargetPlatform.windows
            ? const Size(3840, 2400)
            : const Size(1080, 2400),
      );
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      final wheel = find.byKey(const ValueKey('playback_speed_wheel'));
      final controller = tester.widget<ListWheelScrollView>(wheel).controller!;
      await tester.tap(
        find.descendant(of: wheel, matching: find.text(formatSpeedValue(1.25))),
      );
      await tester.pump();
      expect(controller.position.pixels, 4 * 52);
      await tester.pumpAndSettle();
      expect(result.session.speed, 1.25);
      await tester.tap(find.byKey(const ValueKey('restore_playback_speed')));
      await tester.pump();
      expect(controller.position.pixels, 3 * 52);
      await tester.pumpAndSettle();
      expect(result.session.speed, 1.0);
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue();
      await tester.pump();
      await tester.pump();
      await tester.tap(
        find.descendant(of: wheel, matching: find.text(formatSpeedValue(1.5))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(controller.position.isScrollingNotifier.value, isTrue);
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();
      await tester.pump();
      expect(controller.position.pixels, 5 * 52);
      expect(controller.position.isScrollingNotifier.value, isFalse);
      await tester.pumpAndSettle();
      expect(result.session.speed, 1.5);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final isVideo in [false, true]) {
    testWidgets(
      'portrait detail cover spacing preserves aspect ratio and collapsed width, video=$isVideo',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 820);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        Widget page(bool expanded) => MaterialApp(
          home: Scaffold(
            body: SessionDetailLayout(
              isLandscape: false,
              padding: EdgeInsets.zero,
              segmentPanelExpanded: expanded,
              artwork: const SizedBox(key: ValueKey('portrait_artwork')),
              isVideo: isVideo,
              title: 'Test',
              circleName: 'Circle',
              voiceActors: const ['Voice'],
              sessionId: 'Test',
              progress: const SizedBox(height: 44),
              transport: const SizedBox(height: 50),
              subtitle: const SizedBox(),
              segmentPanelBuilder: (_) => const SizedBox(height: 220),
            ),
          ),
        );
        await tester.pumpWidget(page(false));
        final artwork = tester.getRect(
          find.byKey(const ValueKey('portrait_artwork')),
        );
        expect(artwork.left, isVideo ? 0 : 8);
        expect(390 - artwork.right, isVideo ? 0 : 8);
        expect(artwork.width / artwork.height, closeTo(4 / 3, 0.001));
        final filename = find.byKey(const ValueKey('title_marquee_Test'));
        final credits = find.byKey(
          const ValueKey('session_detail_credits_Test'),
        );
        if (isVideo) {
          expect(
            tester.getRect(filename).top,
            greaterThanOrEqualTo(artwork.bottom),
          );
        } else {
          expect(artwork.contains(tester.getRect(filename).topLeft), isTrue);
          expect(artwork.contains(tester.getRect(credits).bottomRight), isTrue);
        }
        expect(
          tester.getRect(credits).top,
          greaterThan(tester.getRect(filename).bottom),
        );
        expect(find.text('Circle'), findsOneWidget);
        expect(find.text('Voice'), findsOneWidget);

        await tester.pumpWidget(page(true));
        await tester.pumpAndSettle();
        final frame = tester.getRect(find.byType(CoverArtworkFrame));
        expect(frame.left, 0);
        expect(frame.width, 390);
        expect(frame.height, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (platform, screenSize) in [
    (TargetPlatform.android, const Size(1080, 2400)),
    (TargetPlatform.android, const Size(2400, 1080)),
    (TargetPlatform.windows, const Size(2880, 1800)),
  ]) {
    for (final remote in [false, true]) {
      testWidgets(
        'detail credits load and update on $platform at $screenSize, remote=$remote',
        (tester) async {
          final track =
              testMusicTrack(
                name: 'Filename',
                path: remote
                    ? 'https://audio.test/track.mp3'
                    : '/credits/track.mp3',
                groupKey: '/credits',
                groupTitle: 'Work',
              ).copyWith(
                remoteMetadataKind: remote
                    ? MusicTrack.remoteMetadataKindAsmrOne
                    : null,
                remoteMetadata: remote
                    ? {
                        'id': 7,
                        'circle': {'name': 'Circle'},
                        'vas': [
                          {'name': 'Voice A'},
                          {'name': 'Voice B'},
                        ],
                      }
                    : null,
              );
          final target = AudioDetailTarget.libraryRootFolder('/credits');
          final harness = await _pumpSubtitleDetail(
            tester: tester,
            initialTrack: track,
            subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: []),
            initialPosition: Duration.zero,
            physicalSize: screenSize,
            configureFixture: remote
                ? null
                : (fixture) => fixture.persistenceRepository.upsert(
                    AudioDetail.empty(target).copyWith(
                      circleName: 'Circle',
                      voiceActors: ['Voice A', 'Voice B'],
                    ),
                  ),
          );
          final title = find.byKey(
            const ValueKey('title_marquee_subtitle-session'),
          );
          final credits = find.byKey(
            const ValueKey('session_detail_credits_subtitle-session'),
          );
          final mouse = platform == TargetPlatform.windows
              ? await tester.createGesture(
                  kind: PointerDeviceKind.mouse,
                  buttons: kSecondaryMouseButton,
                )
              : null;
          await mouse?.addPointer(location: Offset.zero);
          for (final value in ['Circle', 'Voice A', 'Voice B']) {
            expect(
              find.descendant(of: credits, matching: find.text(value)),
              findsOneWidget,
            );
          }
          expect(
            tester.getRect(credits).top,
            greaterThan(tester.getRect(title).bottom),
          );
          final copied = <String>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied.add((call.arguments as Map)['text'] as String);
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          for (final value in ['Circle', 'Voice A', 'Voice B']) {
            final label = find.descendant(
              of: credits,
              matching: find.text(value),
            );
            await tester.tap(label);
            await tester.pumpAndSettle();
            expect(copied.last, value);
            await tester.pump(const Duration(seconds: 3));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<AnimatedOpacity>(
                    find.byKey(const ValueKey('session_detail_title_fade')),
                  )
                  .opacity,
              1,
            );
            if (mouse != null) {
              await mouse.moveTo(tester.getCenter(label));
              await tester.pumpAndSettle();
              final ink = tester.widget<InkWell>(
                find.ancestor(of: label, matching: find.byType(InkWell)).first,
              );
              expect(ink.hoverColor, Colors.transparent);
              final scale = tester
                  .widgetList<Transform>(
                    find.ancestor(of: label, matching: find.byType(Transform)),
                  )
                  .where((widget) => !widget.transformHitTests)
                  .fold<double>(1.0, (scale, t) => scale * t.transform.entry(0, 0));
              expect(scale, 1.0);
              await mouse.down(tester.getCenter(label));
              await mouse.up();
            } else {
              await tester.longPress(label);
            }
            await tester.pumpAndSettle();
            expect(find.text('Search online'), findsOneWidget);
            expect(find.text('Search locally'), findsOneWidget);
            await tester.tap(find.text('Copy'));
            await tester.pumpAndSettle();
            expect(copied.last, value);
            await tester.pump(const Duration(seconds: 3));
            await tester.pumpAndSettle();
          }
          await mouse?.removePointer();
          expect(copied, [
            'Circle',
            'Circle',
            'Voice A',
            'Voice A',
            'Voice B',
            'Voice B',
          ]);
          if (!remote) {
            await tester.runAsync(
              () => harness.fixture.runtimeGraph.library.saveAudioDetail(
                AudioDetail.empty(target).copyWith(circleName: 'Edited circle'),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              find.descendant(
                of: credits,
                matching: find.text('Edited circle'),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(of: credits, matching: find.text('--')),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }

  testWidgets(
    'reduced motion portrait panel opens without an intermediate size',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      Widget page(bool expanded) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: SessionDetailLayout(
              isLandscape: false,
              padding: EdgeInsets.zero,
              segmentPanelExpanded: expanded,
              artwork: const SizedBox(),
              isVideo: false,
              title: 'Test',
              sessionId: 'Test',
              progress: const SizedBox(height: 44),
              transport: const SizedBox(height: 50),
              subtitle: const SizedBox(),
              segmentPanelBuilder: (_) => const SizedBox(height: 220),
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(false));
      await tester.pumpWidget(page(true));
      await tester.pump();
      expect(tester.getSize(find.byType(AnimatedContainer)).height, 0);
      final panelTransition = find.descendant(
        of: find.byType(SessionDetailLayout),
        matching: find.byType(SizeTransition),
      );
      expect(
        tester.widget<SizeTransition>(panelTransition).sizeFactor.value,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

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
        final entryContentState = tester.state<SessionDetailContentState>(
          content,
        );
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isFalse);
        await tester.pump(const Duration(milliseconds: 60));
        final firstTop = tester.getTopLeft(content).dy;
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.getTopLeft(content).dy, firstTop);
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isFalse);
        await tester.pumpAndSettle();
        expect(
          tester.state<SessionDetailContentState>(content),
          same(entryContentState),
        );
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isTrue);

        final beforeDrag = tester.getTopLeft(content);
        await tester.dragFrom(
          beforeDrag + const Offset(100, 150),
          const Offset(320, 0),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SessionDetailPage), findsOneWidget);
        expect(tester.getTopLeft(content), beforeDrag);
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isTrue);

        await tester.tap(
          find.byKey(const ValueKey('session_detail_close_button')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(TickerMode.valuesOf(tester.element(content)).enabled, isFalse);
        await tester.pumpAndSettle();
        expect(find.byType(SessionDetailPage), findsNothing);
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
          // Isolate detail discovery from playlist artwork resumed after pop.
          detailBuilder: (_) =>
              const SizedBox.shrink(key: ValueKey('detail_discovery_host')),
        );
        expect(subtitleLoads, cachedSubtitle ? 1 : 0);
        // Notification artwork is independent of detail discovery. Finish its
        // first presentation before counting the detail route's requests.
        fixture.fixture.notifications.syncPlaybackState(
          immediateUnifiedSync: true,
        );
        await tester.pump();
        fixture.coverCache.requestedPaths.clear();
        final navigator = Navigator.of(
          tester.element(find.byKey(const ValueKey('detail_discovery_host'))),
        );
        final route = buildSessionDetailRoute(sessionId: fixture.session.id);
        unawaited(navigator.push(route));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(fixture.coverCache.requestedPaths, isEmpty);
        expect(subtitleLoads, cachedSubtitle ? 1 : 0);
        expect(find.byType(SessionDetailContent), findsOneWidget);
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
        expect(
          find.text('Cached or deferred subtitle'),
          closeDuringEntrance ? findsNothing : findsOneWidget,
        );
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
    fixture.library.addTracks(tracks, persist: false);
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
    fixture.library.addTracks([singleTrack], persist: false);
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
    await tester.runAsync(
      fixture.library.detailCacheService.waitForPendingOperations,
    );
    await tester.pump();
  });

  for (final (platform, replaceQueue) in [
    for (final platform in [TargetPlatform.android, TargetPlatform.windows])
      for (final replaceQueue in [false, true]) (platform, replaceQueue),
  ]) {
    testWidgets(
      'switcher starts during exit and validates queue on $platform, replaced=$replaceQueue',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
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
          physicalSize: platform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1080, 2400),
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
        final switchButton = find.byTooltip(
          harness.fixture.languageProvider.tr('switch_audio'),
        );
        final switchPress = await tester.startGesture(
          tester.getCenter(switchButton),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await switchPress.up();
        final row = find.byKey(
          ValueKey('queue_switcher_track_${tracks[1].path}'),
        );
        await tester.pump();
        expect(row, findsOneWidget);
        await tester.pumpAndSettle();
        final sheet = tester.widget<SessionTrackSwitcherSheet>(
          find.byType(SessionTrackSwitcherSheet),
        );
        final route = ModalRoute.of(tester.element(row))!;
        var exited = false;
        unawaited(route.completed.then((_) => exited = true));
        if (replaceQueue) {
          harness.session.playbackQueue = harness.session.playbackQueue!
              .copyWith(entries: []);
        }
        await tester.tap(row);
        // A stale second tap must neither pop the detail page nor prepare twice.
        sheet.onSelected(
          SessionTrackSelection(track: tracks[1], queueIndex: 1),
        );
        await tester.pump();
        expect(exited, isFalse);
        expect(
          commands,
          replaceQueue ? isEmpty : [(harness.session.id, tracks[1].path, 1)],
        );
        await tester.pump(const Duration(milliseconds: 140));
        expect(exited, isFalse);
        expect(harness.session.currentTrackPath, tracks.first.path);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(exited, isTrue);
        expect(find.byType(SessionDetailPage), findsOneWidget);
        if (replaceQueue) {
          expect(harness.session.currentTrackPath, tracks.first.path);
          expect(commands, isEmpty);
        } else {
          expect(commands, [(harness.session.id, tracks[1].path, 1)]);
        }
        await tester.pump(PlaybackSession.loadingIndicatorThreshold);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
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

        final seekButton = find.byIcon(
          forward ? Icons.forward_5_rounded : Icons.replay_5_rounded,
        );
        final initialColor = IconTheme.of(tester.element(seekButton)).color;
        final initialPosition = tester.getCenter(seekButton);
        final seekPress = await tester.startGesture(initialPosition);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 110));
        final glyphScale = tester
            .widgetList<Transform>(
              find.ancestor(of: seekButton, matching: find.byType(Transform)),
            )
            .where((widget) => !widget.transformHitTests)
            .fold<double>(1.0, (scale, t) => scale * t.transform.entry(0, 0));
        expect(
          glyphScale,
          defaultTargetPlatform == TargetPlatform.windows ? 1.0 : 0.92,
        );
        expect(IconTheme.of(tester.element(seekButton)).color, initialColor);
        await seekPress.up();
        await tester.pump();
        expect(session.position, Duration(seconds: forward ? 25 : 15));
        session.setOptimisticState(processingState: ProcessingState.buffering);
        await tester.pump();
        final spinner = find.descendant(
          of: find.byType(PrimaryPlaybackControls),
          matching: find.byType(CircularProgressIndicator),
        );
        expect(spinner, findsNothing);
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          tester.getCenter(seekButton).dx - initialPosition.dx,
          forward ? greaterThan(0) : lessThan(0),
        );
        await tester.pump(const Duration(milliseconds: 319));
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

  for (final forward in [false, true]) {
    testWidgets(
      'holding five-second ${forward ? 'forward' : 'rewind'} repeats until release or cancellation',
      (tester) async {
        final harness = await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: const Duration(seconds: 20),
          physicalSize: defaultTargetPlatform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1080, 2400),
        );
        final session = harness.session
          ..setOptimisticDuration(const Duration(seconds: 40));
        final button = find.byIcon(
          forward ? Icons.forward_5_rounded : Icons.replay_5_rounded,
        );
        final kind = defaultTargetPlatform == TargetPlatform.windows
            ? PointerDeviceKind.mouse
            : PointerDeviceKind.touch;
        final delta = forward ? 5 : -5;

        await tester.tap(button, kind: kind);
        await tester.pump(const Duration(milliseconds: 600));
        expect(session.position, Duration(seconds: 20 + delta));

        final hold = await tester.startGesture(
          tester.getCenter(button),
          kind: kind,
        );
        await tester.pump(kLongPressTimeout);
        expect(session.position, Duration(seconds: 20 + 2 * delta));
        await tester.pump(const Duration(milliseconds: 300));
        expect(session.position, Duration(seconds: 20 + 3 * delta));
        await hold.up();
        await tester.pump(const Duration(milliseconds: 600));
        expect(session.position, Duration(seconds: 20 + 3 * delta));

        final cancelledHold = await tester.startGesture(
          tester.getCenter(button),
          kind: kind,
        );
        await tester.pump(kLongPressTimeout);
        final boundary = Duration(seconds: forward ? 40 : 0);
        expect(session.position, boundary);
        await tester.pump(const Duration(milliseconds: 300));
        session.setOptimisticPosition(const Duration(seconds: 20));
        await tester.pump(const Duration(milliseconds: 600));
        expect(session.position, const Duration(seconds: 20));
        await cancelledHold.cancel();

        final activeHold = await tester.startGesture(
          tester.getCenter(button),
          kind: kind,
        );
        await tester.pump(kLongPressTimeout);
        await activeHold.cancel();
        await tester.pump(const Duration(milliseconds: 600));
        expect(session.position, Duration(seconds: 20 + delta));
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('held seek skips busy ticks and stops after switching tracks', (
    tester,
  ) async {
    final harness = await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
      initialPosition: const Duration(seconds: 20),
      nativePlaybackRepository: NativePlaybackRepository(
        bridge: NativePlaybackBridge.instance,
      ),
    );
    final session = harness.session
      ..loadedPath = harness.session.currentTrackPath
      ..setOptimisticDuration(const Duration(minutes: 1));
    final positions = <int>[];
    final firstSeek = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
          if (call.method != NativePlaybackMethod.seek) {
            return <String, Object?>{'ok': true, 'value': null};
          }
          final position = (call.arguments as Map)['positionMs'] as int;
          final path = session.currentTrackPath;
          positions.add(position);
          if (positions.length == 1) await firstSeek.future;
          return <String, Object?>{
            'ok': true,
            'value': {
              'sessionId': session.id,
              'path': path,
              'positionMs': position,
              'queueIndex': 0,
            },
          };
        });
    final button = find.byIcon(Icons.forward_5_rounded);
    final hold = await tester.startGesture(tester.getCenter(button));
    await tester.pump(kLongPressTimeout);
    expect(positions, [25000]);
    await tester.pump(const Duration(milliseconds: 600));
    expect(session.position, const Duration(seconds: 25));
    expect(positions, [25000]);
    firstSeek.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(positions, [25000, 30000]);

    session
      ..currentTrackPath = '/library/subtitles/another.mp3'
      ..setOptimisticPosition(Duration.zero);
    harness.fixture.runtimeGraph.playback.publishSessionState(session.id);
    await tester.pump(const Duration(milliseconds: 600));
    expect(session.position, Duration.zero);
    expect(positions, [25000, 30000]);
    await hold.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('held seek stops when the app loses focus', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    final harness = await _pumpSubtitleDetail(
      tester: tester,
      subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
      initialPosition: const Duration(seconds: 20),
    );
    final button = find.byIcon(Icons.forward_5_rounded);
    final hold = await tester.startGesture(tester.getCenter(button));
    await tester.pump(kLongPressTimeout);
    expect(harness.session.position, const Duration(seconds: 25));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 600));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 600));
    await hold.up();
    await tester.pump();
    expect(harness.session.position, const Duration(seconds: 25));
  });

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

  testWidgets(
    'Windows subtitle wheel animates to the selected cue',
    (tester) async {
      final subtitleTrack = SubtitleTrack(
        sourcePath: 'wheel.srt',
        cues: List.generate(
          10,
          (index) => SubtitleCue(
            start: Duration(seconds: index * 2),
            end: Duration(seconds: index * 2 + 2),
            text: 'Cue $index',
          ),
        ),
      );
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(
          Center(
            child: SizedBox(
              width: 400,
              height: 160,
              child: TimelineSubtitleView(
                cues: subtitleTrack.cues,
                playbackSubtitleIndex: 2,
                onSeek: (_) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('subtitle_timeline_list'));
      final controller = tester.widget<ListView>(list).controller!;
      final start = controller.offset;
      Future<void> wheel() => tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(list),
          scrollDelta: const Offset(0, 80),
        ),
      );
      await wheel();
      await wheel();
      expect(controller.offset, start);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      expect(controller.offset, greaterThan(start));
      final partial = controller.offset;
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(partial));
      final cue = find.byKey(const ValueKey('subtitle_timeline_cue_4'));
      expect(tester.getCenter(cue).dy, closeTo(tester.getCenter(list).dy, 0.1));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(start, 0.1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

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
        final pending = Completer<List<TimeSegmentLabel>>();
        var reads = 0;
        await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: Duration.zero,
          configureFixture: (fixture) {
            fixture.persistenceRepository.timeSegmentLabelLoader = (_) async {
              reads++;
              return reads == 1 ? await pending.future : [];
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
          final labels = {
            for (final track in tracks)
              TimeSegmentLabel.trackKeyFor(track): TimeSegmentLabel(
                id: 'deferred-${track.displayName}',
                trackKey: TimeSegmentLabel.trackKeyFor(track),
                name: '${track.displayName} deferred label',
                start: Duration.zero,
                end: const Duration(seconds: 5),
                colorValue: kTimeSegmentLabelPalette.first,
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
              ),
          };
          final harness = await _pumpSubtitleDetail(
            tester: tester,
            subtitleTrack: SubtitleTrack(
              sourcePath: 'empty.srt',
              cues: const [],
            ),
            initialPosition: Duration.zero,
            queueTracks: tracks,
            configureFixture: (fixture) {
              fixture.persistenceRepository.timeSegmentLabelLoader =
                  (key) async {
                    reads++;
                    return [labels[key]!];
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
    'SessionProgressBar retains the seek target while progress updates are deferred',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final session = PlaybackSession(
        id: 'seek-progress-session',
        currentTrackPath: '/library/track.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      )
        ..setOptimisticDuration(const Duration(minutes: 2))
        ..setOptimisticPosition(const Duration(seconds: 10));
      fixture.playbackService.registerSession(session);
      final interaction = UiInteractionCoordinator.instance;
      final interactionSource = Object();
      addTearDown(() => interaction.cancelInteraction(interactionSource));

      await tester.pumpWidget(
        fixture.build(
          Center(
            child: SizedBox(
              width: 400,
              child: SessionProgressBar(
                session: PlaybackSessionSnapshot.fromRuntime(session),
                playback: fixture.playback,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final slider = find.byType(Slider);
      final rect = tester.getRect(slider);
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * 0.25, rect.center.dy),
      );
      interaction.beginInteraction(interactionSource);
      await gesture.moveBy(Offset(rect.width * 0.4, 0));
      await tester.pump();
      final target = tester.widget<Slider>(slider).value.round();
      expect(target, greaterThan(30000));
      await gesture.up();
      await tester.pump();
      expect(session.position.inMilliseconds, target);
      expect(tester.widget<Slider>(slider).value, target.toDouble());

      interaction.cancelInteraction(interactionSource);
      await tester.pump();
      session.setOptimisticPosition(const Duration(seconds: 90));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 90000);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'SessionProgressBar updates both timecode labels when hovering over progress track and restores on exit',
    (tester) async {
      await tester.runAsync(() async {
        final timecodeFont = FontLoader('Outfit')
          ..addFont(rootBundle.load('assets/fonts/Outfit-Variable.ttf'));
        await timecodeFont.load();
      });
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final theme = ThemeProvider(loadPersistedState: false);
      addTearDown(theme.dispose);
      final session = PlaybackSession(
        id: 'hover-progress-session',
        currentTrackPath: '/library/track.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      )..setOptimisticDuration(const Duration(hours: 1));
      addTearDown(session.shutdown);
      fixture.playbackService.registerSession(session);

      await tester.pumpWidget(
        fixture.build(
          Theme(
            data: theme.lightTheme,
            child: SizedBox(
              width: 400,
              child: SessionProgressBar(
                session: PlaybackSessionSnapshot.fromRuntime(session),
                playback: fixture.runtimeGraph.playback,
                inlineTimecodes: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final labels = find.byType(TimecodeLabel);
      expect(labels, findsNWidgets(2));
      expect(tester.widget<TimecodeLabel>(labels.first).text, '00:00');
      expect(tester.widget<TimecodeLabel>(labels.last).text, '-01:00:00');

      final sliderFinder = find.byType(Slider);
      final sliderRect = tester.getRect(sliderFinder);

      final gesture = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);

      final trackLeft = sliderRect.left + 12.0;
      final trackRight = sliderRect.right - 12.0;
      final midPoint = Offset(
        (trackLeft + trackRight) / 2.0,
        sliderRect.center.dy,
      );

      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(midPoint);
      await tester.pump();

      // The remaining time loses its hour field without expanding the track.
      expect(tester.widget<TimecodeLabel>(labels.first).text, '30:00');
      expect(tester.widget<TimecodeLabel>(labels.last).text, '-30:00');
      expect(tester.getRect(sliderFinder), sliderRect);
      // Actual slider thumb value is still at 0
      expect(tester.widget<Slider>(sliderFinder).value, 0.0);

      // Move to 75% point
      final threeQuarterPoint = Offset(
        trackLeft + (trackRight - trackLeft) * 0.75,
        sliderRect.center.dy,
      );
      await gesture.moveTo(threeQuarterPoint);
      await tester.pump();
      expect(tester.widget<TimecodeLabel>(labels.first).text, '45:00');
      expect(tester.widget<TimecodeLabel>(labels.last).text, '-15:00');
      expect(tester.getRect(sliderFinder), sliderRect);

      session.setOptimisticPosition(const Duration(minutes: 1));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<TimecodeLabel>(labels.first).text, '45:00');
      expect(tester.getRect(sliderFinder), sliderRect);

      await gesture.moveTo(Offset(trackRight, sliderRect.center.dy));
      await tester.pump();
      expect(tester.widget<TimecodeLabel>(labels.first).text, '01:00:00');
      expect(tester.widget<TimecodeLabel>(labels.last).text, '-00:00');
      expect(tester.getRect(sliderFinder), sliderRect);

      // Exit progress bar area
      await gesture.moveTo(
        Offset(sliderRect.center.dx, sliderRect.bottom + 50.0),
      );
      await tester.pump();

      // Restores to actual playback progress
      expect(tester.widget<TimecodeLabel>(labels.first).text, '01:00');
      expect(tester.widget<TimecodeLabel>(labels.last).text, '-59:00');
      expect(tester.getRect(sliderFinder), sliderRect);

      session
        ..setOptimisticDuration(const Duration(minutes: 2, seconds: 11))
        ..setOptimisticPosition(Duration.zero);
      await tester.pump(const Duration(milliseconds: 100));
      final minuteRect = tester.getRect(sliderFinder);
      final minuteLeft = minuteRect.left + 12;
      final minuteWidth = minuteRect.width - 24;
      final clippedLabels = <String>[];
      for (final seconds in [1, 11, 22, 44, 59, 61, 88, 111]) {
        await gesture.moveTo(
          Offset(
            minuteLeft + minuteWidth * ((seconds + 0.1) / 131),
            minuteRect.center.dy,
          ),
        );
        await tester.pump();
        final minutes = seconds ~/ 60;
        final secondsText = (seconds % 60).toString().padLeft(2, '0');
        expect(
          tester.widget<TimecodeLabel>(labels.first).text,
          '${minutes.toString().padLeft(2, '0')}:$secondsText',
        );
        expect(tester.getRect(sliderFinder), minuteRect);
        for (final label in tester.widgetList<TimecodeLabel>(labels)) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(label.text),
          );
          if (paragraph.getMaxIntrinsicWidth(double.infinity) >
              paragraph.size.width) {
            clippedLabels.add(label.text);
          }
        }
      }
      expect(clippedLabels, isEmpty);
      await gesture.down(
        Offset(minuteLeft + minuteWidth * (111.1 / 131), minuteRect.center.dy),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(session.position, const Duration(seconds: 111, milliseconds: 100));
      expect(tester.widget<TimecodeLabel>(labels.first).text, '01:51');
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
      painter.paint(Canvas(recorder), Size(width + 24, 40));
      recorder.endRecording().dispose();
      final expected = <({double x, double top})>[];
      for (final label in labels) {
        for (final position in [label.start, label.end]) {
          final x =
              12 + width * (position.inMilliseconds / 1000).clamp(0.0, 1.0);
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
                inlineTimecodes: screenSize.width > screenSize.height,
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
        final fadeFinder = find
            .ancestor(
              of: find.text('Middle section'),
              matching: find.byType(FadeTransition),
            )
            .first;
        final tooltipOpacity = tester
            .widget<FadeTransition>(fadeFinder)
            .opacity;
        expect(tooltipOpacity.value, 0);
        await tester.pump(kAppFadeDuration ~/ 2);
        expect(tooltipOpacity.value, inExclusiveRange(0, 1));
        final capsule = find
            .ancestor(
              of: find.text('Middle section'),
              matching: find.byType(DecoratedBox),
            )
            .first;
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
        expect(
          identical(
            tester.widget<FadeTransition>(fadeFinder).opacity,
            tooltipOpacity,
          ),
          isTrue,
        );
        expect(tooltipOpacity.value, inExclusiveRange(0, 1));
        await tester.pump(kAppFadeDuration - (kAppFadeDuration ~/ 2));
        expect(tooltipOpacity.value, 1);
        tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(35000);
        await tester.pump();
        expect(find.text('Middle section'), findsOneWidget);
        await tester.pump(kAppFadeDuration ~/ 2);
        expect(tooltipOpacity.value, inExclusiveRange(0, 1));
        await tester.pump(kAppFadeDuration - (kAppFadeDuration ~/ 2));
        expect(tooltipOpacity.value, closeTo(0, 0.001));
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(find.text('Middle section'), findsNothing);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'mounted playback card refreshes only for its cover scopes or a full reset',
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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
      ], persist: false);
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
            onOpenSession: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(coverCache.requestedPaths, contains(track.path));
      coverCache.requestedPaths.clear();

      coverCache.invalidateFolder('/unrelated-work');
      await tester.pumpAndSettle();
      expect(coverCache.requestedPaths, isEmpty);

      coverCache.invalidateTrack(track);
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
    final indicator = find.byKey(const ValueKey('active_session_indicator'));
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
          onOpenSession: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(indicator, findsNothing);

    await tester.pumpWidget(
      fixture.build(
        ActiveSessionCarousel(sessions: sessions, onOpenSession: (_, _) {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(indicator, findsOneWidget);
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
          onOpenSession: (_, _) {},
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
          onOpenSession: (_, _) {},
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
        onOpenSession: (_, _) {},
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
          onOpenSession: (_, _) {},
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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
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
      ], persist: false);
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
              onOpenSession: (_, _) {},
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
            .widget<CoverArtworkFrame>(
              find.descendant(
                of: find.byKey(
                  const ValueKey<String>('active_session_cover_circular_1'),
                ),
                matching: find.byType(CoverArtworkFrame),
              ),
            )
            .borderRadius,
        BorderRadius.circular(
          coverProgressInnerDimension(kActiveSessionCarouselDockHeight) / 2,
        ),
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
              find.descendant(
                of: embeddedCard,
                matching: find.byWidgetPredicate((widget) => widget is InkWell),
              ),
            )
            .any((inkWell) => inkWell.customBorder is StadiumBorder),
        isTrue,
      );
      expect(
        tester
            .widget<CoverArtworkFrame>(
              find.descendant(
                of: find.byKey(
                  const ValueKey<String>('active_session_cover_circular_2'),
                ),
                matching: find.byType(CoverArtworkFrame),
              ),
            )
            .borderRadius,
        BorderRadius.circular(coverProgressInnerDimension(48) / 2),
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
        fixture.runtimeGraph.library.addTracks([track], persist: false);
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
                onOpenSession: (_, _) {},
              ),
            ),
            subtitleService: subtitleService,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

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

    expect(disabledIcons, isNot(contains(Icons.equalizer_rounded)));
    expect(enabledIcons, contains(Icons.equalizer_rounded));
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

  testWidgets('audio switcher shrinks folder children to zero in 220 ms', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final session = fixture.playback.createPlaybackQueue('Switch audio');
    final disc = SessionSwitcherNode.folder('Disc', key: 'disc');
    final track = MusicTrack(
      path: '/library/disc/audio.mp3',
      displayName: 'Audio',
      groupKey: '/library/disc',
      groupTitle: 'Disc',
      groupSubtitle: '',
      isSingle: false,
    );
    final leaf = SessionSwitcherNode.track(
      track,
      selected: false,
      queueIndex: 1,
      sourceIndex: 0,
    );
    disc.children.add(leaf);
    await tester.pumpWidget(
      fixture.build(
        SessionTrackSwitcherSheet(
          session: PlaybackSessionSnapshot.fromRuntime(session),
          trackCount: 1,
          tree: (
            roots: [disc],
            rows: [
              (node: disc, depth: 0, key: disc.key),
              (node: leaf, depth: 1, key: leaf.key),
            ],
            indices: {disc.key: 0, leaf.key: 1},
            expanded: {disc.key},
          ),
          onSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final audioRow = find.byKey(ValueKey<String>(leaf.key));
    await tester.tap(find.text('Disc', findRichText: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 215));
    expect(tester.getSize(audioRow).height, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 16));
    expect(audioRow, findsNothing);
  }, variant: const TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  }));

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
    fixture.runtimeGraph.library.addTracks(tracks, persist: false);
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
    'session detail buttons accept repeated presses after first opening',
    (WidgetTester tester) async {
      final windows = defaultTargetPlatform == TargetPlatform.windows;
      final pumped = await _pumpSubtitleDetail(
        tester: tester,
        openDetail: false,
        physicalSize: windows ? const Size(3840, 2400) : const Size(1080, 2400),
        initialPosition: const Duration(seconds: 30),
        subtitleTrack: SubtitleTrack(
          sourcePath: '/library/subtitles/track.vtt',
          cues: const <SubtitleCue>[],
        ),
      );

      final commands = <String>[];
      final facade = pumped.fixture.runtimeGraph.playback;
      facade.detachCommandPort();
      facade.attachPlaybackCommands(
        prepareSession:
            (
              _, {
              required nextPath,
              autoPlay = true,
              forceStartAtZero = false,
              showLoading = true,
              targetQueueIndex,
            }) async {
              commands.add(nextPath);
              return true;
            },
        pauseSession: (session) async {
          commands.add('pause');
          session.state = const PlayerState(false, ProcessingState.ready);
        },
        startSession: (session, {required shouldStartTriggerCountdown}) async {
          commands.add('play');
          session.state = const PlayerState(true, ProcessingState.ready);
          return true;
        },
        resolveAdvance: (_, {required forward}) => PlaybackAdvanceResult(
          path: forward ? '/queue/next.mp3' : '/queue/prev.mp3',
        ),
        hasAdjacent: (_, {required forward}) => true,
      );
      final navigator = Navigator.of(tester.element(find.byType(PlaylistTab)));
      final route = buildSessionDetailRoute(sessionId: pumped.session.id);
      unawaited(navigator.push(route));
      await tester.pump();
      await tester.pump(route.transitionDuration);
      await tester.pump();
      await tester.pump(route.transitionDuration);
      expect(route.animation!.status, AnimationStatus.completed);

      final device = windows
          ? PointerDeviceKind.mouse
          : PointerDeviceKind.touch;
      Future<void> press(Finder button) async {
        final bounds = tester.getRect(button);
        final gesture = await tester.startGesture(
          bounds.centerLeft + const Offset(6, 0),
          kind: device,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getRect(button), bounds);
        await gesture.up();
        await tester.pump();
      }

      Finder iconButton(IconData glyph) => find.ancestor(
        of: find.byIcon(glyph),
        matching: find.byType(IconButton),
      );

      await press(iconButton(Icons.forward_5_rounded));
      expect(pumped.session.position, const Duration(seconds: 35));

      await press(iconButton(Icons.replay_5_rounded));
      expect(pumped.session.position, const Duration(seconds: 30));

      await press(iconButton(Icons.skip_next_rounded));
      expect(commands, ['/queue/next.mp3']);
      // Non-queue sessions restart the track when more than three seconds in.
      await press(iconButton(Icons.skip_previous_rounded));
      expect(pumped.session.position, Duration.zero);
      await press(iconButton(Icons.skip_previous_rounded));
      expect(commands, ['/queue/next.mp3', '/queue/prev.mp3']);
      final toggle = find.byKey(
        const ValueKey('session_detail_play_pause_button'),
      );
      await press(toggle);
      expect(commands, ['/queue/next.mp3', '/queue/prev.mp3', 'play']);
      await press(toggle);
      expect(commands, ['/queue/next.mp3', '/queue/prev.mp3', 'play', 'pause']);
      await press(iconButton(Icons.tune_rounded));
      expect(
        find.byKey(ValueKey(windows ? 'segments_landscape' : 'segments')),
        findsOneWidget,
      );

      navigator.pop();
      await tester.pumpAndSettle();
      UiInteractionCoordinator.instance.resetForTest();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'playlist keeps its skeleton until session restoration confirms an empty list',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      var sorts = 0;
      await tester.pumpWidget(
        fixture.build(
          const PlaylistTab(),
          overrides: [
            playlistSortedEntriesUiProvider.overrideWithBuild((ref, notifier) {
              sorts++;
              return [];
            }),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey('playlist_initial_placeholder')),
        findsOneWidget,
      );
      expect(find.byType(SessionsEmptyState), findsNothing);
      expect(sorts, 0);

      fixture.playbackService.syncSlice(
        activeSessions: const <PlaybackSession>[],
        playingSessionCount: 0,
        focusedSessionId: null,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SessionsEmptyState), findsOneWidget);
      expect(find.byType(PlaylistLoadingSkeleton), findsNothing);
      expect(sorts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('playlist first open crossfades its card skeleton over 300ms', (
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
      tester.widget<TopPageHeader>(find.byType(TopPageHeader)).iconWidget,
      isA<PlaylistIcon>().having((w) => w.filled, 'filled', isTrue),
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
      initialSkeletonCardTop -
          tester.getBottomLeft(find.byType(TopPageHeader)).dy,
      closeTo(8, 0.001),
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

    // Start the fade clock after the loaded list's first layout frame.
    await tester.pump();
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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
      ], persist: false);
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

  testWidgets('downward drag leaves the expanded console and detail open', (
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
        final pageRect = tester.getRect(stack);
        final dragStart = Offset(pageRect.center.dx, pageRect.bottom - 8);
        for (final dx in [-120.0, 120.0]) {
          await tester.dragFrom(dragStart, Offset(dx, 0));
          await tester.pumpAndSettle();
          expect(tester.widget<SegmentPanelPageHeader>(header).pageIndex, 2);
        }
        final speed = find.byType(SpeedWheelPage, skipOffstage: false);
        final speedState = tester.state(speed);
        final speedWidget = tester.widget(speed);
        expect(
          tester.widget<AppFadeThroughIndexedStack>(stack).duration,
          kAppFadeDuration,
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
        await tester.pump(kAppFadeDuration ~/ 2);
        expect(translation(0).dx, allOf(greaterThan(-1), lessThan(0)));
        expect(tester.widget(equalizer), same(equalizerWidget));
        expect(tester.widget(speed), same(speedWidget));
        await tester.pump(kAppFadeDuration ~/ 2 - const Duration(milliseconds: 1));
        expect(excludesSemantics(equalizer), isTrue);
        await tester.pump(const Duration(milliseconds: 2));
        expect(translation(0), Offset.zero);
        expect(excludesSemantics(equalizer), isFalse);
        expect(TickerMode.valuesOf(tester.element(speed)).enabled, isFalse);

        tester.widget<SegmentPanelPageHeader>(header).onSelected(2);
        await tester.pump();
        await tester.pump();
        await tester.pump(kAppFadeDuration ~/ 2);
        expect(excludesSemantics(speed), isTrue);
        await tester.pump(kAppFadeDuration ~/ 2 + const Duration(milliseconds: 1));
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
        expect(tester.widget<SegmentPanelPageHeader>(header).pageIndex, 4);
        expect(find.byTooltip(i18n.tr('segment_add')), findsNothing);
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
                loopSegmentId: null,
                onSelect: (_) {},
                onAdd: () {},
                onSetStart: () {},
                onSetEnd: () {},
                onEditStart: () {},
                onEditEnd: () {},
                onDelete: (_) {},
                onToggleLoop: (_) {},
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

  testWidgets(
    'equalizer displays and saves bands before playback and while paused',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(
        defaultTargetPlatform == TargetPlatform.windows ? 1280 : 430,
        900,
      );
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const channel = MethodChannel(NativePlaybackChannel.name);
      final nativeCalls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call);
        return <String, Object?>{'ok': true, 'value': null};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final session = PlaybackSession(
        id: 'idle-equalizer',
        currentTrackPath: '/library/eq/track.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.idle),
      );
      addTearDown(session.shutdown);
      fixture.playbackService.registerSession(session);
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(
        fixture.build(
          EqualizerPage(
            session: PlaybackSessionSnapshot.fromRuntime(session),
            playback: fixture.playback,
            topInset: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final equalizer = find.byType(EqualizerPage);
      final toggle = find.descendant(
        of: equalizer,
        matching: find.byType(SwitchListTile),
      );
      final preset = find.descendant(
        of: equalizer,
        matching: find.byType(DropdownButtonFormField<String>),
      );
      expect(tester.widget<SwitchListTile>(toggle).subtitle, isNull);
      expect(tester.getSize(preset).width, tester.getSize(toggle).width);
      await tester.tap(preset);
      await tester.pumpAndSettle();
      expect(find.byType(AppModalBackground), findsOneWidget);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(find.byType(AppModalBackground), findsNothing);
      expect(find.byType(EqBandSlider), findsNWidgets(8));
      expect(
        tester.widgetList<Slider>(find.byType(Slider)).map((s) => s.onChanged),
        everyElement(isNull),
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      final band = find.byType(EqBandSlider).first;
      expect(tester.widget<EqBandSlider>(band).onChanged, isNotNull);
      tester.widget<EqBandSlider>(band).onChangeEnd!(3);
      await tester.pumpAndSettle();
      expect(session.audioEffects.eqEnabled, isTrue);
      expect(session.audioEffects.eqBandLevels[60], 3);
      expect(tester.widget<EqBandSlider>(band).value, 3);
      expect(nativeCalls, isEmpty);
      expect(session.loadedPath, isNull);
      expect(session.effectivePlaying, isFalse);

      session.applyNativeSnapshot(
        NativePlaybackSnapshot(
          sessionId: session.id,
          path: session.currentTrackPath,
          playing: false,
          playWhenReady: false,
          processingState: 'ready',
          position: Duration.zero,
          bufferedPosition: Duration.zero,
          volume: 1,
          boostGain: 1,
          channelSwapEnabled: false,
          audioEffects: session.audioEffects.copyWith(
            eqBandLevels: {60: 3, 400: -2},
          ),
          eqCapabilities: EqCapabilities(
            supported: true,
            minGainDb: -6,
            maxGainDb: 6,
            bands: const [EqBandInfo(frequencyHz: 100)],
          ),
        ),
      );
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).subtitle, isNull);
      expect(find.byType(EqBandSlider), findsNWidgets(9));
      expect(tester.widget<EqBandSlider>(band).value, 3);
      expect(tester.widget<EqBandSlider>(band).min, -6);
      expect(tester.widget<EqBandSlider>(band).max, 6);
      expect(
        tester
            .widgetList<EqBandSlider>(find.byType(EqBandSlider))
            .singleWhere((slider) => slider.label == '400Hz')
            .value,
        -2,
      );
      expect(session.effectivePlaying, isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('playback tabs slide one selection capsule between labels', (
    tester,
  ) async {
    var selected = 0;
    const accent = Colors.deepPurple;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: const ColorScheme.light(primary: accent)),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SegmentPanelPageHeader(
              pageIndex: selected,
              onSelected: (index) => setState(() => selected = index),
              onClose: () {},
              closeTooltip: 'Close',
              labels: const ['EQ', 'Sound settings', 'Speed'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final indicator = find.byKey(const ValueKey('console_tab_indicator'));
    RRect capsule() {
      final canvas = TestRecordingCanvas();
      tester
          .widget<CustomPaint>(indicator)
          .painter!
          .paint(canvas, tester.getSize(indicator));
      final draw = canvas.invocations
          .singleWhere((call) => call.invocation.memberName == #drawRRect)
          .invocation;
      final fillColor = (draw.positionalArguments.last as Paint).color;
      expect(fillColor.withValues(alpha: 1), isSameColorAs(accent));
      expect(fillColor.a, inExclusiveRange(0, 1));
      return draw.positionalArguments.first as RRect;
    }

    final origin = tester.getTopLeft(indicator).dx;
    final start = capsule();
    final destination =
        tester.getCenter(find.text('Sound settings')).dx - origin;
    await tester.tap(find.text('Sound settings'));
    await tester.pump();
    expect(capsule(), start);
    await tester.pump(const Duration(milliseconds: 60));
    final intermediate = capsule();
    expect(
      intermediate.center.dx,
      inExclusiveRange(start.center.dx, destination),
    );
    await tester.pump(const Duration(milliseconds: 160));
    final end = capsule();
    expect(end.center.dx, closeTo(destination, 0.01));
    expect(end.width, greaterThan(intermediate.width));
    expect(end.tlRadiusX, end.height / 2);
  });

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
    runtimeGraph.library.addTracks(<MusicTrack>[track], persist: false);
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
    expect(panelDecoration.color, isNull);
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
    expect(
      find.descendant(of: header, matching: find.byType(HeaderFloatingSurface)),
      findsNothing,
    );
    final headerMaterial = tester.widget<Material>(
      find.descendant(of: header, matching: find.byType(Material)).first,
    );
    expect(headerMaterial.type, MaterialType.transparency);
    final panelRect = tester.getRect(panelSurface);
    final headerRect = tester.getRect(header);
    expect(panelRect.contains(tester.getCenter(closeButtonFinder)), isTrue);
    expect(headerRect.height, 38);
    expect(headerRect.top, closeTo(panelRect.top, 1));
    expect(headerRect.left, closeTo(panelRect.left, 1));
    expect(headerRect.right, closeTo(panelRect.right, 1));
    final tabScrollView = tester.widget<SingleChildScrollView>(
      find.descendant(of: header, matching: find.byType(SingleChildScrollView)),
    );
    expect(tabScrollView.physics, isA<ClampingScrollPhysics>());
    final tabTaps = find.descendant(of: header, matching: find.byType(InkWell));
    expect(tabTaps, findsNWidgets(6));
    expect(
      tester.widget<InkWell>(tabTaps.at(0)).borderRadius,
      BorderRadius.circular(15),
    );
    final firstTabRect = tester.getRect(tabTaps.at(0));
    final secondTabRect = tester.getRect(tabTaps.at(1));
    await tester.tapAt(headerRect.topLeft + const Offset(1, 1));
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
    final speedRestoreRect = tester.getRect(speedRestoreButton);
    expect(tester.widget<FilledButton>(speedRestoreButton).onPressed, isNull);

    await tester.tap(find.text(languageProvider.tr('equalizer')));
    await tester.pumpAndSettle();
    final equalizerList = find.descendant(
      of: find.byType(EqualizerPage),
      matching: find.byType(ListView),
    );
    expect(
      tester.getRect(equalizerList).top,
      closeTo(tester.getRect(header).bottom, 1),
    );
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
    await tester.scrollUntilVisible(
      equalizerResetButton,
      150,
      scrollable: find.descendant(
        of: equalizerList,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
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

    await tester.tap(saveEqualizerPresetButton);
    await tester.pumpAndSettle();
    final presetForm = find.byType(AppEditPanelForm);
    expect(tester.getSize(presetForm).height, 192);
    await tester.enterText(
      find.descendant(of: presetForm, matching: find.byType(TextField)),
      '  My saved preset  ',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(presetForm, findsNothing);
    expect(
      runtimeGraph.settings.customEqPresets.single.labelKey,
      'My saved preset',
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
      matching: find.byType(UnifiedDropdownButtonFormField<String>),
    );
    expect(
      tester
          .widget<UnifiedDropdownButtonFormField<String>>(presetDropdown)
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
          .widget<UnifiedDropdownButtonFormField<String>>(presetDropdown)
          .initialValue,
      customPreset.id,
    );

    await tester.tap(find.text(languageProvider.tr('volume_balance')));
    await tester.pumpAndSettle();

    final restoreButton = find.byKey(
      const ValueKey<String>('restore_volume_balance'),
    );
    _expectThemeSessionResetButtonStyle(tester, restoreButton);
    expect(tester.getRect(restoreButton), speedRestoreRect);

    final pad = find.byKey(const ValueKey('sound_field_pad'));
    final initialPadHeight = tester.getSize(pad).height;
    final panel = find.byKey(expandedPanel);
    final initialPanelHeight = tester.getSize(panel).height;
    tester.view.physicalSize = const Size(430, 1000);
    await tester.pumpAndSettle();
    final extraHeight = tester.getSize(panel).height - initialPanelHeight;
    expect(extraHeight, greaterThan(0));
    expect(
      tester.getSize(pad).height,
      closeTo(initialPadHeight + extraHeight, 1),
    );
    expect(
      tester.getRect(panel).bottom - tester.getRect(restoreButton).bottom,
      16,
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
    'sound field commits a two-axis drag on release and can recenter',
    (tester) async {
      final windows = defaultTargetPlatform == TargetPlatform.windows;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = windows
          ? const Size(960, 600)
          : const Size(360, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final session = PlaybackSession(
        id: 'sound-field-session',
        currentTrackPath: '/library/stereo.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      )..audioEffects = AudioEffectsState(panning: 0.25);
      addTearDown(session.shutdown);
      fixture.playbackService.registerSession(session);
      final i18n = fixture.languageProvider;
      await tester.pumpWidget(
        fixture.build(
          Center(
            child: SizedBox(
              width: windows ? 520 : 344,
              height: windows ? 294 : 360,
              child: VolumeBalancePage(
                session: PlaybackSessionSnapshot.fromRuntime(session),
                playback: fixture.playback,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(i18n.tr('sound_field_front')));
      await tester.pumpAndSettle();
      expect(session.audioEffects.panning, 0.25);
      expect(session.audioEffects.frontBack, 0.1);

      final pad = find.byKey(const ValueKey('sound_field_pad'));
      final position = find.bySemanticsLabel(i18n.tr('volume_balance'));
      final rect = tester.getRect(pad);
      final gesture = await tester.startGesture(
        rect.center,
        kind: windows ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
      );
      await gesture.moveBy(const Offset(-25, -25));
      await gesture.moveTo(rect.topLeft + const Offset(5, 5));
      await tester.pump();
      expect(session.audioEffects.panning, 0.25);
      expect(session.audioEffects.frontBack, 0.1);
      expect(
        tester.getSemantics(position).getSemanticsData().value,
        '${i18n.tr('sound_field_left')} 100%, ${i18n.tr('sound_field_front')} 100%',
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(session.audioEffects.panning, -1);
      expect(session.audioEffects.frontBack, 1);

      await tester.tapAt(rect.center + const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(session.audioEffects.panning, 0);
      expect(session.audioEffects.frontBack, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(session.audioEffects.panning, 0);
      expect(session.audioEffects.frontBack, -0.1);

      final restore = find.byKey(const ValueKey('restore_volume_balance'));
      expect(tester.widget<FilledButton>(restore).onPressed, isNotNull);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(session.audioEffects, AudioEffectsState.flat);
      expect(tester.widget<FilledButton>(restore).onPressed, isNull);
      expect(
        tester.getSemantics(position).getSemanticsData().value,
        i18n.tr('sound_field_centered'),
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
      ], persist: false);
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

      await tester.tap(
        find.descendant(of: startRow, matching: find.text('00:18')),
      );
      await tester.pumpAndSettle();
      final timeForm = find.byType(AppEditPanelForm);
      expect(tester.getSize(timeForm).height, 192);
      final timeInput = find.descendant(
        of: timeForm,
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(timeInput).controller?.text, '00:18');
      await tester.enterText(timeInput, 'invalid');
      await tester.tap(find.widgetWithText(TextButton, i18n.tr('confirm')));
      await tester.pumpAndSettle();
      expect(timeForm, findsOneWidget);
      await tester.enterText(timeInput, '00:00:20');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(timeForm, findsNothing);
      expect(
        find.descendant(of: startRow, matching: find.text('00:20')),
        findsOneWidget,
      );
      await tester.tap(
        find.widgetWithText(FilledButton, i18n.tr('segment_start')),
      );
      await tester.pump();

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

  for (final boundary in ['collapse', 'selection', 'track', 'dispose']) {
    testWidgets(
      'segment pending name saves retain their identity on $boundary',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final tracks = List.generate(
          2,
          (index) => testMusicTrack(
            name: 'Boundary $index',
            path: '/segments/boundary-$index.mp3',
            groupKey: '/segments',
            groupTitle: 'Boundary work',
          ),
        );
        fixture.library.addTracks(tracks, persist: false);
        final session = fixture.playback.createTrackSession(tracks.first);
        final trackKey = TimeSegmentLabel.trackKeyFor(tracks.first);
        final labels = List.generate(
          2,
          (index) => TimeSegmentLabel(
            id: 'boundary-$index',
            trackKey: trackKey,
            name: 'Label $index',
            start: Duration(seconds: index * 10),
            end: Duration(seconds: index * 10 + 5),
            colorValue: kTimeSegmentLabelPalette[index],
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        );
        await tester.runAsync(() async {
          for (final label in labels) {
            await fixture.persistenceRepository.upsertTimeSegmentLabel(label);
          }
        });
        final key = GlobalKey<SessionDetailContentState>();
        Widget detail() => fixture.build(
          Scaffold(
            body: SessionDetailContent(
              key: key,
              session: PlaybackSessionSnapshot.fromRuntime(session),
              artworkWidget: const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pumpWidget(detail());
        await tester.pumpAndSettle();
        key.currentState!.expandSegmentPanel();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();
        var panel = tester.widget<TimeSegmentPanel>(
          find.byType(TimeSegmentPanel),
        );
        panel.onSelect(labels.first);
        await tester.pump();
        panel = tester.widget<TimeSegmentPanel>(find.byType(TimeSegmentPanel));
        final firstSave = Completer<void>();
        var saveStarted = false;
        fixture.persistenceRepository.beforeTimeSegmentLabelUpsert = () {
          saveStarted = true;
          return firstSave.future;
        };
        addTearDown(() {
          if (!firstSave.isCompleted) firstSave.complete();
        });
        panel.nameController.text = 'Intermediate';
        await tester.pump(const Duration(milliseconds: 350));
        expect(saveStarted, isTrue);
        panel.nameController.text = 'Final name';
        switch (boundary) {
          case 'collapse':
            key.currentState!.collapseSegmentPanel();
          case 'selection':
            panel.onSelect(labels.last);
          case 'track':
            session.currentTrackPath = tracks.last.path;
            await tester.pumpWidget(detail());
          case 'dispose':
            await tester.pumpWidget(const SizedBox.shrink());
        }
        fixture.persistenceRepository.beforeTimeSegmentLabelUpsert = null;
        firstSave.complete();
        List<TimeSegmentLabel>? stored;
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump();
          stored = await tester.runAsync(
            () => fixture.persistenceRepository.loadTimeSegmentLabels(trackKey),
          );
          if (stored!.any((label) => label.name == 'Final name')) break;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        final saved = stored!.singleWhere(
          (label) => label.id == labels.first.id,
        );
        expect(saved.name, 'Final name');
        expect(saved.createdAt, labels.first.createdAt);
        expect(saved.start, labels.first.start);
        expect(saved.end, labels.first.end);
        expect(
          stored.singleWhere((label) => label.id == labels.last.id).name,
          labels.last.name,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
      ], persist: false);
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
      for (
        var attempt = 0;
        attempt < 100 && undo.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await tester.pump();
      for (
        var attempt = 0;
        attempt < 100 && find.text('Renamed').evaluate().isEmpty;
        attempt++
      ) {
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
      await tester.runAsync(
        () => fixture.library.detailCacheService.waitForPendingOperations(),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'playlist keeps 500 sessions within a bounded scroll window',
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
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.android
          ? const Size(412, 892)
          : const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final covers = _RecordingPlaybackCoverCacheService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: covers,
      );
      addTearDown(fixture.dispose);
      final tracks = List.generate(
        500,
        (index) => testMusicTrack(
          name: 'Scroll session $index',
          path: '/playlist-scroll/track-$index.mp3',
          groupKey: '/playlist-scroll',
          groupTitle: 'Scroll work',
        ),
      );
      fixture.runtimeGraph.library.addTracks(tracks, persist: false);
      final sessions = tracks.map((track) {
        final session = fixture.runtimeGraph.playback.createTrackSession(track);
        addTearDown(session.shutdown);
        return session;
      }).toList();
      fixture.playbackService.syncSlice(
        activeSessions: sessions,
        playingSessionCount: 0,
        focusedSessionId: sessions.first.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      // Drain the focused media notification before measuring list requests.
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      covers.requestedPaths.clear();
      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pumpAndSettle();
      await pumpUntilUiIdle(tester);
      await tester.pumpAndSettle();
      final list = find.byKey(const PageStorageKey<String>('playlist_list'));
      final controller = tester.widget<ListView>(list).controller!;
      final viewportHeight = tester.getSize(list).height;
      final initialLimit = ((viewportHeight + 320) / 64).ceil() + 1;
      final scrollingLimit = ((viewportHeight + 640) / 64).ceil() + 1;
      expect(
        find.byType(SessionListCard).evaluate().length,
        inInclusiveRange(1, initialLimit),
      );
      expect(
        covers.requestedPaths.toSet().length,
        lessThanOrEqualTo(initialLimit),
      );

      final initialList = tester.widget<ListView>(list);
      covers.resolvedPlaybackPaths.clear();
      covers.requestedPaths.clear();
      covers.invalidateFolder('/unrelated-work');
      await tester.pumpAndSettle();
      expect(tester.widget<ListView>(list), same(initialList));
      expect(covers.resolvedPlaybackPaths, isEmpty);
      expect(covers.requestedPaths, isEmpty);

      covers.invalidateFolder('/playlist-scroll');
      await tester.pumpAndSettle();
      expect(tester.widget<ListView>(list), same(initialList));
      expect(covers.resolvedPlaybackPaths, isNotEmpty);
      expect(
        covers.resolvedPlaybackPaths.toSet(),
        hasLength(lessThanOrEqualTo(initialLimit)),
      );

      await tester.drag(list, const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(
        find.byType(SessionListCard).evaluate().length,
        inInclusiveRange(1, scrollingLimit),
      );

      // Scrolling must recycle rows without rebuilding the retained cards.
      final retainedCards = find.byType(SessionListCard).evaluate().toSet();
      var retainedBuilds = 0;
      final previousRebuildHook = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousRebuildHook?.call(element, builtOnce);
        if (retainedCards.contains(element)) retainedBuilds++;
      };
      try {
        final gesture = await tester.startGesture(tester.getCenter(list));
        for (var frame = 0; frame < 12; frame++) {
          await gesture.moveBy(const Offset(0, -8));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(retainedBuilds, 0);
      } finally {
        debugOnRebuildDirtyWidget = previousRebuildHook;
      }

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlaylistTab)),
      );
      final lastId = container
          .read(playlistSortedEntriesUiProvider)
          .last
          .id;
      for (
        var attempt = 0;
        attempt < 20 && controller.position.extentAfter > 0.5;
        attempt++
      ) {
        await tester.drag(list, const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(
          find.byType(SessionListCard).evaluate().length,
          lessThanOrEqualTo(scrollingLimit),
        );
      }
      expect(controller.position.extentAfter, lessThanOrEqualTo(0.5));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SessionListCard && widget.sessionId == lastId,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
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
        Size.square(coverProgressInnerDimension(playlistCoverSize)),
      );
      expect(
        tester
            .widget<CoverArtworkFrame>(
              find.descendant(
                of: find.byKey(
                  const ValueKey('playlist_cover_single-duration-session'),
                ),
                matching: find.byType(CoverArtworkFrame),
              ),
            )
            .borderRadius,
        BorderRadius.circular(
          coverProgressInnerDimension(playlistCoverSize) / 2,
        ),
      );
      expect(
        tester
            .widget<CoverArtworkFrame>(
              find.descendant(
                of: find.byKey(
                  const ValueKey('playlist_cover_work-duration-session'),
                ),
                matching: find.byType(CoverArtworkFrame),
              ),
            )
            .borderRadius,
        BorderRadius.circular(
          coverProgressInnerDimension(playlistCoverSize) / 2,
        ),
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
    testWidgets(
      'queue edit from a left swipe or context menu closes via $dismissal',
      (tester) async {
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
        final isWindows = defaultTargetPlatform == TargetPlatform.windows;
        final editAction = find.byTooltip(
          fixture.languageProvider.tr('edit_playback_queue'),
        );
        if (isWindows) {
          await tester.tap(
            find.byType(PlaybackQueueCard),
            buttons: kSecondaryMouseButton,
            kind: PointerDeviceKind.mouse,
          );
          await tester.pumpAndSettle();
          final editLabel = find.text(fixture.languageProvider.tr('edit'));
          final editRow = find.ancestor(
            of: editLabel,
            matching: find.byType(AppEntryInkWell),
          );
          expect(
            find.descendant(
              of: editRow,
              matching: find.byIcon(Icons.edit_rounded),
            ),
            findsOneWidget,
          );
          await tester.tap(editLabel);
        } else {
          await tester.dragFrom(tester.getCenter(row), const Offset(180, 0));
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(row).dx, closeTo(initialLeft, 0.1));
          expect(editAction, findsNothing);
          expect(
            find.byTooltip(fixture.languageProvider.tr('pin_to_top')),
            findsNothing,
          );

          await tester.dragFrom(tester.getCenter(row), const Offset(-180, 0));
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(row).dx, lessThan(initialLeft));
          expect(
            find.descendant(
              of: editAction,
              matching: find.byIcon(Icons.edit_rounded),
            ),
            findsOneWidget,
          );
          await tester.tap(editAction);
        }
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackQueueEditPage), findsOneWidget);
        expect(tester.getTopLeft(row).dx, closeTo(initialLeft, 0.1));

        if (dismissal == 'nested editor') {
          final i18n = fixture.languageProvider;
          final audioEntry = find.text(i18n.tr('edit_queue_audio'));
          final dynamic controller = Material.of(tester.element(audioEntry));
          Iterable<InteractiveInkFeature> visibleInk() =>
              (controller.debugInkFeatures as List<InkFeature>? ?? [])
                  .whereType<InteractiveInkFeature>()
                  .where((feature) => feature.color.a > 0);

          final gesture = await tester.startGesture(
            tester.getCenter(audioEntry),
          );
          await tester.pump(const Duration(milliseconds: 120));
          expect(visibleInk(), isNotEmpty);
          await gesture.up();
          await tester.pump(const Duration(milliseconds: 220));
          expect(visibleInk(), isEmpty);
          await tester.pumpAndSettle();
          expect(find.byType(PlaybackQueueAudioEditPage), findsOneWidget);
          expect(tester.getTopLeft(row).dx, closeTo(initialLeft, 0.1));
          Navigator.of(
            tester.element(find.byType(PlaybackQueueAudioEditPage)),
          ).pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 150));
          expect(visibleInk(), isEmpty);
          await tester.pumpAndSettle();
          expect(find.byType(PlaybackQueueEditPage), findsOneWidget);
          expect(tester.getTopLeft(row).dx, closeTo(initialLeft, 0.1));
        }
        if (dismissal == 'outside') {
          await tester.tapAt(const Offset(10, 10));
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackQueueEditPage), findsNothing);
        expect(tester.getTopLeft(row).dx, closeTo(initialLeft, 0.1));
        if (!isWindows && dismissal == 'outside') {
          await tester.longPressAt(tester.getCenter(row));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('playlist_batch_selection_header')),
            findsOneWidget,
          );
          await tester.dragFrom(tester.getCenter(row), const Offset(-180, 0));
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(row).dx, closeTo(initialLeft, 0.1));
          expect(editAction, findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'volume input shares the queue name style and uses a centered dialog',
    (tester) async {
      final windows = defaultTargetPlatform == TargetPlatform.windows;
      final harness = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
        physicalSize: windows ? const Size(2880, 1800) : const Size(1170, 2100),
        queueTracks: [
          testMusicTrack(
            name: 'Track',
            path: '/library/volume/track.mp3',
            groupKey: '/library/volume',
            groupTitle: 'Volume test',
          ),
        ],
        queueColorValue: 0xff425bb4,
      );
      addTearDown(tester.view.resetViewInsets);
      final i18n = harness.fixture.languageProvider;
      final nameInput = find.byKey(const ValueKey('playback_queue_name_input'));
      final nameSurface = find.byKey(
        const ValueKey('playback_queue_panel_surface'),
      );
      final volumeInput = find.byKey(const ValueKey('session_volume_input'));
      final volumeSurface = find.byKey(
        const ValueKey('session_volume_input_surface'),
      );
      final keyboard = FakeViewPadding(bottom: windows ? 1080 : 1290);
      final ratio = tester.view.devicePixelRatio;
      final screen = tester.view.physicalSize / ratio;

      unawaited(
        showPlaybackQueueEditPanel(
          tester.element(find.byType(SessionDetailContent)),
          harness.session.id,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(i18n.tr('edit_queue_name')));
      await tester.pumpAndSettle();
      final nameRect = tester.getRect(nameInput);
      final surfaceRect = tester.getRect(nameSurface);
      final nameRadius =
          (tester.widget<DecoratedBox>(nameSurface).decoration as BoxDecoration)
              .borderRadius;
      final nameDecoration = InputDecorationTheme.of(tester.element(nameInput));
      final nameIcon = tester.widget<Icon>(
        find.byKey(const ValueKey('playback_queue_name_header_icon')),
      );
      Navigator.of(tester.element(nameInput)).pop();
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('session_volume_button_anchor')),
      );
      await tester.pumpAndSettle();
      final percent = find.byKey(const ValueKey('session_volume_percent_text'));
      await tester.tap(percent);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('app_dialog_scrim')), findsOneWidget);
      final volumeRect = tester.getRect(volumeSurface);
      final inputRect = tester.getRect(volumeInput);
      expect(volumeRect.center, screen.center(Offset.zero));
      expect(volumeRect.height, surfaceRect.height);
      expect(inputRect.height, nameRect.height);
      expect(
        inputRect.topLeft - volumeRect.topLeft,
        nameRect.topLeft - surfaceRect.topLeft,
      );
      expect(
        (tester.widget<DecoratedBox>(volumeSurface).decoration as BoxDecoration)
            .borderRadius,
        nameRadius,
      );
      expect(
        InputDecorationTheme.of(tester.element(volumeInput)),
        nameDecoration,
      );
      final volumeIcon = tester.widget<Icon>(
        find.descendant(
          of: volumeSurface,
          matching: find.byIcon(Icons.volume_up_rounded),
        ),
      );
      expect(volumeIcon.color, nameIcon.color);
      expect(volumeIcon.size, nameIcon.size);
      final field = tester.widget<TextField>(volumeInput);
      expect(field.keyboardType, TextInputType.number);
      expect(field.controller!.text, '100');
      tester.view.viewInsets = keyboard;
      await tester.pumpAndSettle();
      final availableHeight = screen.height - keyboard.bottom / ratio;
      final rectWithKeyboard = tester.getRect(volumeSurface);
      expect(rectWithKeyboard.center.dy, closeTo(availableHeight / 2, 0.01));
      expect(rectWithKeyboard.bottom, lessThanOrEqualTo(availableHeight));

      final confirm = find.widgetWithText(TextButton, i18n.tr('confirm'));
      final cancel = find
          .widgetWithText(TextButton, i18n.tr('cancel'))
          .hitTestable();
      await tester.enterText(volumeInput, '151');
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(volumeInput, findsOneWidget);
      expect(harness.session.volume, 1);
      await tester.enterText(volumeInput, '75');
      await tester.tap(cancel);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(volumeInput, findsNothing);
      expect(harness.session.volume, 1);

      await tester.tap(percent);
      await tester.pumpAndSettle();
      await tester.enterText(volumeInput, '75');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(volumeInput, findsNothing);
      expect(harness.session.volume, 0.75);
      expect(find.text('75%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final action in ['cancel', 'save', 'submit', 'back']) {
    testWidgets(
      'queue name menu resizes from the edit menu top and fades on $action',
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
        final windows = defaultTargetPlatform == TargetPlatform.windows;
        final size = windows ? const Size(960, 600) : const Size(390, 700);
        final systemPadding = FakeViewPadding(bottom: windows ? 0 : 24);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.view.viewPadding = systemPadding;
        tester.view.padding = systemPadding;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewInsets);
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
        await tester.pumpWidget(fixture.build(const SizedBox()));
        unawaited(
          showPlaybackQueueEditPanel(
            tester.element(find.byType(Scaffold)),
            session.id,
          ),
        );
        await tester.pumpAndSettle();
        final i18n = fixture.languageProvider;
        final edit = find.byKey(const ValueKey('playback_queue_edit_panel'));
        final name = find.byKey(const ValueKey('playback_queue_name_panel'));
        final input = find.byKey(const ValueKey('playback_queue_name_input'));
        final surface = find.byKey(const ValueKey('playback_queue_panel_surface'));
        final originalRect = tester.getRect(edit);
        expect(tester.getRect(surface), originalRect);
        final remove = find.widgetWithText(TextButton, i18n.tr('remove_queue'));
        final originalButtonRect = tester.getRect(remove);
        final originalStyle = tester.widget<TextButton>(remove).style!;
        await tester.tap(find.text(i18n.tr('edit_queue_name')));
        await tester.pump();
        double opacity() => tester
            .widget<FadeTransition>(
              find
                  .ancestor(of: name, matching: find.byType(FadeTransition))
                  .first,
            )
            .opacity
            .value;
        expect(opacity(), 0);
        expect(tester.getRect(surface), originalRect);
        await tester.pump(kAppFadeDuration ~/ 2);
        expect(opacity(), closeTo(0.5, 0.03));
        final intermediateRect = tester.getRect(surface);
        expect(intermediateRect.top, originalRect.top);
        expect(intermediateRect.bottom, lessThan(originalRect.bottom));
        expect(
          find.text(i18n.tr('edit_queue_audio')).hitTestable(),
          findsNothing,
        );
        await tester.pump(kAppFadeDuration ~/ 2);
        expect(opacity(), 1);
        final save = find.widgetWithText(TextButton, i18n.tr('save'));
        final cancel = find.widgetWithText(TextButton, i18n.tr('cancel'));
        final header = find.byKey(
          const ValueKey('playback_queue_name_header_icon'),
        );
        final nameRect = tester.getRect(name);
        final inputRect = tester.getRect(input);
        expect(nameRect.width, originalRect.width);
        expect(nameRect.top, originalRect.top);
        expect(nameRect.height, lessThan(originalRect.height));
        expect(nameRect.bottom, lessThan(intermediateRect.bottom));
        expect(tester.getRect(surface), nameRect);
        final primaryFade = find.ancestor(
          of: edit,
          matching: find.byType(Opacity),
        ).first;
        expect(tester.widget<Opacity>(primaryFade).opacity, 0);
        expect(nameRect.center.dy, lessThan(size.height / 2));
        expect(inputRect.top, closeTo(tester.getRect(header).bottom + 12, 0.5));
        expect(tester.getRect(save).right, originalButtonRect.right);
        expect(tester.getRect(save).height, originalButtonRect.height);
        for (final button in [save, cancel]) {
          final style = tester.widget<TextButton>(button).style!;
          expect(style.shape!.resolve({}), originalStyle.shape!.resolve({}));
          expect(
            style.textStyle!.resolve({}),
            originalStyle.textStyle!.resolve({}),
          );
        }
        expect(tester.widget<TextField>(input).controller!.text, 'Queue');
        await tester.enterText(input, '   ');
        await tester.tap(save);
        await tester.pump();
        expect(name, findsOneWidget);
        expect(session.playbackQueue!.name, 'Queue');
        await tester.enterText(input, '  New queue  ');
        final keyboardHeight = windows ? 180.0 : 320.0;
        tester.view.padding = FakeViewPadding.zero;
        for (final fraction in [0.25, 0.5, 0.75, 1.0]) {
          tester.view.viewInsets = FakeViewPadding(
            bottom: keyboardHeight * fraction,
          );
          await tester.pump();
          expect(tester.getRect(name), nameRect);
          expect(tester.getRect(input), inputRect);
        }
        for (final control in [input, save, cancel]) {
          expect(
            tester.getRect(control).bottom,
            lessThan(size.height - keyboardHeight),
          );
        }
        if (action == 'cancel' && !windows) {
          const tallKeyboardHeight = 430.0;
          tester.view.viewInsets = const FakeViewPadding(
            bottom: tallKeyboardHeight,
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(name).top, lessThan(nameRect.top));
          expect(
            tester.getRect(name).bottom,
            lessThanOrEqualTo(size.height - tallKeyboardHeight),
          );
          expect(save.hitTestable(), findsOneWidget);
          tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
          await tester.pumpAndSettle();
          expect(tester.getRect(name), nameRect);
        }
        expect(tester.takeException(), isNull);
        switch (action) {
          case 'cancel':
            await tester.tap(cancel);
          case 'save':
            await tester.tap(save);
          case 'submit':
            await tester.testTextInput.receiveAction(TextInputAction.done);
          case 'back':
            await tester.binding.handlePopRoute();
        }
        await tester.pump();
        expect(opacity(), 1);
        expect(
          session.playbackQueue!.name,
          action == 'save' || action == 'submit' ? 'New queue' : 'Queue',
        );
        expect(
          tester.widget<TextField>(input).controller!.text,
          '  New queue  ',
        );
        await tester.pump(kAppFadeDuration ~/ 2);
        expect(opacity(), closeTo(0.5, 0.03));
        expect(tester.getRect(surface).top, originalRect.top);
        expect(tester.getRect(surface).bottom, greaterThan(nameRect.bottom));
        await tester.pump(kAppFadeDuration ~/ 2 - const Duration(milliseconds: 1));
        expect(name, findsOneWidget);
        expect(
          find.text(i18n.tr('edit_queue_audio')).hitTestable(),
          findsNothing,
        );
        await tester.pump(const Duration(milliseconds: 2));
        expect(name, findsNothing);
        tester.view.viewInsets = FakeViewPadding.zero;
        tester.view.padding = systemPadding;
        await tester.pumpAndSettle();
        expect(tester.getRect(edit), originalRect);
        expect(
          find.text(i18n.tr('edit_queue_audio')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
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
        final editPanel = find.byKey(const ValueKey('playback_queue_edit_panel'));
        final cardName = find.byKey(
          ValueKey('playback_queue_name_${session.id}'),
        );
        final editName = find.descendant(
          of: editPanel,
          matching: find.text('Queue'),
        );
        final defaultColor = Theme.of(
          tester.element(cardName),
        ).colorScheme.primary;
        void expectNameColor(Color color) {
          expect(tester.widget<Text>(cardName).style?.color, color);
          expect(tester.widget<Text>(editName).style?.color, color);
        }

        expectNameColor(defaultColor);
        final editRect = tester.getRect(editPanel);
        await tester.tap(find.text(i18n.tr('edit_queue_color')));
        await tester.pumpAndSettle();
        final editPanelOpacity = tester.widget<Opacity>(
          find
              .ancestor(of: editPanel, matching: find.byType(Opacity))
              .first,
        );
        expect(editPanelOpacity.opacity, 0);
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
        final selectedColor = Color(session.playbackQueue!.colorValue!);
        expect((selectedColor.r * 255).round(), 160);
        expectNameColor(selectedColor);
        await tester.tap(find.text(i18n.tr('reset_to_default')));
        await tester.pump();
        expect(session.playbackQueue!.colorValue, isNull);
        expectNameColor(defaultColor);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'playlist queue rows only resolve artwork used by the cover mosaic',
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
      final covers = _RecordingPlaybackCoverCacheService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: covers,
      );
      addTearDown(fixture.dispose);
      final tracks = List.generate(
        2,
        (index) => testMusicTrack(
          name: 'Queue track $index',
          path: '/library/queue-artwork/track-$index.mp3',
          groupKey: '/library/queue-artwork',
          groupTitle: 'Queue work',
        ),
      );
      fixture.library.addTracks(tracks, persist: false);
      final session = fixture.playback.createPlaybackQueue('Queue')
        ..currentTrackPath = tracks.last.path
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'Queue',
          entries: [
            PlaybackQueueEntry(
              id: 'work',
              kind: PlaybackQueueEntryKind.work,
              title: 'Queue work',
              tracks: tracks,
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
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      covers.resolvedPlaybackPaths.clear();

      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pumpAndSettle();

      expect(find.byType(PlaybackQueueCard), findsOneWidget);
      expect(covers.resolvedPlaybackPaths, contains(tracks.first.path));
      expect(covers.resolvedPlaybackPaths, isNot(contains(tracks.last.path)));
      expect(find.text(tracks.last.displayName), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('queue cover lookup is reused across card rebuilds', (
    tester,
  ) async {
    final coverCache = _RecordingPlaybackCoverCacheService();
    final tickerEnabled = ValueNotifier(true);
    addTearDown(tickerEnabled.dispose);
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
      ValueListenableBuilder<bool>(
        valueListenable: tickerEnabled,
        builder: (context, enabled, child) =>
            TickerMode(enabled: enabled, child: child!),
        child: Center(
          child: SizedBox(
            width: 400,
            child: PlaybackQueueCard(
              sessionId: session.id,
              library: fixture.runtimeGraph.library,
              playback: fixture.runtimeGraph.playback,
              coverCacheWidth: 96,
              onOpen: (_) {},
              onEdit: () {},
            ),
          ),
        ),
      ),
    );

    syncCoverGeneration(0);
    await tester.pumpWidget(card());
    await tester.pump();
    expect(coverCache.requestedPaths, [track.path]);

    final coverLookups = coverCache.resolvedPlaybackPaths.length;
    tickerEnabled.value = false;
    await tester.pump();
    tickerEnabled.value = true;
    await tester.pump();
    expect(coverCache.resolvedPlaybackPaths.length, coverLookups);

    await tester.pumpWidget(card());
    await tester.pump();
    expect(coverCache.requestedPaths, [track.path]);

    syncCoverGeneration(1);
    await tester.pump();
    await tester.pumpWidget(card());
    await tester.pump();
    expect(coverCache.requestedPaths, [track.path, track.path]);
    await tester.pump(const Duration(milliseconds: 200));

    final addedTrack = testMusicTrack(
      name: 'Added track',
      path: '/library/queue/added.mp3',
      groupKey: '/library/queue',
      groupTitle: 'Queue work',
    );
    await fixture.playback.addTrackToPlaybackQueue(session.id, addedTrack);
    await tester.pumpAndSettle();
    expect(coverCache.requestedPaths, contains(addedTrack.path));
  });

  testWidgets(
    'large queue discovers later covers in bounded batches and reuses them',
    (tester) async {
      final interaction = UiInteractionCoordinator.instance;
      interaction.resetForTest();
      addTearDown(interaction.resetForTest);
      final covers = _RecordingPlaybackCoverCacheService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: covers,
      );
      addTearDown(fixture.dispose);
      final tracks = List.generate(
        160,
        (index) => testMusicTrack(
          name: 'Queue track $index',
          path: '/queue/$index.mp3',
          groupKey: '/queue',
          groupTitle: 'Queue',
          isSingle: true,
        ),
      );
      tracks.last = tracks.last.copyWith(isVideo: true);
      final session = fixture.playback.createPlaybackQueue('Queue')
        ..currentTrackPath = tracks.first.path
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'Queue',
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
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      Widget card(int mount) => fixture.build(
        Center(
          child: PlaybackQueueCard(
            key: ValueKey(mount),
            sessionId: session.id,
            library: fixture.library,
            playback: fixture.playback,
            coverCacheWidth: 96,
            onOpen: (_) {},
            onEdit: () {},
          ),
        ),
      );

      final scrolling = Object();
      interaction.beginInteraction(scrolling);
      await tester.pumpWidget(card(0));
      expect(covers.resolvedPlaybackPaths.length, lessThan(tracks.length));
      expect(covers.resolvedPlaybackPaths, isNot(contains(tracks.last.path)));
      expect(find.byType(QueueTrackCover), findsNothing);

      interaction.cancelInteraction(scrolling);
      await tester.pumpAndSettle();
      expect(
        tester.widget<QueueTrackCover>(find.byType(QueueTrackCover)).track,
        tracks.last,
      );

      covers.resolvedPlaybackPaths.clear();
      await tester.pumpWidget(card(1));
      await tester.pumpAndSettle();
      expect(covers.resolvedPlaybackPaths.toSet(), {tracks.last.path});
      expect(
        tester.widget<QueueTrackCover>(find.byType(QueueTrackCover)).track,
        tracks.last,
      );
    },
  );

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
          matching: find.byElementPredicate((element) {
            final widget = element.widget;
            if (widget is! RawImage || widget.image == null) return false;
            Image? owner;
            element.visitAncestorElements((ancestor) {
              if (ancestor.widget is! Image) return true;
              owner = ancestor.widget as Image;
              return false;
            });
            // The loading placeholder has its own decoded brand icon.
            return owner?.image == provider;
          }),
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

  testWidgets(
    'queue cover flies in both directions after replaying a completed round',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.android
          ? const Size(500, 1000)
          : const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final artworkPaths = (await tester.runAsync(() async {
        final folder = await Directory.systemTemp.createTemp('queue-replay-');
        addTearDown(() async {
          releaseRetainedCoverImages();
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          await tester.runAsync(() => folder.delete(recursive: true));
        });
        final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        );
        return [
          for (final name in ['first', 'last'])
            (await File('${folder.path}/$name.png').writeAsBytes(png)).path,
        ];
      }))!;
      final tracks = [
        for (final (work, audio) in [('first', 1), ('last', 1), ('last', 2)])
          testMusicTrack(
            name: '$work audio $audio',
            path: '/library/$work/$audio.mp3',
            groupKey: '/library/$work',
            groupTitle: work,
          ),
      ];
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(
          playbackCoverPaths: {
            tracks[0].path: artworkPaths[0],
            tracks[1].path: artworkPaths[1],
            tracks[2].path: artworkPaths[1],
          },
        ),
      );
      addTearDown(fixture.dispose);
      fixture.library.addTracks(tracks, persist: false);
      final playback = fixture.playback;
      final session = playback.createPlaybackQueue('Replay queue')
        ..loopMode = SessionLoopMode.crossOnce
        ..currentTrackPath = tracks.first.path
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'Replay queue',
          entries: [
            PlaybackQueueEntry(
              id: 'first-work',
              kind: PlaybackQueueEntryKind.work,
              title: 'First work',
              tracks: [tracks.first],
            ),
            PlaybackQueueEntry(
              id: 'last-work',
              kind: PlaybackQueueEntryKind.work,
              title: 'Last work',
              tracks: tracks.skip(1).toList(),
            ),
          ],
        );
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      void publishTrack(int index, {bool completed = false}) {
        expect(
          playback
              .applyNativeSnapshot(
                NativePlaybackSnapshot(
                  sessionId: session.id,
                  path: tracks[index].path,
                  queueIndex: index,
                  playing: !completed,
                  playWhenReady: !completed,
                  processingState: completed ? 'completed' : 'ready',
                  position: completed
                      ? const Duration(seconds: 10)
                      : Duration.zero,
                  bufferedPosition: const Duration(seconds: 10),
                  duration: const Duration(seconds: 10),
                  volume: 1,
                  boostGain: 1,
                  channelSwapEnabled: false,
                ),
                hasLibraryTrack: (_) => true,
              )
              .applied,
          isTrue,
        );
      }

      playback.detachCommandPort();
      playback.attachPlaybackCommands(
        prepareSession:
            (
              _, {
              required nextPath,
              autoPlay = true,
              forceStartAtZero = false,
              showLoading = true,
              targetQueueIndex,
            }) async {
              expect(nextPath, tracks.last.path);
              expect(forceStartAtZero, isTrue);
              publishTrack(2);
              return true;
            },
        pauseSession: (_) async {},
        startSession: (_, {required shouldStartTriggerCountdown}) async =>
            false,
        resolveAdvance: (_, {required forward}) => null,
        hasAdjacent: (_, {required forward}) => false,
      );
      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pumpAndSettle();
      final queueCover = find.byWidgetPredicate(
        (widget) =>
            widget is SessionCoverAnchor &&
            widget.location == SessionCoverLocation.playlist,
      );
      final anchor = tester.state<SessionCoverAnchorState>(queueCover);
      publishTrack(0);
      await tester.pump();
      publishTrack(1);
      await pumpUntilFound(
        tester,
        find.byElementPredicate(
          (element) =>
              element is StatefulElement &&
              identical(element.state, anchor) &&
              anchor.decodedImage != null,
          description: 'decoded artwork of the last work',
        ),
      );
      final lastWorkImage = anchor.decodedImage!;
      publishTrack(2);
      await tester.pump();
      publishTrack(2, completed: true);
      await pumpFiniteTransitions(tester);
      await tester.tap(find.byTooltip(fixture.languageProvider.tr('play')));
      await pumpFiniteTransitions(tester);
      expect(session.effectivePlaying, isTrue);
      expect(session.position, Duration.zero);

      final sourceBounds = anchor.bounds();
      expect(sourceBounds, isNotNull);
      await tester.tap(find.text('Replay queue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final flight = find.byKey(const ValueKey('session_detail_cover_flight'));
      expect(flight, findsOneWidget);
      final entering =
          tester.widget<CustomPaint>(flight).painter! as SessionCoverFlight;
      expect(entering.from, sourceBounds);
      expect(entering.image.isCloneOf(lastWorkImage), isTrue);
      await pumpFiniteTransitions(tester);
      await tester.tap(
        find.byKey(const ValueKey('session_detail_close_button')),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(flight, findsOneWidget);
      final leaving =
          tester.widget<CustomPaint>(flight).painter! as SessionCoverFlight;
      expect(leaving.reverse, isTrue);
      expect(leaving.to, sourceBounds);
      await pumpUntilNotFound(tester, find.byType(SessionDetailPage));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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
              sessionId: session.id,
              library: fixture.runtimeGraph.library,
              playback: fixture.runtimeGraph.playback,
              coverCacheWidth: 96,
              onOpen: (_) {},
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
        final expectedCenter =
            gridCenter +
            centerOffsets[count]![index] * (tester.getSize(grid).width / 52);
        final actualCenter = tester.getCenter(cell);
        expect(actualCenter.dx, closeTo(expectedCenter.dx, 0.01));
        expect(actualCenter.dy, closeTo(expectedCenter.dy, 0.01));
        if (count == 1) continue;
        final clip = tester.widget<ClipPath>(
          find.ancestor(of: cell, matching: find.byType(ClipPath)).first,
        );
        final path = clip.clipper!.getClip(tester.getSize(grid));
        for (var pointIndex = 0; pointIndex < count; pointIndex++) {
          expect(
            path.contains(
              sectorPoints[count]![pointIndex] *
                  (tester.getSize(grid).width / 52),
            ),
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

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'new playback queues fade in over 300 ms (reduced: $reducedMotion)',
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
        tester.view.physicalSize =
            defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1280, 800)
            : const Size(400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reducedMotion);
        addTearDown(
          tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final playback = fixture.runtimeGraph.playback;
        final existing = playback.createPlaybackQueue('Existing queue');
        fixture.playbackService.syncSlice(
          activeSessions: [existing],
          playingSessionCount: 0,
          focusedSessionId: existing.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        await tester.pumpWidget(fixture.build(const PlaylistTab()));
        await tester.pumpAndSettle();

        double opacityOf(String id) => tester
            .widget<Opacity>(
              find
                  .descendant(
                    of: find.byKey(ValueKey('playlist_queue_appearance_$id')),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;

        expect(opacityOf(existing.id), 1);
        await tester.tap(
          find.byTooltip(fixture.languageProvider.tr('add_playback_queue')),
        );
        await tester.pump();
        final created = playback.activeSessions.singleWhere(
          (session) => session.id != existing.id,
        );
        final card = find.byWidgetPredicate(
          (widget) =>
              widget is PlaybackQueueCard && widget.sessionId == created.id,
        );
        final initialRect = tester.getRect(card);
        expect(
          initialRect.top,
          lessThan(
            tester
                .getTopLeft(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is PlaybackQueueCard &&
                        widget.sessionId == existing.id,
                  ),
                )
                .dy,
          ),
        );
        expect(opacityOf(existing.id), 1);
        expect(opacityOf(created.id), reducedMotion ? 1 : 0);
        await tester.pump(kAppFadeDuration ~/ 2);
        expect(
          opacityOf(created.id),
          reducedMotion
              ? equals(1)
              : closeTo(kAppFadeCurve.transform(0.5), 0.001),
        );
        expect(tester.getRect(card), initialRect);
        await tester.pump(kAppFadeDuration ~/ 2 - const Duration(milliseconds: 1));
        expect(opacityOf(created.id), reducedMotion ? equals(1) : lessThan(1));
        await tester.pump(const Duration(milliseconds: 1));
        expect(opacityOf(created.id), 1);

        // Selection rebuilds the row without replaying its appearance.
        tester.widget<PlaybackQueueCard>(card).onLongPress!();
        await tester.pump();
        expect(opacityOf(created.id), 1);
        expect(opacityOf(existing.id), 1);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
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
    expect(topGap - 8, closeTo(bottomGap, 5));

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
    final confirmButton = find.byKey(const ValueKey('sort_options_confirm'));
    final confirmRect = tester.getRect(confirmButton);
    expect(
      find.descendant(of: confirmButton, matching: find.byType(FilledButton)),
      findsOneWidget,
    );
    expect(confirmRect.bottom, lessThanOrEqualTo(viewportSize.height));
    expect(cancelRect.center.dx, greaterThan(viewportSize.width / 2));
    expect(confirmRect.left - cancelRect.right, closeTo(8, 0.01));
    expect(confirmRect.center.dy, closeTo(cancelRect.center.dy, 0.01));
    expect(confirmRect.width, lessThan(120));
    final sortControls = find.byWidgetPredicate(
      (widget) => widget is SegmentedButton,
    );
    void expectSortIcon(IconData icon, Matcher matches) {
      expect(
        find.descendant(of: sortControls, matching: find.byIcon(icon)),
        matches,
      );
    }

    expectSortIcon(Icons.library_music_rounded, findsOneWidget);
    expectSortIcon(Icons.arrow_upward_rounded, findsNothing);
    expectSortIcon(Icons.arrow_downward_rounded, findsOneWidget);
    expectSortIcon(Icons.check, findsOneWidget);
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
    expectSortIcon(Icons.library_music_rounded, findsNothing);
    expectSortIcon(Icons.arrow_upward_rounded, findsOneWidget);
    expectSortIcon(Icons.arrow_downward_rounded, findsNothing);
    expectSortIcon(Icons.check, findsNWidgets(2));
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
      find.byTooltip(languageProvider.tr('resume_last_playback')),
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
    runtimeGraph.library.addTracks(<MusicTrack>[
      queueTrack,
      secondQueueTrack,
    ], persist: false);
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
    expect(
      find.descendant(
        of: find.byKey(ValueKey(queueSession.id)),
        matching: find.byTooltip(fixture.languageProvider.tr('more_actions')),
      ),
      findsNothing,
    );
    expect(queueCard.shape, same(playlistRowShape));
    expect(queueCard.margin, EdgeInsets.zero);
    final queueCoverGrid = find.byKey(
      const ValueKey('playback_queue_cover_grid'),
    );
    expect(queueCoverGrid, findsOneWidget);
    expect(
      tester.widget<CoverArtworkFrame>(queueCoverGrid).borderRadius,
      BorderRadius.circular(coverProgressInnerDimension(playlistCoverSize) / 2),
    );
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
    expect(queueName.style?.color, queueCardColor);
    expect(
      firstTrackName.textSpan!.toPlainText(includePlaceholders: false),
      queueTrack.displayName,
    );
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
          .textSpan!
          .toPlainText(includePlaceholders: false),
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
    await pumpFiniteTransitions(tester);

    final queueRowMaterial = tester.widget<Material>(
      find.byKey(ValueKey('playback_queue_row_surface_${queueSession.id}')),
    );
    expect(queueRowMaterial.color, Colors.transparent);
    expect(
      find.ancestor(
        of: find.byKey(
          ValueKey('playback_queue_card_content_${queueSession.id}'),
        ),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is ShapeDecoration &&
              (widget.decoration as ShapeDecoration).gradient != null,
        ),
      ),
      findsNothing,
    );

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
    await pumpFiniteTransitions(tester);

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
    await pumpFiniteTransitions(tester);
    expect(
      Theme.of(
        tester.element(find.byType(SessionDetailContent)),
      ).colorScheme.primary,
      queueCardColor,
    );
    Navigator.of(tester.element(find.byType(SessionDetailPage))).pop();
    await pumpFiniteTransitions(tester);

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
    expect(tester.widget<Icon>(headerIcon).icon, Icons.playlist_play_rounded);
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
    final editAudioIcon = find.descendant(
      of: find.byType(PlaybackQueueEditPage),
      matching: find.byIcon(Icons.edit_note_rounded),
    );
    expect(editAudioIcon, findsOneWidget);
    expect(
      find.ancestor(
        of: editAudioIcon,
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.decoration != null,
        ),
      ),
      findsOneWidget,
    );
    final audioTileCenterY = tester
        .getCenter(find.text(languageProvider.tr('edit_queue_audio')))
        .dy;
    final nameTileCenterY = tester
        .getCenter(find.text(languageProvider.tr('edit_queue_name')))
        .dy;
    final colorTileCenterY = tester
        .getCenter(find.text(languageProvider.tr('edit_queue_color')))
        .dy;
    expect(nameTileCenterY - audioTileCenterY, closeTo(68.0, 0.5));
    expect(colorTileCenterY - nameTileCenterY, closeTo(68.0, 0.5));

    final removeQueueText = find.text(languageProvider.tr('remove_queue'));
    expect(removeQueueText, findsOneWidget);
    final removeQueueFinder = find
        .ancestor(of: removeQueueText, matching: find.byType(TextButton))
        .first;
    final removeQueueButton = tester.widget<TextButton>(removeQueueFinder);
    expect(
      removeQueueButton.style?.shape?.resolve({}) is StadiumBorder,
      isTrue,
    );
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final restColor = DefaultTextStyle.of(
        tester.element(removeQueueText),
      ).style.color;
      final removeQueueMaterial = find.descendant(
        of: removeQueueFinder,
        matching: find.byType(Material),
      );
      final restBackground = tester.widget<Material>(removeQueueMaterial).color;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      await mouse.moveTo(tester.getCenter(removeQueueFinder));
      await tester.pumpAndSettle();

      final hoverScale = tester
          .widgetList<Transform>(
            find.ancestor(
              of: removeQueueText,
              matching: find.byType(Transform),
            ),
          )
          .where((t) => !t.transformHitTests)
          .fold<double>(1.0, (p, t) => p * t.transform.entry(0, 0));
      expect(hoverScale, closeTo(1.0, 0.001));
      expect(
        DefaultTextStyle.of(tester.element(removeQueueText)).style.color,
        isNot(equals(restColor)),
      );
      expect(
        tester.widget<Material>(removeQueueMaterial).color,
        restBackground,
      );

      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
    }
    final removeQueueCenter = tester.getCenter(removeQueueText);
    final editPanelRect = tester.getRect(
      find.byKey(const ValueKey('playback_queue_edit_panel')),
    );
    final headerIconRect = tester.getRect(headerIcon);
    expect(headerIconRect.size, const Size(40, 40));
    expect(headerIconRect.left - editPanelRect.left, closeTo(20, 0.5));
    expect(headerIconRect.top - editPanelRect.top, closeTo(20, 0.5));
    final audioTileRect = tester.getRect(
      find
          .ancestor(
            of: find.text(languageProvider.tr('edit_queue_audio')),
            matching: find.bySubtype<InkWell>(),
          )
          .first,
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
    await tester.pump(kAppFadeDuration ~/ 2);
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
    await pumpFiniteTransitions(tester);
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
            w is AppEntryInkWell &&
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
      tester.getTopLeft(presetColorButtons.first).dy -
          colorHeaderIconRect.bottom,
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
    await tester.pump(kAppFadeDuration);
    await tester.pump(const Duration(milliseconds: 1));
    expect(colorPanelFinder, findsNothing);
    await tester.tap(find.text(languageProvider.tr('edit_queue_audio')));
    await pumpFiniteTransitions(tester);
    final audioEditPage = find.byType(PlaybackQueueAudioEditPage);
    expect(audioEditPage, findsOneWidget);
    expect(
      find.descendant(
        of: audioEditPage,
        matching: find.byIcon(Icons.edit_note_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: audioEditPage,
        matching: find.byIcon(Icons.playlist_play_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: audioEditPage,
        matching: find.byType(PlaylistIcon),
      ),
      findsOneWidget,
    );
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('queue-entry')),
        matching: find.byType(ReorderableDelayedDragStartListener),
      ),
      findsOneWidget,
    );

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
    'restored queue editor retries and reads entries one page at a time',
    (tester) async {
      final repository = _PagedQueueRepository();
      final fixture = AppRuntimeWidgetTestFixture(
        providedPersistenceRepository: repository,
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..syncSlice(isInitialized: true),
      );
      addTearDown(fixture.dispose);
      final session = fixture.playback.createPlaybackQueue('Paged queue');
      session
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'Paged queue',
          entries: const [],
          storedEntryCount: 260,
          storedTrackCount: 260,
        )
        ..queueLoadingRequired = true;
      fixture.playback.publishSessionState(session.id);

      await tester.pumpWidget(fixture.build(
        PlaybackQueueAudioEditPage(sessionId: session.id),
      ));
      await tester.pumpAndSettle();
      final retry = find.text(fixture.languageProvider.tr('retry'));
      expect(retry, findsOneWidget);
      expect(repository.requests, [(0, 128)]);

      await tester.tap(retry);
      await tester.pumpAndSettle();
      final list = find.byType(ReorderableListView);
      expect(tester.widget<ReorderableListView>(list).itemCount, 128);
      final controller = tester.widget<ReorderableListView>(list).scrollController!;
      controller.jumpTo(controller.position.maxScrollExtent - 400);
      await tester.pumpAndSettle();
      expect(tester.widget<ReorderableListView>(list).itemCount, 256);
      expect(repository.requests, [(0, 128), (0, 128), (128, 128)]);
      expect(session.queueLoadingRequired, isTrue);
      expect(repository.queueLoads, 0);
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      final root = find.descendant(
        of: find.byKey(const ValueKey('saved-entry-0')),
        matching: find.byType(FileTreeRow),
      );
      expect(root, findsOneWidget);
      await tester.tap(root);
      await tester.pumpAndSettle();
      expect(repository.queueLoads, 0);
      expect(repository.entryLoads, ['saved-entry-0']);
      expect(session.queueLoadingRequired, isTrue);
      expect(tester.widget<ReorderableListView>(list).itemCount, 257);
      expect(
        find.text(repository.workTrack.displayName, findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final loadFails in [false, true]) {
    testWidgets(
      'first queue reorder moves a single track before a work (load failure: $loadFails)',
      (tester) async {
        tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
            ? const Size(960, 600)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final load = Completer<void>();
        addTearDown(() {
          if (!load.isCompleted) load.complete();
        });
        final repository = _PagedQueueRepository()..queueLoadGate = load.future;
        final fixture = AppRuntimeWidgetTestFixture(
          providedPersistenceRepository: repository,
          coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
          configureSettingsRepository: (settings) => settings
            ..workNameDisplay = WorkNameDisplay.folderName
            ..syncSlice(isInitialized: true),
        );
        addTearDown(fixture.dispose);
        final session = fixture.playback.createPlaybackQueue('Paged queue');
        session
          ..playbackQueue = PlaybackQueueDefinition(
            name: 'Paged queue',
            entries: const [],
            storedEntryCount: 260,
            storedTrackCount: 260,
          )
          ..queueLoadingRequired = true;
        fixture.playback.publishSessionState(session.id);
        await tester.pumpWidget(
          fixture.build(PlaybackQueueAudioEditPage(sessionId: session.id)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(fixture.languageProvider.tr('retry')));
        await tester.pumpAndSettle();

        final work = find.byKey(const ValueKey('saved-entry-0'));
        final single = find.byKey(const ValueKey('saved-entry-1'));
        final originalTop = tester.getTopLeft(single).dy;
        Finder row(Finder entry) =>
            find.descendant(of: entry, matching: find.byType(FileTreeRow));
        final singleRow = tester.widget<FileTreeRow>(row(single));
        expect(singleRow.titleMaxLines, 2);
        expect(singleRow.subtitleMaxLines, 1);
        expect(
          singleRow.subtitle,
          fixture.languageProvider.tr('audio_count', {'count': 1}),
        );
        expect(tester.getSize(row(single)), tester.getSize(row(work)));
        expect(singleRow.onTap, isNull);
        expect(repository.queueLoads, 0);
        final drag = await tester.startGesture(
          tester.getCenter(single),
          kind: defaultTargetPlatform == TargetPlatform.windows
              ? PointerDeviceKind.mouse
              : PointerDeviceKind.touch,
        );
        await tester.pump(kLongPressTimeout);
        await drag.moveTo(tester.getCenter(work));
        await tester.pumpAndSettle();
        await drag.up();
        await tester.pumpAndSettle();

        expect(repository.queueLoads, 1);
        expect(session.queueLoadingRequired, isTrue);
        final previewTop = tester.getTopLeft(single).dy;
        expect(previewTop, lessThan(originalTop));

        if (loadFails) {
          load.completeError(StateError('Failed to restore queue'));
          await tester.pumpAndSettle();
          expect(session.queueLoadingRequired, isTrue);
          expect(tester.getTopLeft(single).dy, closeTo(originalTop, 0.01));
          expect(
            find.descendant(
              of: single,
              matching: find.byType(ReorderableDelayedDragStartListener),
            ),
            findsOneWidget,
          );
        } else {
          load.complete();
          await tester.pumpAndSettle();
          expect(session.queueLoadingRequired, isFalse);
          expect(session.playbackQueue!.entries.first.id, 'saved-entry-1');
          expect(tester.getTopLeft(single).dy, closeTo(previewTop, 0.01));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'queue editor defers a fetched page while edge scrolling a drag',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
          ? const Size(960, 600)
          : const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final nextPage = Completer<void>();
      final repository = _PagedQueueRepository(
        firstPageFails: false,
        allWorks: true,
      )..nextPageGate = nextPage.future;
      final fixture = AppRuntimeWidgetTestFixture(
        providedPersistenceRepository: repository,
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..syncSlice(isInitialized: true),
      );
      addTearDown(fixture.dispose);
      final session = fixture.playback.createPlaybackQueue('Paged queue');
      session
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'Paged queue',
          entries: const [],
          storedEntryCount: 260,
          storedTrackCount: 260,
        )
        ..queueLoadingRequired = true;
      fixture.playback.publishSessionState(session.id);
      await tester.pumpWidget(
        fixture.build(PlaybackQueueAudioEditPage(sessionId: session.id)),
      );
      await tester.pumpAndSettle();

      final list = find.byType(ReorderableListView);
      final scroll = tester.widget<ReorderableListView>(list).scrollController!;
      scroll.jumpTo(scroll.position.maxScrollExtent - 550);
      await tester.pumpAndSettle();
      expect(repository.requests, [(0, 128)]);
      final handle = find
          .byType(ReorderableDelayedDragStartListener)
          .hitTestable()
          .first;
      final colors = Theme.of(tester.element(handle)).colorScheme;
      final dragColor = Color.alphaBlend(
        colors.primary.withValues(alpha: 0.18),
        colors.surface,
      );
      final proxy = find.byWidgetPredicate(
        (widget) => widget is Material && widget.color == dragColor,
      );
      final start = tester.getCenter(handle);
      final drag = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout);
      await drag.moveTo(Offset(start.dx, tester.getRect(list).bottom - 2));
      for (
        var frame = 0;
        frame < 40 && repository.requests.length == 1;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(repository.requests, [(0, 128), (128, 128)]);
      nextPage.complete();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<ReorderableListView>(list).itemCount, 128);
      expect(proxy, findsOneWidget);
      expect(tester.takeException(), isNull);

      await drag.cancel();
      await tester.pumpAndSettle();
      expect(tester.widget<ReorderableListView>(list).itemCount, 256);
      expect(proxy, findsNothing);
      expect(repository.queueLoads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('queue editor animates expanded audio without mounting the full work', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
      configureSettingsRepository: (settings) => settings
        ..workNameDisplay = WorkNameDisplay.folderName
        ..syncSlice(isInitialized: true),
    );
    addTearDown(fixture.dispose);
    final queue = fixture.playback.createPlaybackQueue('Queue');
    await fixture.playback.addWorkToPlaybackQueue(
      queue.id,
      title: 'Large work',
      workRootPath: '/library/work',
      tracks: [
        for (var index = 0; index < 600; index++)
          testMusicTrack(
            name: 'Audio $index',
            path: '/library/work/$index.mp3',
            groupKey: '/library/work',
            groupTitle: 'Work',
          ),
      ],
    );
    await tester.pumpWidget(
      fixture.build(PlaybackQueueAudioEditPage(sessionId: queue.id)),
    );
    await tester.pumpAndSettle();
    final list = find.byType(ReorderableListView);
    final rows = find.descendant(of: list, matching: find.byType(FileTreeRow));
    final firstAudio = find.text('Audio 0', findRichText: true);
    final transition = find.ancestor(
      of: firstAudio,
      matching: find.byType(SizeTransition),
    ).first;
    await tester.tap(rows);
    await tester.pump();
    expect(rows.evaluate().length, lessThan(100));
    await tester.pump(const Duration(milliseconds: 100));
    final expandingHeight = tester.getSize(transition).height;
    expect(expandingHeight, inExclusiveRange(0, 48));
    expect(rows.evaluate().length, lessThan(100));
    await tester.pumpAndSettle();

    await tester.tap(rows.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final collapsingHeight = tester.getSize(transition).height;
    expect(collapsingHeight, inExclusiveRange(0, 48));
    expect(firstAudio.hitTestable(), findsNothing);
    await tester.tap(rows.first);
    await tester.pump();
    expect(tester.getSize(transition).height, closeTo(collapsingHeight, 0.01));
    await tester.pumpAndSettle();

    await tester.tap(rows.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 215));
    expect(tester.getSize(transition).height, lessThan(1.0));
    expect(rows.evaluate().length, lessThan(100));
    await tester.pumpAndSettle();
    expect(rows, findsOneWidget);

    await tester.tap(rows);
    await tester.pumpAndSettle();
    final widget = tester.widget<ReorderableListView>(list);
    expect(widget.itemCount, 601);
    expect(rows.evaluate().length, lessThan(30));
    expect(find.text('Audio 599', findRichText: true), findsNothing);
    final scroll = widget.scrollController!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find.text('Audio 599', findRichText: true).hitTestable(),
      findsOneWidget,
    );
    expect(rows.evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'queue reorder reuses rows, scrolls at the edges and survives quick back',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
          ? const Size(960, 600)
          : const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final hapticCalls = <Object?>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(call.arguments);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final coverCache = _RecordingPlaybackCoverCacheService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: coverCache,
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..syncSlice(isInitialized: true),
      );
      addTearDown(fixture.dispose);
      final queue = fixture.playback.createPlaybackQueue('Queue');
      for (var index = 0; index < 24; index++) {
        await fixture.playback.addWorkToPlaybackQueue(
          queue.id,
          title: 'Work $index',
          tracks: [
            testMusicTrack(
              name: 'Track $index',
              path: '/library/work$index/track.mp3',
              groupKey: '/library/work$index',
              groupTitle: 'Work $index',
            ),
          ],
        );
      }
      fixture.playbackService.syncSlice(
        activeSessions: [queue],
        playingSessionCount: 0,
        focusedSessionId: queue.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(
        fixture.build(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                buildAppPageRoute<void>(
                  context: context,
                  child: PlaybackQueueAudioEditPage(sessionId: queue.id),
                ),
              ),
              child: const Text('Open queue reorder'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open queue reorder'));
      await tester.pumpAndSettle();

      final list = find.byType(ReorderableListView);
      final scroll = tester.widget<ReorderableListView>(list).scrollController!;
      scroll.jumpTo(300);
      await tester.pumpAndSettle();
      final addedHeader = find.ancestor(
        of: find.text(fixture.languageProvider.tr('queue_added_audio')),
        matching: find.byType(HeaderFloatingSurface),
      );
      final addedHeaderRect = tester.getRect(addedHeader);
      final headerBottom = addedHeaderRect.bottom;
      final backCapsule = find.descendant(
        of: find.byType(TopPageHeader),
        matching: find.byType(HeaderFloatingButton),
      );
      final backRect = tester.getRect(backCapsule);
      final cards = find.descendant(
        of: list,
        matching: find.byType(FileTreeRow),
      );
      final scrollBounds = tester.getRect(list);
      void expectCardsBehindFloatingCapsules() {
        expect(tester.getRect(list), scrollBounds);
        for (final point in [
          Offset(backRect.right + 4, backRect.center.dy),
          Offset(addedHeaderRect.right + 8, addedHeaderRect.center.dy),
        ]) {
          expect(scrollBounds.contains(point), isTrue);
          expect(
            cards.evaluate().any(
              (element) =>
                  tester.getRect(find.byWidget(element.widget)).contains(point),
            ),
            isTrue,
          );
        }
      }

      expectCardsBehindFloatingCapsules();
      final handles = find
          .byType(ReorderableDelayedDragStartListener)
          .hitTestable();
      final handle = handles.at(handles.evaluate().length ~/ 2);
      final start = tester.getCenter(handle);
      final colors = Theme.of(tester.element(handle)).colorScheme;
      final dragColor = Color.alphaBlend(
        colors.primary.withValues(alpha: 0.18),
        colors.surface,
      );
      final dragHighlight = find.byWidgetPredicate(
        (widget) => widget is Material && widget.color == dragColor,
      );
      hapticCalls.clear();
      final gesture = await tester.startGesture(start);
      const lastMillisecond = Duration(milliseconds: 1);
      await tester.pump(kLongPressTimeout - lastMillisecond);
      expect(hapticCalls, isEmpty);
      expect(dragHighlight, findsNothing);
      await tester.pump(lastMillisecond);
      expect(hapticCalls, [
        if (defaultTargetPlatform == TargetPlatform.android)
          'HapticFeedbackType.mediumImpact',
      ]);
      expect(dragHighlight, findsOneWidget);
      await gesture.moveBy(const Offset(0, -22));
      await tester.pump(const Duration(milliseconds: 100));
      expect(scroll.offset, 300);
      expectCardsBehindFloatingCapsules();

      coverCache.resolvedPlaybackPaths.clear();
      for (var i = 0; i < 3; i++) {
        await gesture.moveBy(const Offset(0, -2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(coverCache.resolvedPlaybackPaths, isEmpty);

      await gesture.moveTo(Offset(start.dx, headerBottom + 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(dragHighlight, findsOneWidget);
      expect(scroll.offset, lessThan(300));
      expectCardsBehindFloatingCapsules();

      await gesture.moveTo(start);
      await tester.pumpAndSettle();
      final offset = scroll.offset;
      await gesture.moveTo(Offset(start.dx, tester.getRect(list).bottom - 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(scroll.offset, greaterThan(offset));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(dragHighlight, findsNothing);
      expect(tester.getRect(list), scrollBounds);

      for (final closeAfterDrop in [false, true]) {
        final visibleHandles = find
            .byType(ReorderableDelayedDragStartListener)
            .hitTestable();
        final handleIndex = visibleHandles.evaluate().length ~/ 2;
        final movedHandle = visibleHandles.at(handleIndex);
        final previousHandle = visibleHandles.at(handleIndex - 1);
        final entries = queue.playbackQueue!.entries;
        final from = tester
            .widget<ReorderableDelayedDragStartListener>(movedHandle)
            .index;
        final to = tester
            .widget<ReorderableDelayedDragStartListener>(previousHandle)
            .index;
        final movedEntry = find.byKey(ValueKey(entries[from].id));
        final movedTrack = find.text(
          entries[from].tracks.single.displayName,
          findRichText: true,
        );
        final movedFolder = find.descendant(
          of: movedEntry,
          matching: find.byType(ReorderableDelayedDragStartListener),
        );
        if (!closeAfterDrop) {
          await tester.tap(movedFolder);
          await tester.pumpAndSettle();
          expect(movedTrack, findsOneWidget);
        }
        final target = tester.getCenter(previousHandle) + const Offset(0, 12);
        final drop = await tester.startGesture(tester.getCenter(movedFolder));
        await tester.pump(kLongPressTimeout);
        expect(movedTrack, findsNothing);
        await drop.moveBy(const Offset(0, -22));
        await tester.pump();
        await drop.moveTo(target);
        await tester.pump(const Duration(milliseconds: 250));
        await drop.up();
        if (closeAfterDrop) {
          await tester.tap(find.byType(AppHeaderBackButton));
          await tester.pump();
          expect(queue.playbackQueue!.entries, entries);
        }
        await tester.pumpAndSettle();
        expect(dragHighlight, findsNothing);
        expect(movedTrack, findsNothing);
        final expectedEntries = entries.toList();
        expectedEntries.insert(to, expectedEntries.removeAt(from));
        expect(queue.playbackQueue!.entries, expectedEntries);
      }
      expect(find.byType(PlaybackQueueAudioEditPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'closing edited queue audio page retains rows and defers removal feedback and cover scan',
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
      final interaction = UiInteractionCoordinator.instance;
      interaction.resetForTest();
      addTearDown(interaction.resetForTest);
      final observer = UiInteractionNavigatorObserver();
      addTearDown(observer.dispose);
      final coverCache = _RecordingPlaybackCoverCacheService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: coverCache,
      );
      addTearDown(fixture.dispose);

      final initialTrack = testMusicTrack(
        name: 'Initial queue track',
        path: '/library/initial/01.mp3',
        groupKey: '/library/initial',
        groupTitle: 'Initial work',
        isSingle: true,
      );
      final sourceTrack = testMusicTrack(
        name: 'Source track to add',
        path: '/library/source/01.mp3',
        groupKey: '/library/source',
        groupTitle: 'Source work',
        isSingle: true,
      );
      fixture.library.addTracks([initialTrack, sourceTrack], persist: false);
      final sourceSession = fixture.playback.createTrackSession(sourceTrack);
      final queueSession = fixture.playback.createPlaybackQueue('Queue');
      await fixture.playback.addTrackToPlaybackQueue(
        queueSession.id,
        initialTrack,
      );
      addTearDown(sourceSession.shutdown);
      addTearDown(queueSession.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: [sourceSession, queueSession],
        playingSessionCount: 0,
        focusedSessionId: queueSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        fixture.build(const PlaylistTab(), navigatorObservers: [observer]),
      );
      await tester.pumpAndSettle();

      unawaited(
        showPlaybackQueueEditPanel(
          tester.element(find.byType(PlaylistTab)),
          queueSession.id,
        ),
      );
      await tester.pumpAndSettle();

      final i18n = fixture.languageProvider;
      await tester.tap(find.text(i18n.tr('edit_queue_audio')));
      await tester.pumpAndSettle();

      final pageFinder = find.byType(PlaybackQueueAudioEditPage);
      expect(pageFinder, findsOneWidget);
      final pageScaffold = tester.widget<Scaffold>(
        find.descendant(of: pageFinder, matching: find.byType(Scaffold)).first,
      );
      expect(pageScaffold.backgroundColor, Colors.transparent);
      final contentTransition = tester.widget<AppPageContentTransition>(
        find
            .descendant(
              of: pageFinder,
              matching: find.byType(AppPageContentTransition),
            )
            .first,
      );
      expect(contentTransition.backgroundColor, isNotNull);

      await tester.tap(
        find.byTooltip(i18n.tr('add_audio_to_queue')).hitTestable().first,
      );
      await tester.pumpAndSettle();
      expect(queueSession.playbackQueue!.entries, hasLength(2));

      final entry = queueSession.playbackQueue!.entries.first;
      final row = find.byKey(ValueKey(entry.id));
      final removalService = ProviderScope.containerOf(
        tester.element(pageFinder),
      ).read(undoableRemovalServiceProvider);
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip(i18n.tr('remove'))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final rowHeight = tester.getSize(row).height;
      expect(rowHeight, greaterThan(0));

      coverCache.resolvedPlaybackPaths.clear();
      await tester.tap(find.byType(AppHeaderBackButton));
      await tester.pump();
      expect(interaction.isVisualUpdateDeferred, isTrue);
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getSize(row).height, closeTo(rowHeight, 0.01));
      expect(removalService.state.pendingCount, 0);
      expect(
        coverCache.resolvedPlaybackPaths,
        isNot(contains(sourceTrack.path)),
      );

      await tester.pumpAndSettle();
      expect(pageFinder, findsNothing);
      expect(removalService.state.pendingCount, 1);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(coverCache.resolvedPlaybackPaths, contains(sourceTrack.path));
      await tester.tap(find.textContaining(i18n.tr('undo')).hitTestable());
      await tester.pumpAndSettle();
      expect(removalService.state.pendingCount, 0);
      expect(queueSession.playbackQueue!.entries, hasLength(2));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'queue reorder maps visible entries while a removal can still be undone',
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
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..syncSlice(isInitialized: true),
      );
      addTearDown(fixture.dispose);
      final playback = fixture.runtimeGraph.playback;
      final queueSession = playback.createPlaybackQueue('Queue');
      addTearDown(queueSession.shutdown);
      for (var index = 0; index < 4; index++) {
        final track = testMusicTrack(
          name: 'Track $index',
          path: '/library/work$index/track.mp3',
          groupKey: '/library/work$index',
          groupTitle: 'Work $index',
        );
        if (index == 1) {
          await playback.addTrackToPlaybackQueue(queueSession.id, track);
          continue;
        }
        await playback.addWorkToPlaybackQueue(
          queueSession.id,
          title: 'Work $index',
          tracks: [track],
        );
      }
      fixture.playbackService.syncSlice(
        activeSessions: [queueSession],
        playingSessionCount: 0,
        focusedSessionId: queueSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(
        fixture.build(PlaybackQueueAudioEditPage(sessionId: queueSession.id)),
      );
      await tester.pumpAndSettle();
      final entries = queueSession.playbackQueue!.entries.toList();
      final removals = ProviderScope.containerOf(
        tester.element(find.byType(PlaybackQueueAudioEditPage)),
      ).read(undoableRemovalServiceProvider);
      await removals.stage(
        UndoableRemovalAction(
          key: playbackQueueEntryRemovalKey(queueSession.id, entries[0].id),
          commit: () =>
              playback.removePlaybackQueueEntry(queueSession.id, entries[0].id),
          undo: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReorderableListView>(find.byType(ReorderableListView))
            .itemCount,
        3,
      );
      tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .onReorder(0, 3);
      await tester.pumpAndSettle();
      expect(queueSession.playbackQueue!.entries.map((entry) => entry.id), [
        entries[0].id,
        entries[2].id,
        entries[3].id,
        entries[1].id,
      ]);
      tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .onReorder(2, 0);
      await tester.pumpAndSettle();
      expect(queueSession.playbackQueue!.entries.map((entry) => entry.id), [
        entries[0].id,
        entries[1].id,
        entries[2].id,
        entries[3].id,
      ]);
      await removals.undoPending();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReorderableListView>(find.byType(ReorderableListView))
            .itemCount,
        4,
      );
      expect(
        queueSession.playbackQueue!.entries.map((entry) => entry.id),
        entries.map((entry) => entry.id),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'queue editor loads the online work tree for a single-track session',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final work = AsmrWork.fromJson(const {
        'id': 123,
        'title': 'Online work',
        'sourceId': 'RJ000123',
        'resources': [
          {'source': 'japaneseAsmr', 'id': 123, 'code': 'RJ000123'},
        ],
      });
      MusicTrack remote(String name, String relativePath) => MusicTrack(
        path: 'https://example.test/$name.mp3',
        displayName: name,
        groupKey: 'asmr-work-${work.workKey}',
        groupTitle: work.title,
        groupSubtitle: work.sourceId,
        isSingle: false,
        remoteMetadataKind: MusicTrack.remoteMetadataKindJapaneseAsmr,
        remoteMetadata: {...work.toJson(), 'trackRelativePath': relativePath},
      );
      final current = remote('Current track', 'Current track.mp3');
      final sibling = remote('Nested track', 'Disc 2/Nested track.mp3');
      final controller = _QueueEditorAsmrController([current, sibling]);
      addTearDown(controller.dispose);
      final source = fixture.playback.createTrackSession(
        current,
        customQueueTracks: [current],
      );
      final queue = fixture.playback.createPlaybackQueue('Target queue');
      fixture.playbackService.syncSlice(
        activeSessions: [source, queue],
        playingSessionCount: 0,
        focusedSessionId: source.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(
        fixture.build(
          PlaybackQueueAudioEditPage(sessionId: queue.id),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final root = find.descendant(
        of: find.byKey(ValueKey(source.id)),
        matching: find.text(work.title, findRichText: true),
      );
      await tester.tap(root);
      await tester.pumpAndSettle();
      final folder = find.text('Disc 2', findRichText: true);
      expect(folder, findsOneWidget);
      await tester.tap(folder);
      await tester.pumpAndSettle();
      expect(find.text('Nested track', findRichText: true), findsOneWidget);
      expect(controller.requestedWork?.workKey, work.workKey);
      expect(
        controller.requestedWork?.preferredResource.source,
        AsmrCatalogSource.japaneseAsmr,
      );

      await tester.tap(root);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip(fixture.languageProvider.tr('add_work_to_queue')),
      );
      await tester.pumpAndSettle();
      expect(queue.playbackQueue!.entries.single.tracks, [current, sibling]);
      expect(source.customQueueTracks, [current]);

      controller.isOffline = true;
      await tester.tap(root);
      await tester.pumpAndSettle();
      expect(folder, findsNothing);
      expect(
        find.byTooltip(fixture.languageProvider.tr('add_audio_to_queue')),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'queue editor reveals a newly added remote audio entry',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = MusicTrack(
        path: 'https://example.test/audio.mp3',
        displayName: 'Remote source',
        groupKey: 'remote-work',
        groupTitle: 'Remote work',
        groupSubtitle: '',
        isSingle: false,
        remoteMetadataKind: 'asmr.one',
      );
      final source = fixture.playback.createTrackSession(
        track,
        customQueueTracks: [track],
      );
      final queue = fixture.playback.createPlaybackQueue('Remote queue');
      fixture.playbackService.syncSlice(
        activeSessions: [source, queue],
        playingSessionCount: 0,
        focusedSessionId: source.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      expect(fixture.library.trackByPath(track.path), isNull);
      await tester.pumpWidget(
        fixture.build(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                buildAppPageRoute<void>(
                  context: context,
                  child: PlaybackQueueAudioEditPage(sessionId: queue.id),
                ),
              ),
              child: const Text('Open queue editor'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open queue editor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remote work', findRichText: true));
      await tester.pumpAndSettle();
      final add = find.byTooltip(
        fixture.languageProvider.tr('add_audio_to_queue'),
      );
      expect(add, findsOneWidget);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(queue.playbackQueue!.expandedTracks.single.path, track.path);
      expect(
        find.byTooltip(fixture.languageProvider.tr('remove')),
        findsOneWidget,
      );
      for (var i = 0; i < 30; i++) {
        await fixture.playback.addTrackToPlaybackQueue(queue.id, track);
      }
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      final appended = queue.playbackQueue!.entries.last;
      expect(find.byKey(ValueKey(appended.id)).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'batch queue creation freezes sources before announcing its queue',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final tracks = List.generate(
        2,
        (index) => testMusicTrack(
          name: 'Snapshot $index',
          path: '/snapshot/$index.mp3',
          groupKey: '/snapshot/$index',
          groupTitle: 'Snapshot work $index',
        ),
      );
      fixture.library.addTracks(tracks, persist: false);
      final sources = tracks
          .map((track) => fixture.playback.createTrackSession(track))
          .toList();
      fixture.playbackService.syncSlice(
        activeSessions: sources,
        playingSessionCount: 0,
        focusedSessionId: sources.first.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      final selection = sources.map((session) => session.id).toSet();
      Future<void>? pending;
      await tester.pumpWidget(
        fixture.build(
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () {
                pending = PlaylistBatchActions.createPlaybackQueue(
                  ref: ref,
                  visibleEntries: ref.read(playlistStructureUiProvider).entries,
                  selectedSessionIds: selection,
                  playback: fixture.playback,
                  paths: ref.read(audioPathCoordinatorProvider),
                  onQueueAdded: selection.clear,
                );
              },
              child: const Text('Create snapshot queue'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create snapshot queue'));
      await tester.pumpAndSettle();
      await pending;
      expect(selection, isEmpty);
      final queue = fixture.playback.sessions.values
          .where((session) => session.isPlaybackQueue)
          .single;
      expect(
        queue.playbackQueue!.expandedTracks.map((track) => track.path).toSet(),
        tracks.map((track) => track.path).toSet(),
      );
    },
  );

  for (final fail in [false, true]) {
    testWidgets(
      'batch queue creation snapshots selection and rejects reentry, fail=$fail',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final tracks = List.generate(
          2,
          (index) => testMusicTrack(
            name: 'Batch source $index',
            path: '/batch/$index.mp3',
            groupKey: '/batch/$index',
            groupTitle: 'Batch work $index',
          ),
        );
        fixture.library.addTracks(tracks, persist: false);
        final sources = tracks
            .map((track) => fixture.playback.createTrackSession(track))
            .toList();
        fixture.playbackService.syncSlice(
          activeSessions: sources,
          playingSessionCount: 0,
          focusedSessionId: sources.first.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        await tester.pumpWidget(fixture.build(const PlaylistTab()));
        await tester.pumpAndSettle();
        await tester.longPress(find.text(tracks.first.displayName));
        await tester.pumpAndSettle();
        await tester.tap(find.text(tracks.last.displayName));
        await tester.pumpAndSettle();
        fixture.playback.detachRuntime();
        final sync = Completer<void>();
        addTearDown(() {
          if (!sync.isCompleted) sync.complete();
        });
        fixture.playback.attachPlaybackQueueSynchronizer((
          session, {
          bool selectFirst = false,
        }) async {
          await sync.future;
          if (fail) throw StateError('Queue synchronization failed');
        });
        final create = tester
            .widget<IconButton>(
              find.byKey(const ValueKey('batch_create_queue_button')),
            )
            .onPressed!;
        create();
        create();
        // The old close callback cannot clear a pending operation's selection.
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('exit_selection_button')),
            )
            .onPressed!();
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('batch_create_queue_button')),
              )
              .onPressed,
          isNull,
        );
        sync.complete();
        await tester.pumpAndSettle();
        final queue = fixture.playback.sessions.values
            .where((session) => session.isPlaybackQueue)
            .single;
        if (fail) {
          expect(
            find.byKey(const ValueKey('playlist_batch_selection_header')),
            findsOneWidget,
          );
          expect(
            find.text(fixture.languageProvider.tr('operation_failed_retry')),
            findsOneWidget,
          );
          expect(
            tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('batch_create_queue_button')),
                )
                .onPressed,
            isNotNull,
          );
          for (final source in sources) {
            expect(
              find.byKey(ValueKey('playlist_selection_indicator_${source.id}')),
              findsOneWidget,
            );
          }
        } else {
          expect(
            queue.playbackQueue!.expandedTracks
                .map((track) => track.path)
                .toSet(),
            tracks.map((track) => track.path).toSet(),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'queue edit tree adds and removes nested audio with one action per row',
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

      final fixture = AppRuntimeWidgetTestFixture(
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..syncSlice(isInitialized: true),
      );
      addTearDown(fixture.dispose);
      fixture.library.addWatchedLibrary('/library');
      final track = MusicTrack(
        path: '/library/work/Disc 1/track.mp3',
        displayName: 'Track',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: '/library/work',
        isSingle: false,
      );
      final sibling = testMusicTrack(
        name: 'Loose track',
        path: '/library/work/loose.mp3',
        groupKey: track.groupKey,
        groupTitle: track.groupTitle,
      );
      fixture.library.addTracks([track, sibling], persist: false);
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

      final i18n = fixture.languageProvider;
      final source = find.ancestor(
        of: find.byKey(ValueKey(sourceSession.id)),
        matching: find.byType(ListView),
      ).first;
      Finder row(String title, Finder pane) => find.descendant(
        of: pane,
        matching: find.byWidgetPredicate(
          (widget) => widget is FileTreeRow && widget.title == title,
        ),
      );
      Finder action(Finder row, String tooltip) {
        final button = find.descendant(
          of: row,
          matching: find.byType(IconButton),
        );
        final arrow = find.descendant(
          of: row,
          matching: find.byType(FileTreeExpansionArrow),
        );
        expect(button, findsOneWidget);
        final title = find.descendant(
          of: row,
          matching: find.text(
            tester.widget<FileTreeRow>(row).title,
            findRichText: true,
          ),
        );
        final labels = find
            .ancestor(of: title, matching: find.byType(Column))
            .first;
        expect(
          tester.getRect(button).left - tester.getRect(labels).right,
          closeTo(4, 0.01),
        );
        if (tester.widget<FileTreeRow>(row).isFolder) {
          expect(
            tester.getRect(arrow).left,
            greaterThan(tester.getRect(button).right),
          );
        } else {
          expect(arrow, findsNothing);
        }
        expect(
          find.descendant(of: row, matching: find.byType(TextButton)),
          findsNothing,
        );
        return find.descendant(
          of: row,
          matching: find.byTooltip(i18n.tr(tooltip)),
        );
      }

      expect(row('Disc 1', source), findsNothing);
      await tester.tap(action(row('Work', source), 'add_work_to_queue'));
      await tester.pumpAndSettle();
      expect(
        platformCalls.where((call) => call.method == 'HapticFeedback.vibrate'),
        hasLength(1),
      );
      final entry = queueSession.playbackQueue!.entries.single;
      expect(
        entry.tracks.map((track) => track.path),
        unorderedEquals([track.path, sibling.path]),
      );
      final added = find.byType(ReorderableListView);
      await tester.tap(row('Work', added));
      await tester.pumpAndSettle();
      expect(row('Disc 1', added), findsOneWidget);
      expect(row('Track', added), findsNothing);
      await tester.tap(row('Disc 1', added));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final nestedMotion = find.ancestor(
        of: row('Track', added),
        matching: find.byType(SizeTransition),
      ).first;
      expect(tester.getSize(nestedMotion).height, inExclusiveRange(0, 48));
      await tester.pumpAndSettle();
      expect(tester.widget<FileTreeRow>(row('Track', added)).depth, 2);
      expect(
        find.descendant(
          of: added,
          matching: find.byType(CoverArtworkFrame),
        ),
        findsOneWidget,
      );
      final drag = find.byType(ReorderableDelayedDragStartListener);
      expect(drag, findsOneWidget);
      expect(
        find.descendant(of: drag, matching: row('Work', added)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: drag, matching: row('Track', added)),
        findsNothing,
      );
      expect(find.byIcon(Icons.drag_handle_rounded), findsOneWidget);

      await tester.tap(action(row('Track', added), 'remove'));
      await tester.pumpAndSettle();
      expect(row('Track', added), findsNothing);
      expect(row('Loose track', added), findsOneWidget);
      final removals = ProviderScope.containerOf(
        tester.element(find.byType(PlaybackQueueAudioEditPage)),
      ).read(undoableRemovalServiceProvider);
      await removals.undoPending();
      await tester.pumpAndSettle();
      expect(row('Track', added), findsOneWidget);
      await tester.tap(action(row('Disc 1', added), 'remove'));
      await tester.pumpAndSettle();
      await removals.commitPending();
      await tester.pumpAndSettle();
      expect(
        queueSession.playbackQueue!.entries.single.tracks.single.path,
        sibling.path,
      );
      expect(row('Disc 1', added), findsNothing);

      await tester.tap(row('Work', source));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final sourceMotion = find.ancestor(
        of: row('Disc 1', source),
        matching: find.byType(SizeTransition),
      ).first;
      expect(tester.getSize(sourceMotion).height, inExclusiveRange(0, 48));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: source,
          matching: find.byType(CoverArtworkFrame),
        ),
        findsOneWidget,
      );
      await tester.tap(action(row('Disc 1', source), 'add'));
      await tester.pumpAndSettle();
      expect(
        queueSession.playbackQueue!.entries.last.tracks.single.path,
        track.path,
      );
      expect(find.descendant(of: source, matching: drag), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'playback queue audio edit page renders floating capsule section headers and scrolls on add',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
          ? const Size(960, 600)
          : const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
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
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..syncSlice(isInitialized: true),
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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track1,
        track2,
      ], persist: false);
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

      final themeProvider = ThemeProvider(
        loadPersistedState: false,
        preferenceWriter: (_, _) async => true,
      );
      await tester.pumpWidget(
        fixture.build(
          PlaybackQueueAudioEditPage(sessionId: queueSession.id),
          themeProvider: themeProvider,
        ),
      );
      await tester.pumpAndSettle();

      Finder sectionCapsule(String title) => find.ancestor(
        of: find.text(fixture.languageProvider.tr(title)),
        matching: find.byType(HeaderFloatingSurface),
      );

      final pageHeader = find.byType(TopPageHeader);
      expect(tester.widget<TopPageHeader>(pageHeader).showFadeMask, isTrue);
      final titleBar = find.descendant(
        of: pageHeader,
        matching: find.byType(HeaderFloatingSurface),
      );
      final leftEdge = tester.getRect(titleBar.first).left;
      final rightEdge = tester.getRect(titleBar.last).right;
      final isWindows = defaultTargetPlatform == TargetPlatform.windows;
      final addedCapsule = sectionCapsule('queue_added_audio');
      final sourceCapsule = sectionCapsule('playback_sessions');
      Finder capsuleBlur(Finder capsule) => find.descendant(
        of: capsule,
        matching: find.byType(BackdropFilter),
      );
      expect(capsuleBlur(addedCapsule), findsNothing);
      expect(capsuleBlur(sourceCapsule), findsNothing);
      expect(
        tester.getRect(addedCapsule).left,
        leftEdge,
      );
      for (final capsule in [titleBar.first, titleBar.last, addedCapsule]) {
        final decoration = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: capsule,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is DecoratedBox &&
                      widget.decoration is BoxDecoration &&
                      (widget.decoration as BoxDecoration).border != null,
                ),
              )
              .first,
        ).decoration as BoxDecoration;
        expect(decoration.color?.a, greaterThan(0));
        expect((decoration.border! as Border).top.color.a, greaterThan(0));
      }
      TextStyle? headingStyle(String key) => tester
          .widget<Text>(find.text(fixture.languageProvider.tr(key)))
          .style;
      expect(headingStyle('edit_queue_audio')?.fontSize, 16);
      expect(headingStyle('queue_added_audio')?.fontSize, 13.5);
      expect(
        headingStyle('playback_sessions'),
        headingStyle('queue_added_audio'),
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: addedCapsule,
                matching: find.byIcon(Icons.playlist_play_rounded),
              ),
            )
            .size,
        17,
      );
      expect(
        tester.getSize(
          find.descendant(
            of: sectionCapsule('playback_sessions'),
            matching: find.byType(PlaylistIcon),
          ),
        ),
        const Size.square(17),
      );
      final sourceSectionLeft = isWindows
          ? tester.getRect(find.byType(VerticalDivider)).right + leftEdge
          : leftEdge;
      expect(
        tester.getRect(sectionCapsule('playback_sessions')).left,
        sourceSectionLeft,
      );
      final emptyQueue = find.text(
        fixture.languageProvider.tr('empty_playback_queue'),
      );
      final addedSectionRight = isWindows
          ? tester.getRect(find.byType(VerticalDivider)).left
          : tester.view.physicalSize.width;
      expect(tester.getCenter(emptyQueue).dx, addedSectionRight / 2);
      expect(find.byType(HeaderFloatingSurface), findsNWidgets(4));
      expect(find.byType(Divider), findsNothing);
      expect(
        find.byType(VerticalDivider),
        isWindows ? findsOneWidget : findsNothing,
      );
      final placeholders = find.byType(CoverFallbackArtwork);
      expect(placeholders, findsNWidgets(2));
      for (final placeholder in placeholders.evaluate()) {
        final cover = find.byElementPredicate(
          (element) => identical(element, placeholder),
        );
        final card = find
            .ancestor(of: cover, matching: find.byType(FileTreeRow))
            .first;
        expect(tester.getRect(card).left, sourceSectionLeft);
        expect(tester.getRect(card).right, rightEdge);
        final labels = find.descendant(of: card, matching: find.byType(Text));
        expect(tester.getSize(cover), const Size.square(40));
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
      final queuedCard = find.ancestor(
        of: find.byTooltip(fixture.languageProvider.tr('remove')),
        matching: find.byType(FileTreeRow),
      );
      expect(tester.getRect(queuedCard).left, leftEdge);
      final queuedSectionRight = isWindows
          ? tester.getRect(find.byType(VerticalDivider)).left - leftEdge
          : rightEdge;
      expect(tester.getRect(queuedCard).right, queuedSectionRight);
      expect(placeholders, findsNWidgets(3));
      final scrollableTargets = tester
          .elementList(find.byType(Scrollable))
          .map((element) => element.findRenderObject())
          .toSet();
      for (final title in ['queue_added_audio', 'playback_sessions']) {
        final header = find
            .ancestor(
              of: find.text(fixture.languageProvider.tr(title)),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Listener &&
                    widget.behavior == HitTestBehavior.opaque,
              ),
            )
            .first;
        final rect = tester.getRect(header);
        final target = tester.renderObject<RenderPointerListener>(header);
        final hitTargets = tester
            .hitTestOnBinding(Offset(rect.right - 2, rect.center.dy))
            .path
            .map((entry) => entry.target)
            .toSet();
        expect(hitTargets, contains(target));
        expect(hitTargets.intersection(scrollableTargets), isEmpty);
      }
      final sourceHitTargets = tester
          .hitTestOnBinding(tester.getCenter(addButtons.first))
          .path
          .map((entry) => entry.target)
          .toSet();
      expect(sourceHitTargets.intersection(scrollableTargets), isNotEmpty);
      final primary = Theme.of(
        tester.element(find.byType(PlaybackQueueAudioEditPage)),
      ).colorScheme.primary;
      for (final icon in tester.widgetList<AppBrandIcon>(
        find.byType(AppBrandIcon),
      )) {
        expect(icon.color, primary);
      }
      expect(await themeProvider.setBarGlassEnabled(true), isTrue);
      await tester.pumpAndSettle();
      for (final capsule in [addedCapsule, sourceCapsule]) {
        expect(
          tester.widget<BackdropFilter>(capsuleBlur(capsule)).enabled,
          isTrue,
        );
      }
      await tester.pump(const Duration(seconds: 10));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'queue editor switches between playlist and local library sources',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
          ? const Size(960, 600)
          : const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..syncSlice(isInitialized: true),
      );
      addTearDown(fixture.dispose);
      final playlistTrack = testMusicTrack(
        name: 'Playlist session track',
        path: '/playlist/session.mp3',
        groupKey: '/playlist',
        groupTitle: 'Playlist',
        isSingle: true,
      );
      final localTrack = testMusicTrack(
        name: 'Local work audio',
        path: '/library/Local work/Disc 1/audio.mp3',
        groupKey: '/library/Local work/Disc 1',
        groupTitle: 'Disc 1',
      );
      final localSingle = testMusicTrack(
        name: 'Standalone audio',
        path: '/library/single.mp3',
        groupKey: '/library',
        groupTitle: 'Library',
        isSingle: true,
      );
      await tester.runAsync(() async {
        fixture.library.addWatchedLibrary('/library');
        fixture.library.addTracks([localTrack, localSingle], persist: false);
        await fixture.library.ensureCardSnapshot();
      });
      final extraSources = List.generate(14, (index) {
        final track = testMusicTrack(
          name: 'Extra session $index',
          path: '/playlist/extra-$index.mp3',
          groupKey: '/playlist',
          groupTitle: 'Playlist',
          isSingle: true,
        );
        return fixture.playback.createTrackSession(
          track,
          customQueueTracks: [track],
        );
      });
      final source = fixture.playback.createTrackSession(
        playlistTrack,
        customQueueTracks: [playlistTrack],
      );
      final queue = fixture.playback.createPlaybackQueue('Queue');
      fixture.playbackService.syncSlice(
        activeSessions: [source, ...extraSources, queue],
        playingSessionCount: 0,
        focusedSessionId: source.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      final themeProvider = ThemeProvider(
        loadPersistedState: false,
        preferenceWriter: (_, _) async => true,
      );
      final frameKey = GlobalKey();
      await tester.pumpWidget(
        fixture.build(
          RepaintBoundary(
            key: frameKey,
            child: PlaybackQueueAudioEditPage(sessionId: queue.id),
          ),
          themeProvider: themeProvider,
        ),
      );
      await tester.pumpAndSettle();

      final i18n = fixture.languageProvider;
      final playlist = find.text(i18n.tr('playback_sessions'));
      final library = find.text(i18n.tr('show_local_library'));
      Finder capsule(Finder tab) => find.ancestor(
        of: tab,
        matching: find.byType(HeaderFloatingSurface),
      );
      Finder blur(Finder tab) => find.descendant(
        of: capsule(tab),
        matching: find.byType(BackdropFilter),
      );
      void expectSelectedTabBlur(Finder selected, Finder unselected) {
        final filter = blur(selected);
        expect(tester.widget<BackdropFilter>(filter).enabled, isTrue);
        expect(
          tester.layers,
          contains(tester.renderObject<RenderBackdropFilter>(filter).debugLayer),
        );
        expect(blur(unselected), findsNothing);
      }

      Finder row(String label) => find.byWidgetPredicate(
        (widget) => widget is FileTreeRow && widget.title == label,
      );
      expect(
        tester.getCenter(library).dx,
        greaterThan(tester.getCenter(playlist).dx),
      );
      expect(capsule(playlist), findsOneWidget);
      expect(capsule(library), findsNothing);
      expect(row(playlistTrack.displayName), findsOneWidget);
      expect(row('Local work'), findsNothing);
      expect(blur(playlist), findsNothing);
      expect(await themeProvider.setBarGlassEnabled(true), isTrue);
      await tester.pumpAndSettle();
      expectSelectedTabBlur(playlist, library);

      final sourceRow = row(playlistTrack.displayName);
      final sourceScroll = tester
          .state<ScrollableState>(
            find.ancestor(of: sourceRow, matching: find.byType(Scrollable)),
          )
          .position;
      final frame = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(frameKey),
      );
      Future<ByteData> captureFrame() async =>
          (await tester.runAsync(() async {
            final image = await frame.toImage();
            try {
              return (await image.toByteData())!;
            } finally {
              image.dispose();
            }
          }))!;
      final pill = tester.getRect(capsule(playlist));
      final cover = tester.getRect(
        find.descendant(
          of: sourceRow,
          matching: find.byType(CoverFallbackArtwork),
        ),
      );
      final beforeScroll = await captureFrame();
      sourceScroll.jumpTo(cover.center.dy - pill.center.dy);
      await tester.pumpAndSettle();
      final afterScroll = await captureFrame();
      final frameWidth = frame.size.width.toInt();
      final sample = frame.globalToLocal(Offset(cover.center.dx, pill.center.dy));
      var strongestChange = 0;
      for (var y = sample.dy.round() - 8; y <= sample.dy.round() + 8; y++) {
        for (var x = sample.dx.round() - 8; x <= sample.dx.round() + 8; x++) {
          final offset = (y * frameWidth + x) * 4;
          for (var channel = 0; channel < 3; channel++) {
            final change =
                (beforeScroll.getUint8(offset + channel) -
                        afterScroll.getUint8(offset + channel))
                    .abs();
            if (change > strongestChange) strongestChange = change;
          }
        }
      }
      expect(
        strongestChange,
        greaterThan(12),
        reason: 'Scrolling artwork must visibly affect pixels inside the glass.',
      );
      sourceScroll.jumpTo(0);
      await tester.pumpAndSettle();

      await tester.tap(library);
      await tester.pumpAndSettle();
      expect(capsule(library), findsOneWidget);
      expect(capsule(playlist), findsNothing);
      expectSelectedTabBlur(library, playlist);
      expect(row(playlistTrack.displayName), findsNothing);
      expect(row(localSingle.displayName), findsOneWidget);
      await tester.tap(row('Local work'));
      await tester.pumpAndSettle();
      await tester.tap(row('Disc 1'));
      await tester.pumpAndSettle();
      expect(row(localTrack.displayName), findsOneWidget);
      await tester.tap(find.byTooltip(i18n.tr('add_work_to_queue')));
      await tester.pumpAndSettle();
      final added = queue.playbackQueue!.entries.single;
      expect(
        PathMatcher.equalsNormalized(added.workRootPath!, '/library/Local work'),
        isTrue,
      );
      expect(added.tracks.single.path, localTrack.path);

      await tester.tap(playlist);
      await tester.pumpAndSettle();
      expect(capsule(playlist), findsOneWidget);
      expect(capsule(library), findsNothing);
      expectSelectedTabBlur(playlist, library);
      expect(row(playlistTrack.displayName), findsOneWidget);
      expect(row(localSingle.displayName), findsNothing);
      expect(queue.playbackQueue!.entries.single.id, added.id);
      expect(await themeProvider.setBarGlassEnabled(false), isTrue);
      await tester.pumpAndSettle();
      expect(blur(playlist), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'queue audio edit page switches work labels with the display setting',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
      );
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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
      ], persist: false);
      final library = fixture.runtimeGraph.library;
      library.addWatchedLibrary('/library', notify: false);
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
        fixture.build(
          PlaybackQueueAudioEditPage(sessionId: queueSession.id),
          overrides: [
            libraryDetailForTargetProvider.overrideWith(
              (_, target) => AudioDetail.empty(
                target,
              ).copyWith(workTitle: 'Saved work title'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Saved work title', findRichText: true), findsOneWidget);
      expect(find.text('Disc 1'), findsNothing);
      expect(find.text('Track 1', findRichText: true), findsOneWidget);

      // Both panes resolve the work folder label from the same setting.
      final addAudio = find.byTooltip(
        fixture.languageProvider.tr('add_work_to_queue'),
      );
      await tester.tap(addAudio);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.text('Saved work title', findRichText: true),
        findsNWidgets(2),
      );
      await fixture.settings.setWorkNameDisplay(WorkNameDisplay.folderName);
      await tester.pumpAndSettle();
      expect(find.text('RJ123456_Work', findRichText: true), findsNWidgets(2));
      expect(find.text('Saved work title', findRichText: true), findsNothing);
      expect(find.text('Disc 1'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'queue audio edit page uses thumbnail cache width and reuses retained covers',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1920, 1200)
          : const Size(780, 1688);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final interaction = UiInteractionCoordinator.instance;
      interaction.resetForTest();
      addTearDown(interaction.resetForTest);

      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('queue-editor-cover-reuse-'),
      ))!;
      final coverFile = File('${directory.path}/cover.png');
      await tester.runAsync(
        () => coverFile.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        ),
      );
      final expectedWidth = coverThumbnailCacheWidth(
        logicalWidth: 40,
        devicePixelRatio: 2,
        resolution: CoverImageResolution.balanced,
      );
      final provider = resizeFileImageIfNeeded(
        path: coverFile.path,
        cacheWidth: expectedWidth,
      );
      addTearDown(() async {
        releaseRetainedCoverImage(provider);
        await provider.evict();
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 5; attempt++) {
            try {
              if (await directory.exists()) {
                await directory.delete(recursive: true);
              }
              return;
            } on FileSystemException {
              if (attempt == 4) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        });
      });

      final coverCache = _RecordingPlaybackCoverCacheService(
        fixedCoverPath: coverFile.path,
      );
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: coverCache,
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..coverImageResolution = CoverImageResolution.balanced
          ..syncSlice(isInitialized: true),
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(fixture.build(const SizedBox.shrink()));
      final scaffoldContext = tester.element(find.byType(Scaffold));
      await tester.runAsync(() => precacheImage(provider, scaffoldContext));
      retainCoverImage(
        provider,
        createLocalImageConfiguration(scaffoldContext),
      );

      final track = testMusicTrack(
        name: 'Track 1',
        path: '${directory.path}/work/01.mp3',
        groupKey: '${directory.path}/work',
        groupTitle: 'Work',
      ).copyWith(manualCoverPath: coverFile.path);
      fixture.library.addTracks([track], persist: false);
      final sourceSession = fixture.playback.createTrackSession(
        track,
        customQueueTracks: [track],
      );
      final queueSession = fixture.playback.createPlaybackQueue('Queue');
      await fixture.playback.addWorkToPlaybackQueue(
        queueSession.id,
        title: 'Work',
        workRootPath: '${directory.path}/work',
        tracks: [track],
      );
      addTearDown(sourceSession.shutdown);
      addTearDown(queueSession.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: [sourceSession, queueSession],
        playingSessionCount: 0,
        focusedSessionId: queueSession.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      final navigation = Object();
      interaction.beginNavigation(navigation);
      await tester.pumpWidget(
        fixture.build(PlaybackQueueAudioEditPage(sessionId: queueSession.id)),
      );
      await tester.pump();

      final covers = tester.widgetList<QueueTrackCover>(
        find.byType(QueueTrackCover),
      );
      expect(covers, hasLength(2));
      for (final cover in covers) {
        expect(cover.coverCacheWidth, expectedWidth);
      }
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
      expect(decodedArtwork, findsNWidgets(2));

      interaction.endNavigation(navigation);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'queue audio edit page reuses unaffected row elements on expand, collapse and reorder',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
          ? const Size(960, 600)
          : const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..syncSlice(isInitialized: true),
      );
      addTearDown(fixture.dispose);

      fixture.library.addWatchedLibrary('/library');
      final workATrack = testMusicTrack(
        name: 'Track A',
        path: '/library/Work A/Disc 1/track_a.mp3',
        groupKey: '/library/Work A',
        groupTitle: 'Work A',
      );
      final workBTrack = testMusicTrack(
        name: 'Track B',
        path: '/library/Work B/track_b.mp3',
        groupKey: '/library/Work B',
        groupTitle: 'Work B',
      );
      final source1Track = testMusicTrack(
        name: 'Source Track 1',
        path: '/library/Source Work 1/Disc S1/source_1.mp3',
        groupKey: '/library/Source Work 1',
        groupTitle: 'Source Work 1',
      );
      final source2Track = testMusicTrack(
        name: 'Source Track 2',
        path: '/library/Source Work 2/source_2.mp3',
        groupKey: '/library/Source Work 2',
        groupTitle: 'Source Work 2',
      );
      fixture.library.addTracks([
        workATrack,
        workBTrack,
        source1Track,
        source2Track,
      ], persist: false);

      final source1 = fixture.playback.createTrackSession(
        source1Track,
        customQueueTracks: [source1Track],
      );
      final source2 = fixture.playback.createTrackSession(
        source2Track,
        customQueueTracks: [source2Track],
      );
      final queue = fixture.playback.createPlaybackQueue('Queue');
      await fixture.playback.addWorkToPlaybackQueue(
        queue.id,
        title: 'Work A',
        workRootPath: '/library/Work A',
        tracks: [workATrack],
      );
      await fixture.playback.addWorkToPlaybackQueue(
        queue.id,
        title: 'Work B',
        workRootPath: '/library/Work B',
        tracks: [workBTrack],
      );
      addTearDown(source1.shutdown);
      addTearDown(source2.shutdown);
      addTearDown(queue.shutdown);

      fixture.playbackService.syncSlice(
        activeSessions: [source1, source2, queue],
        playingSessionCount: 0,
        focusedSessionId: queue.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        fixture.build(PlaybackQueueAudioEditPage(sessionId: queue.id)),
      );
      await tester.pumpAndSettle();

      final entries = queue.playbackQueue!.entries;
      final entryAId = entries[0].id;
      final entryBId = entries[1].id;

      Element rowElementForKey(String key) => find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(FileTreeRow),
          )
          .evaluate()
          .single;

      Element rowElementForChildText(Finder rootScope, String title) => find
          .descendant(
            of: rootScope,
            matching: find.byWidgetPredicate(
              (widget) => widget is FileTreeRow && widget.title == title,
            ),
          )
          .evaluate()
          .single;

      final addedList = find.byType(ReorderableListView);
      final sourceList = find
          .ancestor(
            of: find.byKey(ValueKey(source1.id)),
            matching: find.byType(ListView),
          )
          .first;

      final entryAElement = rowElementForKey(entryAId);
      final entryBElement = rowElementForKey(entryBId);
      final source2Element = rowElementForKey(source2.id);

      // Expand Work A in left pane: Disc 1 stays mounted through settle, and
      // Work B + right pane rows keep their exact Element instances.
      await tester.tap(find.byKey(ValueKey(entryAId)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final disc1ElementMid = rowElementForChildText(addedList, 'Disc 1');
      expect(identical(rowElementForKey(entryBId), entryBElement), isTrue);
      expect(identical(rowElementForKey(source2.id), source2Element), isTrue);

      await tester.pumpAndSettle();
      expect(
        identical(rowElementForChildText(addedList, 'Disc 1'), disc1ElementMid),
        isTrue,
      );
      expect(identical(rowElementForKey(entryBId), entryBElement), isTrue);

      // Collapse Work A: Disc 1 keeps its Element when collapse starts, and
      // Work B keeps its Element when indices shift back.
      await tester.tap(find.byKey(ValueKey(entryAId)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        identical(rowElementForChildText(addedList, 'Disc 1'), disc1ElementMid),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(identical(rowElementForKey(entryBId), entryBElement), isTrue);

      // Expand Source 1 in right pane: findChildIndexCallback keeps Source 2's
      // Element intact while left pane remains unaffected.
      await tester.tap(find.byKey(ValueKey(source1.id)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final sourceDisc1Mid = rowElementForChildText(sourceList, 'Disc S1');
      expect(identical(rowElementForKey(source2.id), source2Element), isTrue);
      expect(identical(rowElementForKey(entryBId), entryBElement), isTrue);

      await tester.pumpAndSettle();
      expect(
        identical(
          rowElementForChildText(sourceList, 'Disc S1'),
          sourceDisc1Mid,
        ),
        isTrue,
      );
      expect(identical(rowElementForKey(source2.id), source2Element), isTrue);
      expect(identical(rowElementForKey(entryBId), entryBElement), isTrue);

      // Drag Work B above Work A: both rows keep their Element instances.
      final target =
          tester.getCenter(find.byKey(ValueKey(entryAId))) +
          const Offset(0, 12);
      final drag = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey(entryBId))),
      );
      await tester.pump(kLongPressTimeout);
      await drag.moveBy(const Offset(0, -22));
      await tester.pump();
      await drag.moveTo(target);
      await tester.pump(const Duration(milliseconds: 250));
      await drag.up();
      await tester.pumpAndSettle();

      expect(queue.playbackQueue!.entries.map((entry) => entry.id), [
        entryBId,
        entryAId,
      ]);
      expect(identical(rowElementForKey(entryAId), entryAElement), isTrue);
      expect(identical(rowElementForKey(entryBId), entryBElement), isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'queue audio edit page upper list reuses cached library tree lazily for nested removals',
    (tester) async {
      final disc1Track = testMusicTrack(
        name: 'Disc 1 Track',
        path: '/library/Work/Disc 1/01.mp3',
        groupKey: '/library/Work',
        groupTitle: 'Work',
      );
      final disc2Track = testMusicTrack(
        name: 'Disc 2 Track',
        path: '/library/Work/Disc 2/02.mp3',
        groupKey: '/library/Work',
        groupTitle: 'Work',
      );
      final rootFolder = FolderNode('Work', '/library/Work', depth: 1);
      final disc1 = FolderNode('Disc 1', '/library/Work/Disc 1', depth: 2)
        ..addChild(TrackNode(disc1Track));
      final disc2 = FolderNode('Disc 2', '/library/Work/Disc 2', depth: 2)
        ..addChild(TrackNode(disc2Track));
      rootFolder
        ..addChild(disc1)
        ..addChild(disc2);

      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
        libraryTreeSnapshotBuilder: (_) async => LibraryTreeSnapshot(
          tree: [rootFolder],
          leafFolderCount: 2,
        ),
        configureSettingsRepository: (settings) => settings
          ..workNameDisplay = WorkNameDisplay.folderName
          ..syncSlice(isInitialized: true),
      );
      addTearDown(fixture.dispose);

      await tester.runAsync(() async {
        fixture.library.addWatchedLibrary('/library');
        fixture.library.addTracks([disc1Track, disc2Track], persist: false);
        await fixture.library.ensureCardSnapshot();
        await fixture.library.loadLibraryFolderTree('/library/Work');
      });

      final queue = fixture.playback.createPlaybackQueue('Queue');
      await fixture.playback.addWorkToPlaybackQueue(
        queue.id,
        title: 'Work',
        workRootPath: '/library/Work',
        tracks: [disc1Track, disc2Track],
      );
      addTearDown(queue.shutdown);

      fixture.playbackService.syncSlice(
        activeSessions: [queue],
        playingSessionCount: 0,
        focusedSessionId: queue.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(
        fixture.build(PlaybackQueueAudioEditPage(sessionId: queue.id)),
      );
      await tester.pumpAndSettle();

      final list = find.byType(ReorderableListView);
      final entryId = queue.playbackQueue!.entries.single.id;
      await tester.tap(find.byKey(ValueKey(entryId)));
      await tester.pumpAndSettle();

      // Nested tracks stay unmounted while subfolders are collapsed, then
      // expanding Disc 2 reveals only Disc 2 Track.
      expect(
        find.descendant(of: list, matching: find.text('Disc 1 Track')),
        findsNothing,
      );
      expect(
        find.descendant(of: list, matching: find.text('Disc 2 Track')),
        findsNothing,
      );
      await tester.tap(find.descendant(of: list, matching: find.text('Disc 2')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: list, matching: find.text('Disc 2 Track')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: list, matching: find.text('Disc 1 Track')),
        findsNothing,
      );

      // Removing unpopulated Disc 1 computes its exact index even after Disc 2
      // was opened first.
      final disc1Row = find.ancestor(
        of: find.descendant(of: list, matching: find.text('Disc 1')),
        matching: find.byType(FileTreeRow),
      );
      await tester.tap(
        find.descendant(of: disc1Row, matching: find.byType(IconButton)),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      expect(
        queue.playbackQueue!.entries.single.tracks.map((track) => track.path),
        [disc2Track.path],
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
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
      find.text(fixture.languageProvider.tr('turn_on_subtitle')),
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
      find.text(fixture.languageProvider.tr('turn_on_subtitle')),
      findsOneWidget,
    );
    expect(
      find.text(fixture.languageProvider.tr('subtitle_global_display')),
      findsOneWidget,
    );
    await tester.tap(
      find.text(fixture.languageProvider.tr('turn_on_subtitle')),
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
    fixture.runtimeGraph.library.addTracks(<MusicTrack>[track], persist: false);
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
    final visualCard = tester.widget<Material>(
      find
          .ancestor(
            of: find.byKey(
              ValueKey<String>('playlist_card_content_${session.id}'),
            ),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(visualCard.clipBehavior, Clip.none);
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

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Windows playlist context menu pins item to top and unpins it',
    (tester) async {
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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        trackA,
        trackB,
      ], persist: false);
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

      final cardB = find.ancestor(
        of: find.text('Work B'),
        matching: find.byType(SwipeRevealCard),
      );
      Future<void> openMenu() => tester.tap(
        cardB,
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await openMenu();
      await tester.pumpAndSettle();
      final pinButtonFinder = find.text(
        fixture.languageProvider.tr('pin_to_top'),
      );
      expect(pinButtonFinder, findsOneWidget);
      final pinIconFinder = find.descendant(
        of: find
            .ancestor(of: pinButtonFinder, matching: find.byType(InkWell))
            .first,
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

      await openMenu();
      await tester.pumpAndSettle();
      final unpinButtonFinder = find.text(
        fixture.languageProvider.tr('unpin_from_top'),
      );
      final unpinMenuRow = find
          .ancestor(of: unpinButtonFinder, matching: find.byType(InkWell))
          .first;
      expect(unpinButtonFinder, findsOneWidget);
      expect(
        find.descendant(
          of: unpinMenuRow,
          matching: find.byIcon(Icons.vertical_align_bottom_rounded),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: unpinMenuRow, matching: find.byType(CustomPaint)),
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
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

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
              colorValue: 0xFFFFFFFF,
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
      final pinScheme = Theme.of(tester.element(pinQueueFinder)).colorScheme;
      final pinDecoration =
          tester.widget<Container>(pinQueueFinder).decoration! as BoxDecoration;
      expect(pinDecoration.color, pinScheme.primary);
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: pinQueueFinder,
                matching: find.byIcon(Icons.push_pin_rounded),
              ),
            )
            .color,
        pinScheme.onPrimary,
      );
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
      expect(
        tester.getSize(placeholderCover),
        Size.square(coverProgressInnerDimension(playlistCoverSize)),
      );
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
      expect(
        tester.getSize(cover),
        Size.square(coverProgressInnerDimension(playlistCoverSize)),
      );
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

  testWidgets('PlaylistSelectionIndicator enters quickly and fades out in 300ms', (
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

    await tester.pump();
    expect(checkmarkFinder, findsOneWidget);

    await tester.pump(kAppMotionFast ~/ 2);
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

    await tester.pump(kAppMotionFast ~/ 2);
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

    // Mid reverse-animation: checkmark is still present and fading out
    await tester.pump();
    await tester.pump(kAppFadeDuration ~/ 2);
    expect(checkmarkFinder, findsOneWidget);
    final fadeOutOpacity = tester
        .widget<FadeTransition>(fadeTransitionFinder)
        .opacity
        .value;
    expect(fadeOutOpacity, greaterThan(0.0));
    expect(fadeOutOpacity, lessThan(1.0));

    // After remaining reverse duration, checkmark finishes fading out and is removed
    await tester.pump(kAppFadeDuration ~/ 2 + const Duration(milliseconds: 25));
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
    expect(checkmarkFinder, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(fadeTransitionFinder).opacity.value,
      1,
    );
  });

  testWidgets(
    'playlist cards switch from loading spinners to static retry icons',
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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
      ], persist: false);
      final trackSession =
          fixture.runtimeGraph.playback.createTrackSession(track)
            ..state = const PlayerState(false, ProcessingState.buffering)
            ..beginPreparation(showLoading: true, autoPlay: false);
      final queueSession =
          fixture.runtimeGraph.playback.createPlaybackQueue('Loading queue')
            ..state = const PlayerState(false, ProcessingState.buffering)
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
            ..beginPreparation(showLoading: true, autoPlay: false);
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

      for (final session in [trackSession, queueSession]) {
        session.finishPreparation(
          session.loadGeneration,
          prepared: false,
          autoPlay: false,
          error: 'playback failed',
        );
        session.setOptimisticState(processingState: ProcessingState.idle);
        fixture.playback.publishSessionState(session.id);
      }
      await pumpFiniteTransitions(tester);
      expect(find.byKey(const ValueKey('loading')), findsNothing);
      expect(find.byKey(const ValueKey('retry')), findsNWidgets(2));

      for (final session in [trackSession, queueSession]) {
        session.beginTransportCommand(commandId: 1, playing: false);
        session.setOptimisticState(processingState: ProcessingState.ready);
        fixture.playback.publishSessionState(session.id);
      }
      await pumpFiniteTransitions(tester);
      expect(find.byKey(const ValueKey('loading')), findsNothing);
      expect(find.byKey(const ValueKey('retry')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'failed playlist item keeps a clickable retry icon without inline text',
    (tester) async {
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
      fixture.library.addTracks([track], persist: false);
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
      await pumpFiniteTransitions(tester);
      expect(
        find.byKey(ValueKey<String>('playlist_card_content_${session.id}')),
        findsOneWidget,
      );
      expect(
        find.byTooltip(fixture.languageProvider.tr('retry_playback')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('loading')), findsNothing);
      expect(find.byKey(const ValueKey('retry')), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byKey(const ValueKey('retry')),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        find.text(fixture.languageProvider.tr('playback_failed_retry')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'detail and carousel switch from loading spinners to static retry icons',
    (tester) async {
      final harness = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
        physicalSize: defaultTargetPlatform == TargetPlatform.windows
            ? const Size(3840, 2400)
            : const Size(1080, 2400),
      );
      final session = harness.session;
      final fixture = harness.fixture;

      for (final carousel in [false, true]) {
        if (carousel) {
          await tester.pumpWidget(const SizedBox.shrink());
          await pumpFiniteTransitions(tester);
          await tester.pumpWidget(
            fixture.build(
              ActiveSessionCarousel(
                sessions: [PlaybackSessionSnapshot.fromRuntime(session)],
                onOpenSession: (_, _) {},
              ),
            ),
          );
          await pumpFiniteTransitions(tester);
        }
        final controls = carousel
            ? find.byType(ActiveSessionCarousel)
            : find.byType(PrimaryPlaybackControls);
        final spinner = find.descendant(
          of: controls,
          matching: find.byKey(const ValueKey('loading')),
        );
        final retry = find.descendant(
          of: controls,
          matching: find.byKey(const ValueKey('retry')),
        );
        expect(spinner, findsNothing);

        session.setOptimisticState(processingState: ProcessingState.loading);
        fixture.playback.publishSessionState(session.id);
        await pumpFiniteTransitions(tester);
        expect(spinner, findsNWidgets(carousel ? 3 : 1));
        expect(retry, findsNothing);

        session.finishPreparation(
          session.loadGeneration,
          prepared: false,
          autoPlay: false,
          error: 'playback failed',
        );
        session.setOptimisticState(processingState: ProcessingState.idle);
        fixture.playback.publishSessionState(session.id);
        await pumpFiniteTransitions(tester);
        expect(spinner, findsNothing);
        expect(retry, findsNWidgets(carousel ? 3 : 1));

        session.beginTransportCommand(
          commandId: session.transportCommandId + 1,
          playing: false,
        );
        session.setOptimisticState(processingState: ProcessingState.ready);
        fixture.playback.publishSessionState(session.id);
        await pumpFiniteTransitions(tester);
        expect(spinner, findsNothing);
        expect(retry, findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('playlist thumbnail updates for DPI and detail keeps quality', (
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
    fixture.runtimeGraph.library.addTracks([track], persist: false);
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
    final card = tester.widget<AsyncLocalCoverImage>(
      find.byType(AsyncLocalCoverImage).first,
    );
    expect(card.cacheWidth, 64);
    final cardKey = await imageKey(card);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1000, 2000);
    await tester.pump();
    final resizedCard = tester.widget<AsyncLocalCoverImage>(
      find.byType(AsyncLocalCoverImage).first,
    );
    expect(resizedCard.cacheWidth, 128);
    expect(await imageKey(resizedCard), isNot(cardKey));
    unawaited(
      Navigator.of(
        tester.element(find.byType(PlaylistTab)),
      ).push(buildSessionDetailRoute(sessionId: session.id)),
    );
    await tester.pumpAndSettle();
    final detailArtwork = find.descendant(
      of: find.byType(SessionHeroArtwork),
      matching: find.byType(AsyncLocalCoverImage),
    );
    final detailKey = await imageKey(
      tester.widget<AsyncLocalCoverImage>(detailArtwork),
    );
    expect(detailKey, isNot(cardKey));
    expect(tester.widget<AsyncLocalCoverImage>(detailArtwork).cacheWidth, 600);
    Navigator.of(tester.element(find.byType(SessionDetailPage))).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      fixture.build(
        ActiveSessionCarousel(
          sessions: [PlaybackSessionSnapshot.fromRuntime(session)],
          onOpenSession: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final carouselCover = tester.widget<AsyncLocalCoverImage>(
      find.byType(AsyncLocalCoverImage).first,
    );
    expect(await imageKey(carouselCover), await imageKey(resizedCard));
    await tester.runAsync(
      () => fixture.persistenceRepository.loadTimeSegmentLabels(
        TimeSegmentLabel.trackKeyFor(track),
      ),
    );
    await tester.runAsync(
      fixture.library.detailCacheService.waitForPendingOperations,
    );
    await tester.pump();
  });

  testWidgets(
    'video detail retains its surface through real pause commands',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
        providedNativePlaybackRepository: NativePlaybackRepository(
          bridge: NativePlaybackBridge.instance,
        ),
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
      fixture.runtimeGraph.library.addTracks(tracks, persist: false);
      final session =
          fixture.runtimeGraph.playback.createTrackSession(tracks[0])
            ..isTemporary = true
            ..setOptimisticState(playing: true);
      var pauseCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            if (call.method != NativePlaybackMethod.pause &&
                call.method != NativePlaybackMethod.play) {
              return <String, Object?>{'ok': true, 'value': null};
            }
            if (call.method == NativePlaybackMethod.pause) pauseCount++;
            final playing = call.method == NativePlaybackMethod.play;
            return <String, Object?>{
              'ok': true,
              'value': {
                'sessionId': session.id,
                'path': session.currentTrackPath,
                'playing': playing,
                'playWhenReady': playing,
                'processingState': 'ready',
                'positionMs': 12000,
                'transportCommandId':
                    (call.arguments as Map)['transportCommandId'],
              },
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, null);
      });
      void sync() => fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      sync();
      await tester.pumpWidget(
        fixture.build(
          const PlaylistTab(),
          overrides: [
            appOrientationControllerProvider.overrideWithValue(
              AppOrientationController(
                setPreferredOrientations: (_) async {},
                setSystemUiMode: (_) async {},
              ),
            ),
          ],
        ),
      );
      await pumpUntilFound(tester, find.byType(SessionListCard));
      await tester.pump(kAppMotionFast);
      await tester.pump();
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

      final surfaceBeforePause = tester.element(
        find.byType(NativeSessionVideoSurface),
      );
      final pauseButton = find.byTooltip(fixture.languageProvider.tr('pause'));
      final pausePress = await tester.startGesture(
        tester.getCenter(pauseButton),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await pausePress.up();
      await tester.pumpAndSettle();
      expect(pauseCount, 1);
      expect(session.playbackRequested, false);
      expect(session.position, const Duration(seconds: 12));
      expect(videoReady(), isTrue);
      expect(
        tester.element(find.byType(NativeSessionVideoSurface)),
        same(surfaceBeforePause),
      );
      await tester.tap(find.byTooltip(fixture.languageProvider.tr('play')));
      await tester.pumpAndSettle();
      expect(session.playbackRequested, true);
      expect(videoReady(), isTrue);
      expect(
        tester.element(find.byType(NativeSessionVideoSurface)),
        same(surfaceBeforePause),
      );

      session.currentTrackPath = tracks[1].path;
      sync();
      await tester.pumpAndSettle();
      expect(videoReady(), isFalse);
      session.loadedPath = tracks[1].path;
      sync();
      await tester.pumpAndSettle();
      expect(videoReady(), isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('session_video_tap_target')),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      final fullscreenPage = find.byType(SessionVideoFullscreenPage);
      await pumpUntilFound(tester, fullscreenPage);
      await tester.pump(const Duration(milliseconds: 100));
      final routeFade = find
          .ancestor(
            of: fullscreenPage,
            matching: find.byWidgetPredicate(
              (widget) => widget is FadeTransition,
            ),
          )
          .first;
      expect(
        tester.widget<FadeTransition>(routeFade).opacity.value,
        inExclusiveRange(0, 1),
      );
      final openingBounds = tester.getRect(fullscreenPage);
      await tester.pumpAndSettle();
      expect(tester.getRect(fullscreenPage), openingBounds);
      expect(
        find.byType(NativeSessionVideoSurface, skipOffstage: false),
        findsOneWidget,
      );
      final fullscreenSurface = tester.element(
        find.byType(NativeSessionVideoSurface),
      );
      await tester.tap(
        find.byKey(const ValueKey('fullscreen_video_play_pause')),
      );
      await tester.pumpAndSettle();
      expect(pauseCount, 2);
      expect(session.playbackRequested, false);
      expect(
        tester.element(find.byType(NativeSessionVideoSurface)),
        same(fullscreenSurface),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('fullscreen_video_exit')),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.widget<FadeTransition>(routeFade).opacity.value,
        inExclusiveRange(0, 1),
      );
      expect(tester.getRect(fullscreenPage), openingBounds);
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'keyboard reveals fullscreen video controls and holds them while focused',
    (tester) async {
      final orientation = AppOrientationController(
        setPreferredOrientations: (_) async {},
        setSystemUiMode: (_) async {},
      );
      final lease = await orientation.enterVideoFullscreen();
      addTearDown(lease.release);
      final track = testMusicTrack(
        name: 'Video',
        path: '/videos/keyboard.mp4',
        groupKey: '/videos',
        groupTitle: 'Videos',
      ).copyWith(isVideo: true);
      final setup = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
        queueTracks: [track],
        physicalSize: const Size(2400, 1080),
        detailBuilder: (session) => TooltipVisibility(
          visible: defaultTargetPlatform != TargetPlatform.windows,
          child: SessionVideoFullscreenPage(
            sessionId: session.id,
            trackPath: track.path,
            fullscreenLease: lease,
          ),
        ),
      );
      final controls = find.byKey(
        const ValueKey<String>('fullscreen_video_controls'),
      );
      final exitLabel = setup.fixture.languageProvider.tr('exit_fullscreen');
      final exitSemantics = find.semantics.byPredicate(
        (node) =>
            node.label == exitLabel ||
            node.getSemanticsData().tooltip == exitLabel,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
      expect(exitSemantics, findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);
      expect(exitSemantics, findsOne);

      await tester.pump(const Duration(seconds: 4));
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
      expect(exitSemantics, findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'fullscreen sliders preview pointer values without rebuilding video on ${platform.name}',
      (tester) async {
        final orientation = AppOrientationController(
          setPreferredOrientations: (_) async {},
          setSystemUiMode: (_) async {},
        );
        final lease = await orientation.enterVideoFullscreen();
        addTearDown(lease.release);
        final track = testMusicTrack(
          name: 'Video',
          path: '/videos/progress.mp4',
          groupKey: '/videos',
          groupTitle: 'Videos',
        ).copyWith(isVideo: true);
        final setup = await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: const Duration(seconds: 10),
          queueTracks: [track],
          physicalSize: const Size(2400, 1080),
          nativePlaybackRepository: NativePlaybackRepository(
            bridge: NativePlaybackBridge.instance,
          ),
          detailBuilder: (session) => SessionVideoFullscreenPage(
            sessionId: session.id,
            trackPath: track.path,
            fullscreenLease: lease,
          ),
        );
        var adjacencyQueries = 0;
        final commands = setup.fixture.runtimeGraph.playbackCommands;
        setup.fixture.playback.detachCommandPort();
        setup.fixture.playback.attachPlaybackCommands(
          prepareSession: commands.prepareSession,
          pauseSession: (session) async {
            await commands.pauseSession(session);
          },
          startSession: commands.startSession,
          resolveAdvance: commands.resolveAdvance,
          hasAdjacent: (session, {required forward}) {
            adjacencyQueries++;
            return commands.hasAdjacent(session, forward: forward);
          },
        );
        final session = setup.session
          ..loadedPath = track.path
          ..setOptimisticDuration(const Duration(minutes: 2))
          ..setOptimisticState(playing: true);
        setup.fixture.playbackService.syncSlice(
          activeSessions: [session],
          playingSessionCount: 1,
          focusedSessionId: session.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        await tester.pumpAndSettle();

        final exit = find.byKey(const ValueKey('fullscreen_video_exit'));
        final viewport = tester.getRect(find.byType(SessionVideoFullscreenPage));
        expect(
          tester.getCenter(exit),
          viewport.topRight +
              Offset(
                -AppPageHeaderMetrics.padding.right -
                    AppPageHeaderMetrics.buttonSize / 2,
                AppPageHeaderMetrics.padding.top +
                    AppPageHeaderMetrics.buttonSize / 2,
              ),
        );
        expect(tester.getSize(exit), const Size.square(48));
        final exitIcon = find.descendant(
          of: exit,
          matching: find.byIcon(Icons.fullscreen_exit_rounded),
        );
        expect(exitIcon, findsOneWidget);
        expect(IconTheme.of(tester.element(exitIcon)).size, 32);
        expect(
          find.descendant(
            of: exit,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is RichText &&
                  widget.text.style?.foreground?.style ==
                      ui.PaintingStyle.stroke,
            ),
          ),
          findsNothing,
        );

        final progress = find.descendant(
          of: find.byKey(const ValueKey('fullscreen_video_progress')),
          matching: find.byType(Slider),
        );
        final controls = find.byKey(
          const ValueKey<String>('fullscreen_video_controls'),
        );
        final video = tester.widget<NativeSessionVideoSurface>(
          find.byType(NativeSessionVideoSurface),
        );
        final videoState = tester.state(find.byType(NativeSessionVideoSurface));
        final cover = tester.widget<AsyncLocalCoverImage>(
          find.byType(AsyncLocalCoverImage),
        );
        final initialAdjacencyQueries = adjacencyQueries;
        expect(tester.widget<Slider>(progress).value, 10000);
        final times = find.descendant(
          of: find.byKey(const ValueKey('fullscreen_video_progress')),
          matching: find.byType(TimecodeLabel),
        );
        final sliderRect = tester.getRect(progress);
        expect(tester.getRect(times.first).right, lessThan(sliderRect.left));
        expect(tester.getRect(times.last).left, greaterThan(sliderRect.right));
        final pointer = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await pointer.addPointer(location: Offset.zero);
        final volume = find.byKey(const ValueKey('session_volume_slider'));
        final percentButton = find.byKey(
          const ValueKey('session_volume_percent_text'),
        );
        final volumeLabel = find.descendant(
          of: percentButton,
          matching: find.byType(Text),
        );
        final volumeRect = tester.getRect(volume);
        const volumeInset = sessionDetailVolumeTrackInset;
        expect(tester.widget<Text>(volumeLabel).data, '100%');
        for (final (fraction, percent) in [(.2, '30%'), (.8, '120%')]) {
          await pointer.moveTo(
            Offset(
              volumeRect.left +
                  volumeInset +
                  (volumeRect.width - 2 * volumeInset) * fraction,
              volumeRect.center.dy,
            ),
          );
          await tester.pump();
          expect(tester.widget<Text>(volumeLabel).data, percent);
          expect(tester.widget<Slider>(volume).value, 1);
          expect(session.volume, 1);
        }
        final trackLeft = sliderRect.left + 12;
        final trackWidth = sliderRect.width - 24;
        await pointer.moveTo(
          Offset(trackLeft + trackWidth * .25, sliderRect.center.dy),
        );
        await tester.pump();
        expect(tester.widget<Text>(volumeLabel).data, '100%');
        expect(tester.widget<TimecodeLabel>(times.first).text, '00:30');
        expect(tester.widget<TimecodeLabel>(times.last).text, '-01:30');
        expect(tester.widget<Slider>(progress).value, 10000);
        await pointer.moveTo(
          Offset(trackLeft + trackWidth * .75, sliderRect.center.dy),
        );
        await tester.pump();
        expect(tester.widget<TimecodeLabel>(times.first).text, '01:30');
        expect(tester.getRect(progress), sliderRect);
        await pointer.down(
          Offset(trackLeft + trackWidth * .75, sliderRect.center.dy),
        );
        await pointer.up();
        await tester.pump();
        expect(session.position, const Duration(seconds: 90));
        await pointer.removePointer();
        session.setOptimisticPosition(const Duration(seconds: 10));
        await tester.pump(const Duration(milliseconds: 100));
        tester.widget<Slider>(progress).onChangeStart!(10000);
        for (final value in [30000.0, 45000.0]) {
          tester.widget<Slider>(progress).onChanged!(value);
          await tester.pump();
          expect(tester.widget<Slider>(progress).value, value);
          expect(
            tester.widget<NativeSessionVideoSurface>(
              find.byType(NativeSessionVideoSurface),
            ),
            same(video),
          );
          expect(
            tester.widget<AsyncLocalCoverImage>(
              find.byType(AsyncLocalCoverImage),
            ),
            same(cover),
          );
          expect(session.position, const Duration(seconds: 10));
        }
        await tester.pump(const Duration(seconds: 4));
        expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);

        tester.widget<Slider>(progress).onChangeEnd!(45000);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(session.position, const Duration(seconds: 45));
        expect(tester.widget<Slider>(progress).value, 45000);
        final previous = find.byKey(
          const ValueKey<String>('fullscreen_video_previous'),
        );
        session.setOptimisticPosition(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(
          tester.widget<PrimaryTransportButton>(previous).enabled,
          isFalse,
        );
        session.setOptimisticPosition(const Duration(seconds: 46));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.widget<Slider>(progress).value, 46000);
        expect(tester.widget<PrimaryTransportButton>(previous).enabled, isTrue);
        expect(adjacencyQueries, initialAdjacencyQueries);
        final next = find.byKey(
          const ValueKey<String>('fullscreen_video_next'),
        );
        expect(tester.widget<PrimaryTransportButton>(next).enabled, isFalse);
        final nextTrack = testMusicTrack(
          name: 'Next video',
          path: '/videos/next.mp4',
          groupKey: '/videos',
          groupTitle: 'Videos',
        ).copyWith(isVideo: true);
        session.playbackQueue = session.playbackQueue!.copyWith(
          entries: [
            ...session.playbackQueue!.entries,
            PlaybackQueueEntry(
              id: 'next-video',
              kind: PlaybackQueueEntryKind.track,
              title: 'Next video',
              tracks: [nextTrack],
            ),
          ],
        );
        session.customQueueTracks = session.playbackQueue!.expandedTracks;
        setup.fixture.playback.publishSessionState(session.id);
        await tester.pumpAndSettle();
        expect(tester.widget<PrimaryTransportButton>(next).enabled, isTrue);
        expect(adjacencyQueries, greaterThan(initialAdjacencyQueries));
        tester.view.physicalSize = const Size(1080, 2400);
        await tester.pump();
        expect(
          tester.state(find.byType(NativeSessionVideoSurface)),
          same(videoState),
        );
        final rotatedVideo = tester.widget<NativeSessionVideoSurface>(
          find.byType(NativeSessionVideoSurface),
        );
        tester.widget<Slider>(progress).onChangeStart!(46000);
        tester.widget<Slider>(progress).onChanged!(60000);
        await tester.pump();
        expect(
          tester.state(find.byType(NativeSessionVideoSurface)),
          same(videoState),
        );
        expect(
          tester.widget<NativeSessionVideoSurface>(
            find.byType(NativeSessionVideoSurface),
          ),
          same(rotatedVideo),
        );
        tester.widget<Slider>(progress).onChangeEnd!(60000);
        await tester.pump(const Duration(seconds: 3));
        expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
        await tester.pump(kAppFadeDuration);
        final hiddenProgress = tester.widget<Slider>(progress);
        session.setOptimisticPosition(const Duration(seconds: 75));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(tester.widget<Slider>(progress), same(hiddenProgress));
        await tester.tap(
          find.byKey(const ValueKey('fullscreen_video_gesture_surface')),
        );
        await tester.pump(kDoubleTapTimeout);
        expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);
        expect(tester.widget<Slider>(progress).value, 75000);
        await tester.pump(const Duration(seconds: 2));
        session.setOptimisticState(playing: false);
        setup.fixture.playback.publishSessionState(session.id);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1100));
        expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);

        await tester.tap(
          find.byKey(const ValueKey('fullscreen_video_gesture_surface')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SessionVolumeControls), findsOneWidget);
        expect(find.byType(PlaybackSecondaryControlSurface), findsOneWidget);
        expect(
          find.byKey(const ValueKey('session_volume_exit_button')),
          findsNothing,
        );
        await tester.tap(percentButton);
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('session_volume_input'));
        await tester.pump(const Duration(seconds: 4));
        expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);
        await tester.enterText(input, '75');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(input, findsNothing);
        expect(session.volume, 0.75);
        expect(tester.widget<Text>(volumeLabel).data, '75%');

        final muteButton = find.byKey(
          const ValueKey('session_volume_mute_button'),
        );
        await tester.tap(muteButton);
        await tester.pumpAndSettle();
        expect(session.volume, 0);
        await tester.tap(muteButton);
        await tester.pumpAndSettle();
        expect(session.volume, 0.75);

        final gestureBounds = tester.getRect(
          find.byKey(const ValueKey('fullscreen_video_gesture_surface')),
        );
        await tester.dragFrom(
          Offset(gestureBounds.right - 24, gestureBounds.center.dy),
          const Offset(0, -80),
        );
        await tester.pumpAndSettle();
        expect(session.volume, inExclusiveRange(0.75, 1.0));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    final sizes = platform == TargetPlatform.android
        ? const [
            Size(320, 640),
            Size(390, 844),
            Size(640, 320),
            Size(800, 1280),
          ]
        : const [Size(960, 600), Size(1280, 800)];
    for (final size in sizes) {
      testWidgets(
        'fullscreen video controls fit safe bounds at $size on ${platform.name}',
        (tester) async {
          final orientation = AppOrientationController(
            setPreferredOrientations: (_) async {},
            setSystemUiMode: (_) async {},
          );
          final lease = await orientation.enterVideoFullscreen();
          addTearDown(lease.release);
          final track = testMusicTrack(
            name: 'Long video',
            path: '/videos/long-layout.mp4',
            groupKey: '/videos',
            groupTitle: 'Videos',
          ).copyWith(isVideo: true);
          final sidePadding =
              platform == TargetPlatform.android && size.width > size.height
              ? 44.0
              : 20.0;
          final padding = EdgeInsets.fromLTRB(sidePadding, 20, sidePadding, 34);
          final capture = GlobalKey();
          final setup = await _pumpSubtitleDetail(
            tester: tester,
            subtitleTrack: SubtitleTrack(
              sourcePath: 'empty.srt',
              cues: const [],
            ),
            initialPosition: const Duration(
              hours: 12,
              minutes: 34,
              seconds: 56,
            ),
            queueTracks: [track],
            physicalSize: size * 3,
            detailBuilder: (session) => Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: padding,
                  viewPadding: padding,
                  textScaler: const TextScaler.linear(1.5),
                ),
                child: RepaintBoundary(
                  key: capture,
                  child: SessionVideoFullscreenPage(
                    sessionId: session.id,
                    trackPath: track.path,
                    fullscreenLease: lease,
                  ),
                ),
              ),
            ),
          );
          final session = setup.session
            ..loadedPath = track.path
            ..setOptimisticDuration(
              const Duration(hours: 15, minutes: 59, seconds: 59),
            );
          setup.fixture.playbackService.syncSlice(
            activeSessions: [session],
            playingSessionCount: 0,
            focusedSessionId: session.id,
            coverGeneration: 0,
            isInitialized: true,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final safe = Rect.fromLTRB(
            sidePadding,
            20,
            size.width - sidePadding,
            size.height - 34,
          );
          final names = [
            'previous',
            'play_pause',
            'next',
            'progress',
            'volume',
            'exit',
          ];
          final rects = [
            for (final name in names)
              tester.getRect(
                find.byKey(
                  ValueKey(
                    name == 'volume'
                        ? 'session_volume_slider'
                        : 'fullscreen_video_$name',
                  ),
                ),
              ),
          ];
          for (var i = 0; i < rects.length; i++) {
            final rect = rects[i];
            expect(
              rect.left,
              greaterThanOrEqualTo(safe.left),
              reason: names[i],
            );
            expect(rect.right, lessThanOrEqualTo(safe.right), reason: names[i]);
            expect(rect.top, greaterThanOrEqualTo(safe.top), reason: names[i]);
            expect(
              rect.bottom,
              lessThanOrEqualTo(safe.bottom),
              reason: names[i],
            );
            for (var j = i + 1; j < rects.length; j++) {
              expect(
                rect.overlaps(rects[j]),
                isFalse,
                reason: '${names[i]} overlaps ${names[j]}',
              );
            }
          }
          expect(rects[3].width, greaterThan(100));
          expect(rects[4].width, greaterThan(40));
          final times = find.descendant(
            of: find.byKey(const ValueKey('fullscreen_video_progress')),
            matching: find.byType(TimecodeLabel),
          );
          final currentTime = tester.getRect(times.first);
          final duration = tester.getRect(times.last);
          expect(currentTime.left, greaterThanOrEqualTo(safe.left));
          expect(duration.right, lessThanOrEqualTo(safe.right));
          expect(currentTime.overlaps(duration), isFalse);
          expect(
            find.byKey(const ValueKey('fullscreen_video_control_bar')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('session_volume_percent_text')),
            findsOneWidget,
          );
          if (const bool.fromEnvironment('FULLSCREEN_VIDEO_SCREENSHOTS') &&
              (size == const Size(320, 640) || size == const Size(1280, 800))) {
            final timeLabel = times.first;
            final timeText = tester.widget<Text>(
              find.descendant(of: timeLabel, matching: find.byType(Text)).first,
            );
            final fontFamily = timeText.style?.fontFamily ?? 'Roboto';
            await tester.runAsync(() async {
              final textFont = FontLoader(fontFamily)
                ..addFont(rootBundle.load('assets/fonts/Outfit-Variable.ttf'));
              final iconFont = FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
              await textFont.load();
              await iconFont.load();
            });
            await tester.pump();
            await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(capture),
              );
              final image = await boundary.toImage();
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              final folder = Directory('test-artifacts');
              await folder.create(recursive: true);
              final path =
                  '${folder.path}/fullscreen-video-${platform.name}-'
                  '${size.width.toInt()}x${size.height.toInt()}.png';
              await File(path).writeAsBytes(bytes.buffer.asUint8List());
              image.dispose();
            });
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }

  for (final kind in ['normal', 'asmr', 'queue']) {
    testWidgets('fullscreen video controls share detail styles for $kind', (
      tester,
    ) async {
      final orientation = AppOrientationController(
        setPreferredOrientations: (_) async {},
        setSystemUiMode: (_) async {},
      );
      final lease = await orientation.enterVideoFullscreen();
      addTearDown(lease.release);
      const queueColor = Color(0xFF2E9C8B);
      final track =
          testMusicTrack(
            name: 'Styled video',
            path: '/videos/style.mp4',
            groupKey: '/videos',
            groupTitle: 'Videos',
          ).copyWith(
            isVideo: true,
            remoteMetadataKind: kind == 'asmr'
                ? MusicTrack.remoteMetadataKindAsmrOne
                : null,
          );
      final setup = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: const Duration(seconds: 10),
        initialTrack: track,
        queueTracks: kind == 'queue' ? [track] : null,
        queueColorValue: kind == 'queue' ? queueColor.toARGB32() : null,
        physicalSize: const Size(3840, 2400),
        detailBuilder: (session) => SessionVideoFullscreenPage(
          sessionId: session.id,
          trackPath: track.path,
          fullscreenLease: lease,
        ),
      );
      final session = setup.session
        ..loadedPath = track.path
        ..setOptimisticDuration(const Duration(minutes: 2));
      setup.fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpAndSettle();

      final outer = tester.element(find.byType(SessionVideoFullscreenPage));
      final base = ProviderScope.containerOf(
        outer,
      ).read(themeProviderInstanceProvider).darkTheme;
      final expectedTheme = kind == 'queue'
          ? createPlaybackQueueSessionDetailTheme(base, queueColor)
          : base;
      final expectedPrimary = expectedTheme.colorScheme.primary;
      final play = find.byKey(const ValueKey('fullscreen_video_play_pause'));
      final playContext = tester.element(play);
      final theme = Theme.of(playContext);
      final cs = theme.colorScheme;
      expect(theme.brightness, Brightness.dark);
      expect(cs.primary, expectedPrimary);
      expect(cs.onPrimary, expectedTheme.colorScheme.onPrimary);
      expect(tester.getSize(play), const Size(48, 48));
      final playDecoration =
          tester
                  .widget<DecoratedBox>(
                    find
                        .ancestor(of: play, matching: find.byType(DecoratedBox))
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(playDecoration.shape, BoxShape.circle);
      expect(playDecoration.color, expectedPrimary);
      expect(
        playDecoration,
        sessionDetailPlayButtonDecoration(
          playContext,
          expectedPrimary,
          enabled: true,
        ),
      );
      final playButton = tester.widget<IconButton>(play);
      expect(playButton.style!.shape!.resolve({}), isA<CircleBorder>());
      expect(playButton.style!.foregroundColor!.resolve({}), cs.onPrimary);
      for (final name in ['previous', 'next']) {
        final button = find.byKey(ValueKey('fullscreen_video_$name'));
        final transport = tester.widget<PrimaryTransportButton>(button);
        final plate =
            tester
                    .widget<Container>(
                      find
                          .descendant(
                            of: button,
                            matching: find.byType(Container),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration;
        expect(plate.shape, BoxShape.circle);
        expect(
          plate.color,
          cs.surfaceContainerHighest.withValues(
            alpha: transport.enabled ? 0.35 : 0.15,
          ),
        );
      }
      final progressContext = tester.element(
        find.descendant(
          of: find.byKey(const ValueKey('fullscreen_video_progress')),
          matching: find.byType(Slider),
        ),
      );
      final progressTheme = SliderTheme.of(progressContext);
      expect(progressTheme.trackHeight, 3);
      expect(progressTheme.activeTrackColor, expectedPrimary);
      expect(progressTheme.thumbColor, expectedPrimary);
      expect(
        progressTheme.inactiveTrackColor,
        expectedPrimary.withValues(alpha: 0.22),
      );
      final progressThumb = progressTheme.thumbShape! as RoundSliderThumbShape;
      expect(progressThumb.enabledThumbRadius, 6);
      expect(progressThumb.elevation, 2);
      expect(
        (progressTheme.overlayShape! as RoundSliderOverlayShape).overlayRadius,
        12,
      );
      expect(
        progressTheme,
        sessionDetailProgressSliderTheme(progressContext, expectedPrimary),
      );
      final volumeContext = tester.element(
        find.byKey(const ValueKey('session_volume_slider')),
      );
      final volumeTheme = SliderTheme.of(volumeContext);
      expect(volumeTheme.trackHeight, 6);
      expect(
        (volumeTheme.thumbShape! as RoundSliderThumbShape).enabledThumbRadius,
        6,
      );
      expect(
        (volumeTheme.overlayShape! as RoundSliderOverlayShape).overlayRadius,
        14,
      );
      expect(
        volumeTheme,
        sessionDetailVolumeSliderTheme(volumeContext, isBoosted: false),
      );
      final timeLabels = find.descendant(
        of: find.byKey(const ValueKey('fullscreen_video_progress')),
        matching: find.byType(TimecodeLabel),
      );
      expect(timeLabels, findsNWidgets(2));
      for (final label in [timeLabels.first, timeLabels.last]) {
        expect(tester.widget(label), isA<TimecodeLabel>());
        final style = tester
            .widget<Text>(
              find.descendant(of: label, matching: find.byType(Text)).last,
            )
            .style!;
        expect(style.fontSize, 13);
        expect(style.fontWeight, FontWeight.w800);
        expect(
          style.color,
          sessionDetailForeground(
            cs,
            SessionDetailForegroundLevel.muted,
            darkFallback: cs.onSurface.withValues(alpha: 0.8),
          ),
        );
      }
      final volumeLabel = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('session_volume_percent_text')),
          matching: find.byType(Text),
        ),
      );
      expect(volumeLabel.style!.fontSize, 11);
      expect(volumeLabel.style!.fontWeight, FontWeight.w900);
      expect(volumeLabel.style!.color, theme.textTheme.labelSmall!.color);
      expect(volumeLabel.style!.decoration, TextDecoration.underline);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'portrait video fullscreen returns its only surface to landscape detail',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      // A normal portrait page has already observed the visible status bar.
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(padding: EdgeInsets.only(top: 24)),
            child: TopPageHeader(leading: BackButton()),
          ),
        ),
      );
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
      tester.view.viewPadding = const FakeViewPadding(top: 72);
      tester.view.padding = const FakeViewPadding(top: 72);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPadding);
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
        tester
            .widget<SessionDetailContent>(find.byType(SessionDetailContent))
            .isLandscape,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('session_video_tap_target')));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(SessionVideoFullscreenPage), findsOneWidget);
      final page = find.byType(SessionVideoFullscreenPage);
      final exit = find.byKey(const ValueKey('fullscreen_video_exit'));
      final portraitExitCenter = tester.getCenter(exit);
      final portraitRight = tester.getRect(page).right;
      expect(
        portraitExitCenter.dy,
        24 +
            AppPageHeaderMetrics.padding.top +
            AppPageHeaderMetrics.buttonSize / 2,
      );
      expect(
        find.byType(NativeSessionVideoSurface, skipOffstage: false),
        findsOneWidget,
      );

      tester.view.physicalSize = const Size(3840, 2880);
      await tester.pumpAndSettle();
      final landscapeExitCenter = portraitExitCenter.translate(
        tester.getRect(page).right - portraitRight,
        0,
      );
      expect(tester.getCenter(exit), landscapeExitCenter);
      // This fixture has no app-level inset retention. The controls must honor
      // its supplied inset; the real shell's rotation retention is tested there.
      for (final systemBarTop in [0.0, 72.0, 0.0]) {
        tester.view.viewPadding = FakeViewPadding(top: systemBarTop);
        tester.view.padding = FakeViewPadding(top: systemBarTop);
        await tester.pump();
        expect(
          tester.getCenter(exit),
          Offset(
            landscapeExitCenter.dx,
            landscapeExitCenter.dy - 24 + systemBarTop / 3,
          ),
        );
      }
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
        tester
            .widget<SessionDetailContent>(find.byType(SessionDetailContent))
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
      runtimeGraph.library.addTracks(<MusicTrack>[track], persist: false);
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
      final innerCoverSize = Size.square(
        coverProgressInnerDimension(playlistCoverSize),
      );
      expect(tester.getSize(grid), innerCoverSize);
      expect(tester.getSize(firstCell), innerCoverSize);
      expect(
        tester
            .widget<AsyncLocalCoverImage>(
              find.descendant(
                of: firstCell,
                matching: find.byType(AsyncLocalCoverImage),
              ),
            )
            .cacheWidth,
        64,
      );

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
        282,
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
      expect(find.byType(SessionVideoBlurredBackdrop), findsNothing);
      await tester.tap(find.byTooltip(languageProvider.tr('switch_audio')));
      await pumpUntilFound(
        tester,
        find.byKey(ValueKey<String>('queue_switcher_track_${track.path}')),
      );
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

  testWidgets(
    'pressing play keeps the loaded subtitle visible during audio preparation',
    (tester) async {
      final harness = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(
          sourcePath: 'resume.srt',
          cues: const [
            SubtitleCue(
              start: Duration.zero,
              end: Duration(seconds: 30),
              text: 'Subtitle at the paused position',
            ),
          ],
        ),
        initialPosition: const Duration(seconds: 10),
        physicalSize: defaultTargetPlatform == TargetPlatform.windows
            ? const Size(3840, 2400)
            : const Size(1080, 2400),
      );
      final session = harness.session;
      final playback = harness.fixture.playback;
      // Paused Windows audio may release its decoder and resume via prepare.
      session.setOptimisticState(processingState: ProcessingState.idle);
      playback.publishSessionState(session.id);
      final finishLoading = Completer<void>();
      addTearDown(() {
        if (!finishLoading.isCompleted) finishLoading.complete();
      });
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
              final preparation = session.beginPreparation(
                showLoading: showLoading,
                autoPlay: autoPlay,
              );
              playback.publishSessionState(session.id);
              await finishLoading.future;
              session.finishPreparation(
                preparation.generation,
                prepared: true,
                autoPlay: autoPlay,
              );
              session.cancelPlaybackStart(preparation.generation);
              session.setOptimisticState(
                playing: true,
                processingState: ProcessingState.ready,
              );
              playback.publishSessionState(session.id);
              return true;
            },
        pauseSession: (_) async {},
        startSession: (_, {required shouldStartTriggerCountdown}) async =>
            false,
        resolveAdvance: (_, {required forward}) => null,
        hasAdjacent: (_, {required forward}) => false,
      );
      await tester.pumpAndSettle();

      final timeline = find.byType(TimelineSubtitleView);
      final state = tester.state(timeline);
      final fade = find.byWidgetPredicate(
        (widget) =>
            widget is FadeTransition && widget.child is TimelineSubtitleView,
      );
      void expectVisibleSubtitle() {
        expect(find.byKey(const ValueKey('subtitle_loading')), findsNothing);
        expect(tester.state(timeline), same(state));
        expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
        expect(find.text('Subtitle at the paused position'), findsOneWidget);
      }

      await tester.tap(
        find.descendant(
          of: find.byType(PrimaryPlaybackControls),
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
      );
      await tester.pump();
      expect(session.isLoading, isTrue);
      expectVisibleSubtitle();
      await tester.pump(PlaybackSession.loadingIndicatorThreshold);
      expectVisibleSubtitle();
      finishLoading.complete();
      await tester.pumpAndSettle();
      expect(session.effectivePlaying, isTrue);
      expectVisibleSubtitle();
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
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
      expect(tester.getSize(cover), const Size(344, 258));
      expect(tester.getSize(cover).aspectRatio, closeTo(4 / 3, 0.001));

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
      expect(midCoverHeight, initialCoverHeight);

      await tester.pump(const Duration(milliseconds: 350));
      final loadingCoverHeight = tester.getSize(cover).height;
      expect(loadingCoverHeight, initialCoverHeight);

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
      expect(tester.getSize(cover).height, initialCoverHeight);
    },
  );

  testWidgets(
    'subtitle placeholder shows five low-glare themed pill bars and aligns by orientation',
    (tester) async {
      for (final brightness in Brightness.values) {
        final theme = ThemeData(brightness: brightness);
        final cs = theme.colorScheme;
        final isDark = brightness == Brightness.dark;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            themeAnimationDuration: Duration.zero,
            home: const SessionSubtitlePlaceholder(),
          ),
        );
        final bars = find.descendant(
          of: find.byType(SessionSubtitlePlaceholder),
          matching: find.byType(Container),
        );
        expect(bars, findsNWidgets(5));
        final decorations = tester
            .widgetList<Container>(bars)
            .map((bar) => bar.decoration as BoxDecoration)
            .toList(growable: false);
        final expectedCenter = Color.lerp(
          cs.onSurface,
          cs.primary,
          0.35,
        )!.withValues(alpha: isDark ? 0.18 : 0.15);
        final expectedNear = cs.onSurface.withValues(
          alpha: isDark ? 0.09 : 0.08,
        );
        final expectedFar = cs.onSurface.withValues(
          alpha: isDark ? 0.045 : 0.04,
        );
        expect(decorations.map((d) => d.color).toList(), [
          expectedFar,
          expectedNear,
          expectedCenter,
          expectedNear,
          expectedFar,
        ]);
        expect(
          decorations.map((d) => d.borderRadius).toList(),
          [
            BorderRadius.circular(5),
            BorderRadius.circular(5),
            BorderRadius.circular(6),
            BorderRadius.circular(5),
            BorderRadius.circular(5),
          ],
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          themeAnimationDuration: Duration.zero,
          home: const SizedBox(
            width: 400,
            height: 240,
            child: SessionSubtitlePlaceholder(isLandscape: true),
          ),
        ),
      );
      final landscapeBars = find.descendant(
        of: find.byType(SessionSubtitlePlaceholder),
        matching: find.byType(Container),
      );
      expect(
        tester.getTopLeft(landscapeBars.first).dx,
        closeTo(landscapeDetailTextInset, 0.01),
      );
      expect(
        tester.getTopLeft(landscapeBars.at(2)).dx,
        closeTo(landscapeDetailTextInset, 0.01),
      );
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
    'timeline subtitles scroll, snap, return, and tap to focus before seeking',
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
        const ValueKey<String>('subtitle_timeline_text_0'),
      );
      final cue1 = find.byKey(
        const ValueKey<String>('subtitle_timeline_text_1'),
      );
      final cue2 = find.byKey(
        const ValueKey<String>('subtitle_timeline_text_2'),
      );
      double textAlphaFor(Finder cue) =>
          tester.widget<Text>(cue).style!.color!.a;

      final panelRect = tester.getRect(find.byType(SessionSubtitlePanel));
      final viewportRect = tester.getRect(viewport);
      final coverRect = tester.getRect(find.byType(CoverArtworkFrame));
      final headingRect = tester.getRect(
        find.byKey(const ValueKey('session_detail_heading_subtitle-session')),
      );
      expect(coverRect.contains(headingRect.topLeft), isTrue);
      expect(coverRect.contains(headingRect.bottomRight), isTrue);
      expect(viewportRect.top, coverRect.bottom);
      expect(viewportRect, panelRect);
      final edgeFade = find.byKey(
        const ValueKey('subtitle_timeline_edge_fade'),
      );
      final fadeMask = tester.widget<ShaderMask>(edgeFade);
      expect(fadeMask.blendMode, BlendMode.dstIn);
      final fadeAlpha = await _subtitleEdgeAlpha(tester);
      expect(fadeAlpha[0], 255);
      expect(fadeAlpha[1], 255);
      expect(fadeAlpha[2], 255);
      expect(fadeAlpha[3], inInclusiveRange(120, 140));
      expect(fadeAlpha[4], lessThan(10));
      expect(
        find.descendant(
          of: edgeFade,
          matching: find.byKey(const ValueKey('subtitle_timeline_list')),
        ),
        findsOneWidget,
      );
      expect(textAlphaFor(cue0), lessThan(textAlphaFor(cue1) * 0.35));
      expect(textAlphaFor(cue1), closeTo(1.0, 0.01));
      expect(textAlphaFor(cue2), lessThan(textAlphaFor(cue1) * 0.35));
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
      await tester.tap(cue2);
      await tester.pump();
      expect(textAlphaFor(cue2), closeTo(1.0, 0.01));
      expect(
        tester.getCenter(cue2).dy,
        closeTo(tester.getCenter(viewport).dy, 1.0),
      );
      expect(result.session.position, const Duration(milliseconds: 2500));
      expect(
        find.byKey(const ValueKey('subtitle_timeline_seek_button')),
        findsOneWidget,
      );
      await tester.tap(cue1);
      await tester.pump();
      expect(textAlphaFor(cue1), closeTo(1.0, 0.01));
      expect(
        find.byKey(const ValueKey('subtitle_timeline_seek_button')),
        findsNothing,
      );

      final fixedCenter = tester.getCenter(cue1);
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -70));
      await tester.pump();
      expect(tester.getCenter(cue1).dy, lessThan(fixedCenter.dy));
      expect(textAlphaFor(cue2), closeTo(1.0, 0.01));
      await gesture.up();
      await tester.pump();
      // Measure after the focused cue's scale animation finishes.
      await tester.pump(const Duration(milliseconds: 200));
      expect(textAlphaFor(cue2), closeTo(1.0, 0.01));
      expect(
        tester.getCenter(cue2).dy,
        closeTo(tester.getCenter(viewport).dy, 1.0),
      );
      expect(
        find.byKey(const ValueKey<String>('subtitle_timeline_seek_button')),
        findsOneWidget,
      );
      final dashes = find.byKey(
        const ValueKey('subtitle_timeline_seek_dashes'),
      );
      expect(tester.getRect(dashes).left, lessThan(tester.getCenter(list).dx));
      expect(
        tester
            .getCenter(
              find.byKey(const ValueKey('subtitle_timeline_seek_button')),
            )
            .dx,
        greaterThan(tester.getCenter(list).dx),
      );
      expect(
        find.descendant(
          of: edgeFade,
          matching: find.byKey(const ValueKey('subtitle_timeline_seek_button')),
        ),
        findsNothing,
      );

      await tester.pump(const Duration(milliseconds: 2500));
      expect(textAlphaFor(cue2), closeTo(1.0, 0.01));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(textAlphaFor(cue1), closeTo(1.0, 0.01));

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
      expect(textAlphaFor(cue1), closeTo(1.0, 0.01));
      expect(tester.getCenter(cue1), draggedCueCenter);
      await playingGesture.moveBy(const Offset(0, -36));
      await playingGesture.up();
      await tester.pump();
      expect(textAlphaFor(cue2), closeTo(1.0, 0.01));
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
      tester.view.physicalSize = const Size(2400, 1080);
      await tester.pumpAndSettle();
      await tester.drag(list, const Offset(0, -100));
      await tester.pump();
      final landscapeIndicator = find
          .ancestor(of: dashes, matching: find.byType(Row))
          .first;
      expect(
        tester.getRect(dashes).left,
        greaterThan(tester.getCenter(landscapeIndicator).dx),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
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

  for (final selectQueueFirst in [false, true]) {
    testWidgets(
      'playlist right-click multiselect selects the current ${selectQueueFirst ? 'queue' : 'session'} and another item',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(500, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: _RecordingPlaybackCoverCacheService(),
        );
        addTearDown(fixture.dispose);
        final track = testMusicTrack(
          name: 'Saved selection track',
          path: PathMatcher.normalize('/library/saved/track.mp3'),
          groupKey: PathMatcher.normalize('/library/saved'),
          groupTitle: 'Saved selection work',
        );
        final temporaryTrack = testMusicTrack(
          name: 'Temporary selection track',
          path: PathMatcher.normalize('/library/temporary/track.mp3'),
          groupKey: PathMatcher.normalize('/library/temporary'),
          groupTitle: 'Temporary selection work',
        );
        fixture.runtimeGraph.library.addTracks([
          track,
          temporaryTrack,
        ], persist: false);
        final session = fixture.runtimeGraph.playback.createTrackSession(track);
        final temporary = fixture.runtimeGraph.playback.createTrackSession(
          temporaryTrack,
        )..isTemporary = true;
        final queue = fixture.runtimeGraph.playback.createPlaybackQueue(
          'Right-click selection queue',
        );
        fixture.playbackService.syncSlice(
          activeSessions: [session, queue, temporary],
          playingSessionCount: 0,
          focusedSessionId: session.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        await tester.pumpWidget(fixture.build(const PlaylistTab()));
        await pumpFiniteTransitions(tester);

        final actionLabel = fixture.languageProvider.tr('select_multiple');
        final temporaryTitle = find.text(temporaryTrack.displayName);
        Finder indicator(String id) =>
            find.byKey(ValueKey<String>('playlist_selection_indicator_$id'));
        await tester.tap(
          temporaryTitle,
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text(actionLabel), findsOneWidget);
        expect(
          find.text(fixture.languageProvider.tr('pin_to_top')),
          findsNothing,
        );
        await tester.tap(find.text(actionLabel));
        await tester.pumpAndSettle();
        expect(indicator(temporary.id), findsOneWidget);
        expect(
          tester.widget<IconButton>(
            find.byKey(const ValueKey('batch_pin_button')),
          ).onPressed,
          isNull,
        );
        await tester.tap(temporaryTitle);
        await tester.pumpAndSettle();
        expect(indicator(temporary.id), findsNothing);

        final first = selectQueueFirst ? queue : session;
        final second = selectQueueFirst ? session : queue;
        final firstTitle = find.text(
          selectQueueFirst ? 'Right-click selection queue' : track.displayName,
        );
        final secondTitle = find.text(
          selectQueueFirst ? track.displayName : 'Right-click selection queue',
        );
        await tester.tap(
          firstTitle,
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text(actionLabel), findsOneWidget);
        await tester.tap(find.text(actionLabel));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('playlist_batch_selection_header')),
          findsOneWidget,
        );
        expect(indicator(first.id), findsOneWidget);
        expect(indicator(second.id), findsNothing);
        expect(indicator(temporary.id), findsNothing);
        expect(
          find.bySemanticsLabel(
            fixture.languageProvider.tr('selected_count', {'count': '1'}),
          ),
          findsOneWidget,
        );
        await tester.tap(secondTitle);
        await tester.tap(temporaryTitle);
        await tester.pumpAndSettle();
        expect(indicator(first.id), findsOneWidget);
        expect(indicator(second.id), findsOneWidget);
        expect(indicator(temporary.id), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            fixture.languageProvider.tr('selected_count', {'count': '3'}),
          ),
          findsOneWidget,
        );
        await tester.longPress(firstTitle, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(indicator(first.id), findsNothing);
        expect(indicator(second.id), findsOneWidget);
        expect(indicator(temporary.id), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            fixture.languageProvider.tr('selected_count', {'count': '2'}),
          ),
          findsOneWidget,
        );
        expect(find.byType(SessionDetailLayout), findsNothing);
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  testWidgets(
    'playlist multiselect shows expanded header without resetting scroll position',
    (tester) async {
      final windows = defaultTargetPlatform == TargetPlatform.windows;
      final dpr = windows ? 1.25 : 1.0;
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = const Size(500, 420) * dpr;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final tracks = [
        for (var index = 0; index < 12; index++)
          testMusicTrack(
            name: 'Selection track $index',
            path: '/library/selection/track-$index.mp3',
            groupKey: '/library/selection',
            groupTitle: 'Selection work',
          ),
      ];
      fixture.library.addTracks(tracks, persist: false);
      final sessions = [
        for (final track in tracks)
          fixture.playback.createTrackSession(track)
            ..state = const PlayerState(false, ProcessingState.ready),
      ];
      fixture.playbackService.markSessionStateDirty();
      fixture.playbackService.syncSlice(
        activeSessions: sessions,
        playingSessionCount: 0,
        focusedSessionId: sessions.first.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      final tabIndex = ValueNotifier(0);
      addTearDown(tabIndex.dispose);
      await tester.pumpWidget(
        fixture.build(
          AppPageTransitionHost(
            child: Padding(
              padding: EdgeInsets.only(
                top: windows ? WindowsWindowTitleBar.height : 0,
              ),
              child: AppFadeThroughIndexedStack.lazy(
                indexListenable: tabIndex,
                itemCount: 1,
                separateHeader: true,
                itemBuilder: (_, _) => const PlaylistTab(),
              ),
            ),
          ),
        ),
      );
      final normalButton = find.byKey(
        const ValueKey('playlist_clear_all_button'),
      );
      final batchButton = find.byKey(const ValueKey('batch_play_button'));
      Finder titleCapsule(String titleKey) => find.byWidgetPredicate(
        (widget) =>
            widget is HeaderTopCapsule &&
            widget.title == fixture.languageProvider.tr(titleKey),
      );
      final normalTitle = titleCapsule('playback_sessions');
      final batchTitle = titleCapsule('multi_select');
      final list = find.byKey(const PageStorageKey<String>('playlist_list'));
      await pumpUntilFound(tester, list);
      await pumpFiniteTransitions(tester);
      final expandedButtonY = tester.getCenter(normalButton).dy;
      final expandedTitleY = tester.getTopLeft(normalTitle).dy;
      final scroll = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position;
      const batchExit = ValueKey<String>('exit_selection_button');
      for (final offset in [0.0, 24.5, 80.0]) {
        scroll.jumpTo(offset);
        await tester.pump();
        final normalY = tester.getCenter(normalButton).dy;
        final titleY = tester.getTopLeft(normalTitle).dy;
        final listItem = find
            .textContaining('Selection track')
            .hitTestable()
            .first;
        if (windows) {
          await tester.tap(
            listItem,
            buttons: kSecondaryMouseButton,
            kind: PointerDeviceKind.mouse,
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(fixture.languageProvider.tr('select_multiple')),
            kind: PointerDeviceKind.mouse,
          );
        } else {
          await tester.longPress(listItem);
        }
        for (var frame = 0; frame < 28; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          for (final (control, expectedY) in [
            (normalButton, normalY),
            (batchButton, expandedButtonY),
            (normalTitle, titleY),
            (batchTitle, expandedTitleY),
          ]) {
            if (control.evaluate().isNotEmpty) {
              final y = control == normalTitle || control == batchTitle
                  ? tester.getTopLeft(control).dy
                  : tester.getCenter(control).dy;
              expect(
                y,
                closeTo(expectedY, 0.01),
                reason: '$control at scroll offset $offset, frame $frame',
              );
            }
          }
        }
        await pumpFiniteTransitions(tester);
        expect(
          tester.getCenter(batchButton).dy,
          closeTo(expandedButtonY, 0.01),
        );
        expect(scroll.pixels, offset);
        if (offset == 80) {
          final count = find.bySemanticsLabel(
            fixture.languageProvider.tr('selected_count', {'count': '1'}),
          );
          expect(count, findsOneWidget);
          expect(
            tester.getCenter(find.byKey(batchExit)).dy,
            closeTo(expandedButtonY, 0.01),
          );
        }
        await tester.tap(find.byKey(batchExit));
        await pumpFiniteTransitions(tester);
        expect(tester.getCenter(normalButton).dy, closeTo(normalY, 0.01));
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
        queueTrack,
        queueWorkTrack,
        secondQueueWorkTrack,
      ], persist: false);
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
      await pumpFiniteTransitions(tester);

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

      final firstCheck = find.byKey(
        ValueKey<String>('playlist_selection_indicator_${trackSession.id}'),
      );
      await tester.pump();
      expect(firstCheck, findsOneWidget);
      final checkFade = find
          .ancestor(of: firstCheck, matching: find.byType(FadeTransition))
          .first;
      expect(tester.widget<FadeTransition>(checkFade).opacity.value, 0);

      final batchHeader = find.byKey(batchHeaderKey);
      expect(batchHeader, findsOneWidget);
      expect(
        tester.widget<TopPageHeader>(batchHeader).iconWidget,
        isA<PlaylistIcon>().having((w) => w.filled, 'filled', isTrue),
      );
      expect(
        find.text(fixture.languageProvider.tr('multi_select')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: batchHeader,
          matching: find.byType(AppRollingNumber),
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
        kAppFadeDuration,
      );
      expect(find.byType(TopPageHeader), findsNWidgets(2));
      expect(
        find.descendant(
          of: batchHeader,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is TweenAnimationBuilder<double> &&
                widget.child is! Opacity,
          ),
        ),
        findsNothing,
      );

      await pumpFiniteTransitions(tester);
      expect(
        find.bySemanticsLabel(
          fixture.languageProvider.tr('selected_count', {'count': '1'}),
        ),
        findsOneWidget,
      );

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
      expect(
        indicatorDecoration.color,
        AppDesignTokens.of(tester.element(trackIndicator)).success,
      );
      expect(indicatorDecoration.shape, BoxShape.circle);
      final trackCard = tester.widget<Material>(
        find.ancestor(of: trackContent, matching: find.byType(Material)).first,
      );
      expect(trackCard.color, Colors.transparent);
      expect(trackCard.shape, same(playlistRowShape));
      final trackSemantics = tester
          .widgetList<Semantics>(
            find.ancestor(of: trackTitle, matching: find.byType(Semantics)),
          )
          .firstWhere((widget) => widget.properties.selected != null);
      expect(trackSemantics.properties.selected, isTrue);
      expect(trackSemantics.properties.onTap, isNotNull);

      final ordinaryCard = find.byWidgetPredicate(
        (widget) =>
            widget is SessionListCard && widget.sessionId == trackSession.id,
      );
      final retainedCard = tester.widget<SessionListCard>(ordinaryCard);
      await tester.tap(queueTitle);
      await pumpFiniteTransitions(tester);

      expect(tester.widget<SessionListCard>(ordinaryCard), same(retainedCard));
      expect(trackIndicator, findsOneWidget);
      expect(queueIndicator, findsOneWidget);
      expect(tester.getTopLeft(trackTitle).dx, trackTitleX);
      expect(tester.getTopLeft(queueTitle).dx, queueTitleX);
      final queueSurface = tester.widget<Material>(
        find.byKey(ValueKey('playback_queue_row_surface_${queueSession.id}')),
      );
      expect(queueSurface.color, Colors.transparent);

      // Long-pressing while in multi-select mode toggles selection without wiping.
      await tester.longPress(trackTitle);
      await pumpFiniteTransitions(tester);
      expect(trackIndicator, findsNothing);
      expect(queueIndicator, findsOneWidget);

      await tester.longPress(trackTitle);
      await pumpFiniteTransitions(tester);
      expect(trackIndicator, findsOneWidget);
      expect(queueIndicator, findsOneWidget);

      final pauseIconButton = find.byKey(
        const ValueKey<String>('batch_pause_button'),
      );
      final playIconButton = find.byKey(
        const ValueKey<String>('batch_play_button'),
      );
      final removeIconButton = find.byKey(
        const ValueKey<String>('batch_remove_button'),
      );
      final removeIconContext = tester.element(
        find.descendant(
          of: removeIconButton,
          matching: find.byIcon(Icons.delete_outline_rounded),
        ),
      );
      expect(
        IconTheme.of(removeIconContext).color,
        Theme.of(removeIconContext).colorScheme.error,
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
      await pumpFiniteTransitions(tester);
      expect(trackIndicator, findsNothing);
      expect(queueIndicator, findsOneWidget);
      await tester.tap(queueTitle);
      await tester.pump();
      expect(find.byType(TopPageHeader), findsNWidgets(2));
      await pumpFiniteTransitions(tester);
      expect(batchHeader, findsNothing);
      expect(find.byType(TopPageHeader), findsOneWidget);

      await tester.longPress(queueTitle);
      await pumpFiniteTransitions(tester);
      expect(queueIndicator, findsOneWidget);
      await tester.tap(trackTitle);
      await pumpFiniteTransitions(tester);
      expect(trackIndicator, findsOneWidget);
      final sourceQueueIsFirst =
          tester.getTopLeft(queueTitle).dy < tester.getTopLeft(trackTitle).dy;
      await tester.tap(createQueueIconButton);
      await pumpFiniteTransitions(tester);
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
      await pumpFiniteTransitions(tester);
      expect(batchHeader, findsNothing);
      expect(find.byType(TopPageHeader), findsOneWidget);
    },
  );

  testWidgets(
    'temporary playback stays above saved items and can be selected without pinning',
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
      fixture.runtimeGraph.library.addTracks(tracks, persist: false);
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
      final temporaryCardWidget = tester.widget<Material>(
        find.ancestor(of: temporaryCard, matching: find.byType(Material)).first,
      );
      final savedCardWidget = tester.widget<Material>(
        find.ancestor(of: savedCard, matching: find.byType(Material)).first,
      );
      final theme = Theme.of(tester.element(temporaryCard));
      final isDark = theme.brightness == Brightness.dark;
      expect(
        (temporaryCardWidget.shape! as RoundedRectangleBorder).side,
        BorderSide.none,
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
      expect(
        (temporarySwipe.shape as RoundedRectangleBorder).side,
        BorderSide.none,
      );
      expect(temporarySwipe.closedColor, expectedTemporaryCardColor);
      expect(savedSwipe.closedColor, theme.colorScheme.surface);
      expect(temporaryCardWidget.color, Colors.transparent);
      expect(temporaryCardWidget.color, savedCardWidget.color);
      expect(temporarySwipe.onLeadingAction, isNull);
      await tester.longPress(find.text('Temporary audio'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('playlist_batch_selection_header')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('playlist_selection_indicator_${temporary.id}')),
        findsOneWidget,
      );
      for (final action in ['play', 'pause', 'remove']) {
        final button = find.byKey(ValueKey('batch_${action}_button'));
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
      }
      expect(
        tester.widget<IconButton>(
          find.byKey(const ValueKey('batch_pin_button')),
        ).onPressed,
        isNull,
      );
    },
  );

  testWidgets('playlist multiselect batch pin skips temporary sessions', (
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
    final temporaryTrack = testMusicTrack(
      name: 'Temporary track',
      path: PathMatcher.normalize('/library/temporary/03.mp3'),
      groupKey: PathMatcher.normalize('/library/temporary'),
      groupTitle: 'Temporary',
    );
    fixture.runtimeGraph.library.addTracks(<MusicTrack>[
      track1,
      track2,
      temporaryTrack,
    ], persist: false);
    final session1 = fixture.runtimeGraph.playback.createTrackSession(track1);
    final session2 = fixture.runtimeGraph.playback.createTrackSession(track2);
    final temporary = fixture.runtimeGraph.playback.createTrackSession(
      temporaryTrack,
      isTemporary: true,
    );
    fixture.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session1, session2, temporary],
      playingSessionCount: 0,
      focusedSessionId: session1.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    await tester.pumpWidget(fixture.build(const PlaylistTab()));
    await tester.pumpAndSettle();

    final track1Title = find.text('Track 1');
    final track2Title = find.text('Track 2');
    final temporaryTitle = find.text(temporaryTrack.displayName);
    final temporarySelected = find.byKey(
      ValueKey('playlist_selection_indicator_${temporary.id}'),
    );

    // 1. Long press Track 1 to enter selection mode
    await tester.longPress(track1Title);
    await tester.pumpAndSettle();

    final batchHeader = find.byKey(
      const ValueKey<String>('playlist_batch_selection_header'),
    );
    expect(batchHeader, findsOneWidget);

    await tester.tap(track2Title);
    await tester.tap(temporaryTitle);
    await tester.pumpAndSettle();
    expect(temporarySelected, findsOneWidget);

    fixture.playbackService.syncSlice(
      activeSessions: [temporary, session1, session2],
      playingSessionCount: 0,
      focusedSessionId: session1.id,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pumpAndSettle();
    expect(temporarySelected, findsOneWidget);

    final batchPinButton = find.byKey(
      const ValueKey<String>('batch_pin_button'),
    );
    expect(batchPinButton, findsOneWidget);
    expect(
      tester.widget<IconButton>(batchPinButton).tooltip,
      fixture.languageProvider.tr('pin_to_top'),
    );

    await tester.tap(batchPinButton);
    await tester.pumpAndSettle();

    expect(batchHeader, findsNothing);
    expect(
      fixture.settingsRepository.pinnedPlaylistSessionIds,
      unorderedEquals(<String>[session1.id, session2.id]),
    );

    await tester.longPress(track1Title);
    await tester.pumpAndSettle();
    expect(batchHeader, findsOneWidget);

    await tester.tap(track2Title);
    await tester.tap(temporaryTitle);
    await tester.pumpAndSettle();
    expect(temporarySelected, findsOneWidget);

    final batchUnpinButton = find.byKey(
      const ValueKey<String>('batch_pin_button'),
    );
    expect(batchUnpinButton, findsOneWidget);
    expect(
      tester.widget<IconButton>(batchUnpinButton).tooltip,
      fixture.languageProvider.tr('unpin_from_top'),
    );

    await tester.tap(batchUnpinButton);
    await tester.pumpAndSettle();

    expect(batchHeader, findsNothing);
    expect(fixture.settingsRepository.pinnedPlaylistSessionIds, isEmpty);
    expect(
      find.byKey(ValueKey('playlist_session_pinned_${temporary.id}')),
      findsNothing,
    );
  }, variant: const TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  }));

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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
      ], persist: false);
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

  for (final (platform, screenSize, headerHeight, hasSubtitles) in [
    (TargetPlatform.android, const Size(2400, 1080), 40.0, false),
    (TargetPlatform.windows, const Size(2880, 1800), 48.0, false),
    (TargetPlatform.windows, const Size(3840, 2400), 48.0, false),
    (TargetPlatform.android, const Size(2400, 1080), 40.0, true),
    (TargetPlatform.windows, const Size(2880, 1800), 48.0, true),
    (TargetPlatform.windows, const Size(3840, 2400), 48.0, true),
  ]) {
    testWidgets(
      'landscape session detail displays 4:3 cover with platform column widths on ${platform.name} at ${screenSize.width / 3}, subtitles=$hasSubtitles',
      (tester) async {
        await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(
            sourcePath: 'layout.srt',
            cues: hasSubtitles
                ? const [
                    SubtitleCue(
                      start: Duration.zero,
                      end: Duration(minutes: 1),
                      text: 'Subtitle alignment',
                    ),
                  ]
                : const [],
          ),
          preloadSubtitle: hasSubtitles,
          initialPosition: Duration.zero,
          physicalSize: screenSize,
        );

        final coverFrameFinder = find.descendant(
          of: find.byType(SessionDetailPage),
          matching: find.byType(CoverArtworkFrame),
        );
        expect(coverFrameFinder, findsOneWidget);

        final titleFinder = find.byKey(
          const ValueKey('title_marquee_subtitle-session'),
        );
        expect(titleFinder, findsOneWidget);

        final titleInsideCover = find.descendant(
          of: coverFrameFinder,
          matching: titleFinder,
        );
        expect(titleInsideCover, findsNothing);

        final coverRect = tester.getRect(coverFrameFinder);
        final titleRect = tester.getRect(titleFinder);

        // Title is in the right section (to the right of the cover)
        expect(titleRect.left, greaterThan(coverRect.right));
        expect(
          titleRect.top,
          platform == TargetPlatform.android
              ? closeTo(coverRect.top, 0.5)
              : lessThan(coverRect.top),
        );
        expect(coverRect.width / coverRect.height, closeTo(4 / 3, 0.001));
        final progressRect = tester.getRect(find.byType(SessionProgressBar));
        expect(progressRect.top - coverRect.bottom, greaterThan(5));
        final leftRect = tester.getRect(
          find.byKey(const ValueKey('session_detail_cover_area')),
        );
        void expectCoverAndProgressLayout(
          Rect cover,
          Rect left,
          Rect progress,
        ) {
          final bounds = tester.getRect(
            find.byKey(const ValueKey('session_detail_landscape_layout')),
          );
          final primary = tester.getRect(
            find.byKey(const ValueKey('session_detail_primary_controls')),
          );
          expect(cover.top, greaterThanOrEqualTo(bounds.top + headerHeight));
          expect(cover.width / cover.height, closeTo(4 / 3, 0.001));
          expect(cover.center.dx, closeTo(left.center.dx, 0.5));
          if (platform == TargetPlatform.android) {
            expect(cover.top, closeTo(tester.getRect(titleFinder).top, 0.5));
            expect(cover.bottom, closeTo(primary.top - 16, 0.5));
          } else {
            expect(cover.center.dy, closeTo(bounds.center.dy, 0.5));
          }
          expect(primary.top - cover.bottom, greaterThanOrEqualTo(16 - 0.5));
          expect(primary.height, closeTo(48, 0.5));
          expect(progress.top, closeTo(primary.bottom + 4, 0.5));
          expect(progress.bottom, closeTo(bounds.bottom - 16, 0.5));
          final secondary = find.byKey(
            const ValueKey('playback_secondary_controls'),
          );
          expect(
            tester.getRect(secondary).bottom,
            closeTo(progress.bottom, 0.5),
          );
          final buttons = find.descendant(
            of: secondary,
            matching: find.byType(IconButton),
          );
          expect(buttons, findsNWidgets(6));
          for (var index = 1; index < 6; index++) {
            expect(
              tester.getRect(buttons.at(index)).left -
                  tester.getRect(buttons.at(index - 1)).right,
              closeTo(0, 0.5),
            );
          }

          expect(primary.center.dx, closeTo(progress.center.dx, 0.5));
          expect(progress.width, closeTo(left.width * 0.8, 0.5));
          expect(progress.center.dx, closeTo(left.center.dx, 0.5));
          expect(progress.top - cover.bottom, greaterThan(5));
        }

        expectCoverAndProgressLayout(coverRect, leftRect, progressRect);
        final rightRect = tester.getRect(
          find.byKey(const ValueKey('session_detail_right_column')),
        );
        final columnRatio = platform == TargetPlatform.windows ? 4 / 3 : 1.0;
        expect(leftRect.width, closeTo(rightRect.width * columnRatio, 0.5));
        expect(rightRect.left - leftRect.right, closeTo(12, 0.5));
        if (platform == TargetPlatform.windows) {
          expect(
            coverRect.width,
            lessThanOrEqualTo(leftRect.width * 0.7 + 0.5),
          );
          expect(
            coverRect.left - leftRect.left,
            greaterThanOrEqualTo(leftRect.width * 0.15 - 0.5),
          );
          expect(
            leftRect.right - coverRect.right,
            greaterThanOrEqualTo(leftRect.width * 0.15 - 0.5),
          );
        } else {
          expect(coverRect.width, lessThanOrEqualTo(leftRect.width));
        }
        expect(titleRect.left, closeTo(rightRect.left + 4, 0.5));
        expect(
          rightRect.top,
          platform == TargetPlatform.android
              ? closeTo(coverRect.top, 0.5)
              : lessThan(coverRect.top),
        );
        expect(
          rightRect.bottom,
          closeTo(
            tester
                    .getRect(
                      find.byKey(
                        const ValueKey('session_detail_landscape_layout'),
                      ),
                    )
                    .top +
                progressRect.bottom,
            0.5,
          ),
        );
        final secondary = find.byKey(
          const ValueKey('playback_secondary_controls'),
        );
        expect(tester.getRect(secondary).left, closeTo(titleRect.left, 0.5));
        expect(
          tester.getRect(find.byType(TransportPlaybackControlPanel)).bottom,
          closeTo(rightRect.bottom, 0.5),
        );
        if (hasSubtitles) {
          final subtitle = find.text('Subtitle alignment');
          expect(tester.widget<Text>(subtitle).textAlign, TextAlign.left);
          expect(tester.getRect(subtitle).left, closeTo(titleRect.left, 0.5));
          final fadeAlpha = await _subtitleEdgeAlpha(tester);
          expect(fadeAlpha[0], lessThan(10));
          expect(fadeAlpha[1], inInclusiveRange(120, 140));
          expect(fadeAlpha[2], 255);
          expect(fadeAlpha[3], inInclusiveRange(120, 140));
          expect(fadeAlpha[4], lessThan(10));
        }

        if (platform == TargetPlatform.android) {
          tester.view.physicalSize = Size(screenSize.width, 810);
          await tester.pumpAndSettle();
          final resizedCover = tester.getRect(coverFrameFinder);
          expectCoverAndProgressLayout(
            resizedCover,
            tester.getRect(
              find.byKey(const ValueKey('session_detail_cover_area')),
            ),
            tester.getRect(find.byType(SessionProgressBar)),
          );
          expect(resizedCover.height, lessThan(coverRect.height));
          expect(tester.takeException(), isNull);
        } else {
          for (final resized in [
            const Size(3840, 1800),
            const Size(2880, 1800),
            screenSize,
          ]) {
            tester.view.physicalSize = resized;
            await tester.pumpAndSettle();
            final resizedCover = tester.getRect(coverFrameFinder);
            final resizedLeft = tester.getRect(
              find.byKey(const ValueKey('session_detail_cover_area')),
            );
            final resizedRight = tester.getRect(
              find.byKey(const ValueKey('session_detail_right_column')),
            );
            expect(resizedLeft.width, closeTo(resizedRight.width * 4 / 3, 0.5));
            final resizedProgress = tester.getRect(
              find.byType(SessionProgressBar),
            );
            expectCoverAndProgressLayout(
              resizedCover,
              resizedLeft,
              resizedProgress,
            );
            expect(tester.getRect(titleFinder).top, lessThan(resizedCover.top));
            expect(
              tester.getRect(find.byType(TransportPlaybackControlPanel)).bottom,
              closeTo(resizedRight.bottom, 0.5),
            );
            expect(
              resizedCover.width / resizedCover.height,
              closeTo(4 / 3, 0.001),
            );
            expect(tester.takeException(), isNull);
          }
        }
        expect(tester.takeException(), isNull);
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
        matching: find.byType(CoverArtworkFrame),
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
      expect(progressRect.top - coverRect.bottom, greaterThan(5));
      final leftRect = tester.getRect(
        find.byKey(const ValueKey('session_detail_cover_area')),
      );
      expect(progressRect.center.dx, closeTo(leftRect.center.dx, 0.5));
      expect(progressRect.width, closeTo(leftRect.width * 0.8, 0.5));

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

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'detail feature indicators fade independently (reduced: $reducedMotion)',
      (tester) async {
        tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reducedMotion);
        addTearDown(
          tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final result = await _pumpSubtitleDetail(
          tester: tester,
          subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
          initialPosition: Duration.zero,
          physicalSize: defaultTargetPlatform == TargetPlatform.windows
              ? const Size(3840, 2400)
              : const Size(1080, 2400),
        );
        final playback = result.fixture.playback;
        final sessionId = result.session.id;
        await playback.setSessionChannelSwap(sessionId, true);
        await tester.pumpAndSettle();

        final speed = find.byIcon(Icons.speed_rounded);
        final swap = find.byIcon(Icons.swap_horiz_rounded);
        final swapBounds = tester.getRect(swap);
        double opacity(IconData icon) => tester
            .widget<Opacity>(
              find.descendant(
                of: find.byKey(ValueKey(icon)),
                matching: find.byType(Opacity),
              ),
            )
            .opacity;
        expect(speed, findsNothing);
        await playback.setSessionSpeed(sessionId, 0.75, persist: false);
        await tester.pump();
        if (!reducedMotion) {
          await tester.pump(kAppFadeDuration ~/ 2);
          expect(opacity(Icons.speed_rounded), inExclusiveRange(0, 1));
          expect(opacity(Icons.swap_horiz_rounded), 1);
        }
        expect(speed, findsOneWidget);
        expect(tester.getRect(swap), swapBounds);
        await tester.pumpAndSettle();

        await playback.setSessionSpeed(sessionId, 1, persist: false);
        await tester.pump();
        if (!reducedMotion) {
          await tester.pump(kAppFadeDuration ~/ 2);
          final fadeOut = opacity(Icons.speed_rounded);
          expect(fadeOut, inExclusiveRange(0, 1));
          await playback.setSessionSpeed(sessionId, 0.75, persist: false);
          await tester.pump();
          expect(opacity(Icons.speed_rounded), closeTo(fadeOut, 0.001));
          await tester.pumpAndSettle();
          expect(opacity(Icons.speed_rounded), 1);
          await playback.setSessionSpeed(sessionId, 1, persist: false);
          await tester.pumpAndSettle();
        }
        expect(speed, findsNothing);
        expect(tester.getRect(swap), swapBounds);
        // Let the debounced playback notification finish in reduced motion.
        await tester.pump(kAppFadeDuration);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final (platform, screenSize, isPortrait, showActions) in [
    (TargetPlatform.android, const Size(1080, 2400), true, true),
    (TargetPlatform.android, const Size(2400, 1080), false, false),
    (TargetPlatform.android, const Size(3000, 2100), false, true),
    (TargetPlatform.windows, const Size(3840, 2400), false, true),
  ]) {
    for (final topInset in [0.0, 24.0]) {
      testWidgets('detail cover clears the close button on ${platform.name} '
          '${screenSize.width} with top inset $topInset', (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          notificationsChannel,
          (_) async => <String, Object?>{'ok': true, 'value': null},
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(notificationsChannel, null),
        );
        debugDefaultTargetPlatformOverride = platform;
        try {
          tester.view.padding = FakeViewPadding(top: topInset * 3);
          tester.view.viewPadding = FakeViewPadding(top: topInset * 3);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          final result = await _pumpSubtitleDetail(
            tester: tester,
            subtitleTrack: SubtitleTrack(
              sourcePath: 'empty.srt',
              cues: const [],
            ),
            initialPosition: Duration.zero,
            physicalSize: screenSize,
          );
          await result.fixture.playback.setSessionSpeed(
            result.session.id,
            1.25,
            persist: false,
          );
          await tester.pumpAndSettle();

          final button = find.byKey(
            const ValueKey('session_detail_close_button'),
          );
          expect(button, findsOneWidget);
          expect(
            find.ancestor(
              of: button,
              matching: find.byType(HeaderFloatingButton),
            ),
            findsNothing,
          );
          final buttonRect = tester.getRect(button);
          expect(
            buttonRect.left,
            platform == TargetPlatform.windows ? AppSpacing.xl : 16,
          );
          final originalTop =
              (platform == TargetPlatform.windows
                  ? WindowsWindowTitleBar.height
                  : isPortrait
                  ? 0
                  : topInset) +
              6;
          expect(
            buttonRect.top,
            !isPortrait &&
                    showActions &&
                    platform != TargetPlatform.windows &&
                    originalTop < 48
                ? 48
                : originalTop,
          );
          expect(buttonRect.size, const Size.square(38));
          expect(
            tester.getRect(find.byType(SessionDetailContent)).top,
            isPortrait ? buttonRect.bottom + 8 : 0,
          );
          final sleep = find.byKey(
            const ValueKey('session_detail_sleep_button'),
          );
          final timer = find.byKey(
            const ValueKey('session_detail_timer_button'),
          );
          if (showActions) {
            for (final action in [
              if (platform != TargetPlatform.windows) sleep,
              timer,
            ]) {
              expect(action, findsOneWidget);
              final surface = find.ancestor(
                of: action,
                matching: find.byType(HeaderFloatingButton),
              );
              expect(surface, findsNothing);
              expect(tester.getSize(action), const Size.square(38));
              expect(tester.getRect(action).top, buttonRect.top);
              expect(
                tester
                    .widget<IconButton>(action)
                    .style!
                    .backgroundColor!
                    .resolve({}),
                Colors.transparent,
              );
              expect(tester.widget<IconButton>(action).iconSize, 20);
            }
            final status = find.byIcon(Icons.speed_rounded);
            expect(tester.getSize(status), Size.square(isPortrait ? 18 : 20));
            if (isPortrait) {
              final coverRect = tester.getRect(
                find.byKey(
                  const ValueKey('session_detail_cover_subtitle-session'),
                ),
              );
              final statusRect = tester.getRect(status);
              expect(statusRect.top, closeTo(coverRect.top + 8, 1));
              expect(statusRect.right, lessThan(coverRect.right));
              expect(statusRect.left, greaterThan(coverRect.center.dx));
              expect(statusRect.bottom, lessThan(coverRect.bottom));
              expect(statusRect.top, greaterThan(buttonRect.bottom));
              expect(
                tester.getRect(find.byType(SessionDetailContent)).top,
                closeTo(buttonRect.bottom + 8, 0.01),
              );
            } else {
              expect(tester.getRect(status).bottom, lessThan(buttonRect.top));
            }
            if (!isPortrait) {
              final title = find.byKey(
                const ValueKey('title_marquee_subtitle-session'),
              );
              expect(tester.getRect(title).top, greaterThan(buttonRect.bottom));
            }
            if (platform == TargetPlatform.windows) {
              expect(sleep, findsNothing);
              final mouse = await tester.createGesture(
                kind: PointerDeviceKind.mouse,
              );
              await mouse.addPointer(location: Offset.zero);
              await mouse.moveTo(tester.getCenter(timer));
              await tester.pumpAndSettle();
              expect(
                find.descendant(
                  of: timer,
                  matching: find.byWidgetPredicate((widget) {
                    if (widget is! DecoratedBox) return false;
                    final decoration = widget.decoration;
                    return decoration is ShapeDecoration &&
                        decoration.shape is CircleBorder &&
                        (decoration.color?.a ?? 0) > 0;
                  }),
                ),
                findsNothing,
              );
              final hoverScale = tester
                  .widgetList<Transform>(
                    find.descendant(
                      of: timer,
                      matching: find.byType(Transform),
                    ),
                  )
                  .where((transform) => !transform.transformHitTests)
                  .fold<double>(1.0, (scale, t) => scale * t.transform.entry(0, 0));
              expect(hoverScale, 1.0);
              await mouse.removePointer();
              await tester.pump();
            } else {
              expect(tester.widget<IconButton>(sleep).onPressed, isNull);
              expect(
                tester.getRect(timer).right,
                lessThan(tester.getRect(sleep).left),
              );
            }
            if (topInset == 0) {
              await tester.tap(timer);
              await tester.pumpAndSettle();
              expect(find.byType(TimerTab), findsOneWidget);
              await tester.tap(
                find.text(
                  result.fixture.languageProvider.tr('confirm_start_now'),
                ),
              );
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 400));
              expect(result.fixture.timer.state.active, isTrue);
              Navigator.of(tester.element(find.byType(TimerTab))).pop();
              await tester.pumpAndSettle();
              final capsule = find.byKey(
                const ValueKey('session_detail_timer_capsule'),
              );
              expect(timer, findsNothing);
              expect(capsule, findsOneWidget);
              expect(
                find.descendant(
                  of: capsule,
                  matching: find.byType(HeaderFloatingSurface),
                ),
                findsNothing,
              );
              final countdownSurface = tester.widget<Material>(
                find.descendant(of: capsule, matching: find.byType(Material)),
              );
              expect(countdownSurface.color, Colors.transparent);
              final countdownColor = Theme.of(
                tester.element(capsule),
              ).colorScheme.primary;
              expect(
                tester
                    .widget<Icon>(
                      find.descendant(of: capsule, matching: find.byType(Icon)),
                    )
                    .color,
                countdownColor,
              );
              final countdownText = tester.widget<Text>(
                find.descendant(of: capsule, matching: find.byType(Text)),
              );
              expect(countdownText.data, isNotEmpty);
              expect(countdownText.style!.color, countdownColor);
              expect(
                tester.widget<TimerCountdownCapsule>(capsule).remaining,
                result.fixture.timer.state.remaining,
              );
              if (platform != TargetPlatform.windows) {
                expect(
                  tester.getRect(capsule).right,
                  lessThan(tester.getRect(sleep).left),
                );
              }
              await tester.tap(capsule);
              await tester.pumpAndSettle();
              expect(
                tester
                    .widget<TimerTab>(find.byType(TimerTab))
                    .initialCompactDetail,
                isTrue,
              );
              Navigator.of(tester.element(find.byType(TimerTab))).pop();
              result.fixture.timer.cancelTimer();
              await tester.pumpAndSettle();
              expect(capsule, findsNothing);
              expect(timer, findsOneWidget);
              if (platform != TargetPlatform.windows) {
                result.session.setOptimisticState(playing: true);
                result.fixture.playbackService.syncSlice(
                  activeSessions: [result.session],
                  playingSessionCount: 1,
                  focusedSessionId: result.session.id,
                  coverGeneration: result.coverCache.generation,
                  isInitialized: true,
                );
                await tester.pumpAndSettle();
                await tester.tap(sleep);
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 400));
                expect(find.byType(BedtimeCanvasPage), findsOneWidget);
                Navigator.of(
                  tester.element(find.byType(BedtimeCanvasPage)),
                ).pop();
                result.session.setOptimisticState(playing: false);
                result.fixture.playbackService.syncSlice(
                  activeSessions: [result.session],
                  playingSessionCount: 0,
                  focusedSessionId: result.session.id,
                  coverGeneration: result.coverCache.generation,
                  isInitialized: true,
                );
                await tester.pumpAndSettle();
              }
            }
          } else {
            expect(sleep, findsNothing);
            expect(timer, findsNothing);
          }
          final arrow = find.descendant(
            of: button,
            matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
          );
          expect(arrow, findsOneWidget);
          expect(IconTheme.of(tester.element(arrow)).color, Colors.white);
          expect(IconTheme.of(tester.element(arrow)).size, 32);
          final buttonStyle = tester
              .widget<IconButton>(
                find.descendant(of: button, matching: find.byType(IconButton)),
              )
              .style!;
          expect(
            buttonStyle.overlayColor!.resolve({WidgetState.hovered}),
            Colors.transparent,
          );
          final pointer = await tester.createGesture(
            kind: ui.PointerDeviceKind.mouse,
          );
          await pointer.addPointer(location: Offset.zero);
          await pointer.moveTo(buttonRect.center);
          await tester.pumpAndSettle();
          final closeIconButton = tester.widget<IconButton>(
            find.descendant(of: button, matching: find.byType(IconButton)),
          );
          final closeMaterial = tester.widget<Material>(
            find.descendant(of: button, matching: find.byType(Material)).last,
          );
          expect(IconTheme.of(tester.element(arrow)).color, Colors.white);
          expect(
            closeMaterial.color,
            Theme.of(tester.element(button)).platform == TargetPlatform.windows
                ? Colors.black.withValues(alpha: 0.32)
                : Colors.transparent,
          );
          expect(
            closeIconButton.style!.shape!.resolve(const {}),
            isA<CircleBorder>(),
          );
          final iconScale = tester
              .widgetList<Transform>(
                find.ancestor(of: arrow, matching: find.byType(Transform)),
              )
              .where((transform) => !transform.transformHitTests)
              .fold<double>(1.0, (scale, t) => scale * t.transform.entry(0, 0));
          expect(iconScale, 1.0);
          await pointer.removePointer();
          await tester.pumpAndSettle();
          expect(IconTheme.of(tester.element(arrow)).color, Colors.white);
          expect(
            tester
                .widget<Material>(
                  find
                      .descendant(of: button, matching: find.byType(Material))
                      .last,
                )
                .color,
            Colors.transparent,
          );
          if (isPortrait) {
            final artwork = find.byKey(
              const ValueKey('artwork_subtitle-session'),
            );
            expect(
              tester.getRect(artwork).top,
              greaterThanOrEqualTo(buttonRect.bottom),
            );
          }
          if (!isPortrait) {
            final titleRect = tester.getRect(
              find.byKey(const ValueKey('title_marquee_subtitle-session')),
            );
            await tester.tap(find.byIcon(Icons.tune_rounded));
            await tester.pumpAndSettle();
            final menuHeaderRect = tester.getRect(
              find.byType(SegmentPanelPageHeader),
            );
            expect(menuHeaderRect.top, closeTo(titleRect.top, 0.5));
            await tester.tap(
              find.byKey(const ValueKey<String>('close_console_panel')),
            );
            await tester.pumpAndSettle();
          }
          await tester.tapAt(buttonRect.topLeft + const Offset(1, 1));
          await tester.pumpAndSettle();
          expect(find.byType(SessionDetailPage), findsNothing);
          expect(find.byType(PlaylistTab), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
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

      expect(capsuleRect.size, const Size(282, 46));
      expect(loopRect.width, 46.0);
      expect(loopRect.height, 40.0);
      expect(detailRect.width, 46.0);
      expect(detailRect.height, 40.0);

      // End buttons share semicircle centers (23px from left/right, centered
      // vertically) with 3px concentric inset from the 46px outer capsule.
      expect(loopRect.left + 20, closeTo(capsuleRect.left + 23, 0.5));
      expect(detailRect.right - 20, closeTo(capsuleRect.right - 23, 0.5));
      expect(loopRect.top, closeTo(capsuleRect.top + 3, 0.5));
      expect(loopRect.bottom, closeTo(capsuleRect.bottom - 3, 0.5));
      final buttons = find.descendant(
        of: capsuleFinder,
        matching: find.byType(IconButton),
      );
      expect(buttons, findsNWidgets(6));
      for (var index = 1; index < 6; index++) {
        expect(
          tester.getRect(buttons.at(index)).left -
              tester.getRect(buttons.at(index - 1)).right,
          closeTo(0, 0.5),
        );
      }

      await tester.tapAt(loopRect.topLeft + const Offset(2, 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('loop_mode_confirm')), findsNothing);

      await tester.tapAt(detailRect.topRight + const Offset(-2, 2));
      await tester.pump();
      expect(find.byType(WorkDetailPage), findsNothing);

      await tester.tapAt(detailRect.centerRight - const Offset(4, 0));
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
      final themeProvider = ThemeProvider(
        loadPersistedState: false,
        preferenceWriter: (_, _) async => true,
      );
      final pumped = await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
        physicalSize: const Size(2400, 1080),
        themeProvider: themeProvider,
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

      final tuneButtonFinder = find.byIcon(Icons.tune_rounded);
      expect(tuneButtonFinder, findsOneWidget);

      final cover = find.byKey(const ValueKey('session_detail_cover_area'));
      final coverRect = tester.getRect(cover);
      final menu = find.byKey(const ValueKey('segments_landscape'));
      double menuOpacity() => tester
          .widget<FadeTransition>(
            find
                .ancestor(of: menu, matching: find.byType(FadeTransition))
                .first,
          )
          .opacity
          .value;

      await tester.tap(tuneButtonFinder);
      await tester.pump();
      expect(menuOpacity(), 0);
      expect(cover, findsNothing);
      await tester.pump(kAppFadeDuration ~/ 2);
      expect(menuOpacity(), allOf(greaterThan(0), lessThan(1)));
      await tester.pump(kAppFadeDuration ~/ 2 - const Duration(milliseconds: 1));
      expect(menuOpacity(), lessThan(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(menuOpacity(), 1);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('segments_landscape')), findsOneWidget);
      expect(cover, findsNothing);
      final titleRect = tester.getRect(
        find.byKey(const ValueKey('title_marquee_subtitle-session')),
      );
      expect(
        titleRect.top,
        defaultTargetPlatform == TargetPlatform.android
            ? closeTo(coverRect.top, 0.5)
            : lessThan(coverRect.top),
      );
      expect(
        tester.getRect(find.byType(TransportPlaybackControlPanel)).bottom,
        closeTo(
          tester
                  .getRect(
                    find.byKey(
                      const ValueKey('session_detail_landscape_layout'),
                    ),
                  )
                  .top +
              progressRect.bottom,
          0.5,
        ),
      );
      expect(closeButton, findsOneWidget);
      final headerRect = tester.getRect(find.byType(SegmentPanelPageHeader));
      final surface = find.byKey(
        const ValueKey<String>('playback_expanded_control_panel_surface'),
      );
      final surfaceRect = tester.getRect(surface);
      final decoration =
          tester.widget<DecoratedBox>(surface).decoration as BoxDecoration;
      final colors = Theme.of(tester.element(surface)).colorScheme;
      final panelGlass = find.ancestor(
        of: surface,
        matching: find.byType(AppGlassSurface),
      );
      final panelBlur = find.ancestor(
        of: surface,
        matching: find.byType(BackdropFilter),
      );
      expect(panelBlur, findsNothing);
      expect(
        tester.widget<AppGlassSurface>(panelGlass).backgroundColor,
        colors.surfaceContainerHigh.withValues(alpha: 0.9),
      );
      expect(decoration.color, isNull);
      expect(
        decoration.border,
        Border.all(color: colors.outlineVariant.withValues(alpha: 0.55)),
      );
      expect(headerRect.top, closeTo(surfaceRect.top, 1));
      expect(tester.getRect(find.byType(SessionProgressBar)), progressRect);
      expect(surfaceRect.top, closeTo(titleRect.top, 0.5));
      expect(surfaceRect.left, closeTo(progressRect.left, 0.5));
      expect(surfaceRect.right, closeTo(progressRect.right, 0.5));
      final primaryRect = tester.getRect(
        find.byKey(const ValueKey('session_detail_primary_controls')),
      );
      expect(primaryRect.top - surfaceRect.bottom, closeTo(32, 0.5));
      expect(surfaceRect.contains(headerRect.center), isTrue);
      final menuClip = tester.widget<ClipRRect>(
        find.ancestor(of: surface, matching: find.byType(ClipRRect)).first,
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
      expect(tester.getRect(equalizerList).top, closeTo(headerRect.bottom, 1));
      final scrollPosition = tester
          .state<ScrollableState>(equalizerScroll)
          .position;
      expect(scrollPosition.pixels, 0);
      await tester.drag(equalizerList, const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(scrollPosition.pixels, greaterThan(0));
      expect(tester.getRect(find.byType(SegmentPanelPageHeader)), headerRect);
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

      expect(await themeProvider.setBarGlassEnabled(true), isTrue);
      await tester.pumpAndSettle();
      expect(tester.widget<BackdropFilter>(panelBlur).enabled, isTrue);
      expect(tester.getRect(panelBlur), surfaceRect);
      expect(tester.getRect(find.byType(SegmentPanelPageHeader)), headerRect);

      final menuCloseButton = find.byKey(
        const ValueKey<String>('close_console_panel'),
      );
      expect(
        tester.getCenter(menuCloseButton).dx,
        greaterThan(headerRect.center.dx),
      );
      await tester.tap(menuCloseButton);
      await tester.pump();
      expect(menuOpacity(), 1);
      expect(tester.getRect(cover), coverRect);
      await tester.pump(const Duration(milliseconds: 150));
      expect(menuOpacity(), allOf(greaterThan(0), lessThan(1)));
      await tester.pump(const Duration(milliseconds: 149));
      expect(menu, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
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
    'landscape session detail has five equal buttons above the left progress bar',
    (tester) async {
      await _pumpSubtitleDetail(
        tester: tester,
        subtitleTrack: SubtitleTrack(sourcePath: 'empty.srt', cues: const []),
        initialPosition: Duration.zero,
        physicalSize: const Size(2400, 1080),
      );

      final secondaryControlsFinder = find.byKey(
        const ValueKey('playback_secondary_controls'),
      );
      expect(secondaryControlsFinder, findsOneWidget);

      final prevButtonFinder = find.byIcon(Icons.skip_previous_rounded);
      final nextButtonFinder = find.byIcon(Icons.skip_next_rounded);
      expect(prevButtonFinder, findsOneWidget);
      expect(nextButtonFinder, findsOneWidget);

      final primaryRect = tester.getRect(
        find.byKey(const ValueKey('session_detail_primary_controls')),
      );
      final prevRect = tester.getRect(prevButtonFinder);
      final nextRect = tester.getRect(nextButtonFinder);

      expect(prevRect.left, greaterThanOrEqualTo(primaryRect.left));
      expect(nextRect.right, lessThanOrEqualTo(primaryRect.right));
      final buttons = find.descendant(
        of: find.byKey(const ValueKey('session_detail_primary_controls')),
        matching: find.byType(IconButton),
      );
      expect(buttons, findsNWidgets(5));
      final buttonRects = buttons
          .evaluate()
          .map((element) => tester.getRect(find.byWidget(element.widget)))
          .toList();
      for (final rect in buttonRects) {
        expect(rect.width, closeTo(buttonRects.first.width, 0.001));
        expect(rect.height, closeTo(buttonRects.first.height, 0.001));
        expect(rect.center.dy, closeTo(buttonRects.first.center.dy, 0.001));
      }
      final progress = find.byType(SessionProgressBar);
      final progressRect = tester.getRect(progress);
      expect(primaryRect.bottom, lessThan(progressRect.top));
      final sliderRect = tester.getRect(
        find.descendant(of: progress, matching: find.byType(Slider)),
      );
      final times = find.descendant(
        of: progress,
        matching: find.byType(TimecodeLabel),
      );
      expect(times, findsNWidgets(2));
      final elapsed = tester.getRect(times.first);
      final remaining = tester.getRect(times.last);
      expect(elapsed.right, lessThan(sliderRect.left));
      expect(remaining.left, greaterThan(sliderRect.right));
      expect(elapsed.center.dy, closeTo(sliderRect.center.dy, 0.5));
      expect(remaining.center.dy, closeTo(sliderRect.center.dy, 0.5));
      expect(progressRect.top, closeTo(primaryRect.bottom + 4, 0.5));
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
    'playlist rows match library cover corners and ignore horizontal drags',
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
      fixture.runtimeGraph.library.addTracks(<MusicTrack>[
        track,
      ], persist: false);
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

      expect(
        find.descendant(
          of: swipeCardFinder,
          matching: find.byTooltip(fixture.languageProvider.tr('more_actions')),
        ),
        findsNothing,
      );
      final cardRect = tester.getRect(swipeCardFinder);
      expect(cardRect.height, playlistRowHeight);
      const coverRadius = BorderRadius.all(
        Radius.circular(LibraryLikeCardMetrics.coverRadius),
      );
      expect(
        swipeCard.shape,
        const RoundedRectangleBorder(borderRadius: coverRadius),
      );
      final clip = find.descendant(
        of: swipeCardFinder,
        matching: find.byWidgetPredicate(
          (widget) => widget is ClipRRect && widget.borderRadius == coverRadius,
        ),
      );
      expect(clip, findsOneWidget);
      final content = find.byKey(
        ValueKey<String>('playlist_card_content_${session.id}'),
      );
      final initialRect = tester.getRect(content);
      for (final dx in [-180.0, 180.0]) {
        await tester.dragFrom(cardRect.center, Offset(dx, 0));
        await tester.pumpAndSettle();
        expect(tester.getRect(content), initialRect);
        expect(
          find.byTooltip(fixture.languageProvider.tr('pin_to_top')),
          findsNothing,
        );
        expect(
          find.byTooltip(fixture.languageProvider.tr('remove_audio')),
          findsNothing,
        );
      }

      // This point is inside the rounded row but outside the old capsule.
      await tester.longPressAt(cardRect.topLeft + const Offset(4, 12));
      await pumpFiniteTransitions(tester);
      expect(
        find.byKey(ValueKey('playlist_selection_indicator_${session.id}')),
        findsOneWidget,
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  test('formatSpeedValue formats 1, 2, and 3 to two decimal places', () {
    expect(formatSpeedValue(1.0), '1.00x');
    expect(formatSpeedValue(2.0), '2.00x');
    expect(formatSpeedValue(3.0), '3.00x');
    expect(formatSpeedValue(1.25), '1.25x');
    expect(formatSpeedValue(0.75), '0.75x');
  });

  testWidgets(
    'playlist item work title scrolls marquee on hover in Windows',
    (tester) async {
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

      tester.view.physicalSize = const Size(360, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const longWorkTitle =
          'Very Long Work Title That Exceeds The Maximum Allowed Width For A Playlist Item Card In Desktop';
      final track = testMusicTrack(
        name: 'Track 1',
        path: '/library/$longWorkTitle/track1.mp3',
        groupKey: '/library/$longWorkTitle',
        groupTitle: longWorkTitle,
      );
      runtimeGraph.library.addTracks(<MusicTrack>[track], persist: false);
      final session = PlaybackSession(
        id: 'session-hover-test',
        currentTrackPath: track.path,
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.ready),
      );
      addTearDown(session.shutdown);
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
          child: const PlaylistTab(),
        ),
      );
      await tester.pumpAndSettle();

      final card = find.byType(SessionListCard);
      expect(card, findsOneWidget);

      final horizontalScroll = find.descendant(
        of: card,
        matching: find.byType(HorizontalEdgeFadeScroll),
      );

      if (defaultTargetPlatform == TargetPlatform.windows) {
        expect(horizontalScroll, findsOneWidget);
        final scrollable = find.descendant(
          of: horizontalScroll,
          matching: find.byType(Scrollable),
        );
        expect(tester.state<ScrollableState>(scrollable).position.pixels, 0.0);

        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: const Offset(800, 800));
        await mouse.moveTo(tester.getCenter(card));
        await tester.pump();
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(
          tester.state<ScrollableState>(scrollable).position.pixels,
          greaterThan(0.0),
        );

        await mouse.moveTo(const Offset(800, 800));
        await tester.pumpAndSettle();
        expect(tester.state<ScrollableState>(scrollable).position.pixels, 0.0);
      } else {
        expect(horizontalScroll, findsNothing);
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
