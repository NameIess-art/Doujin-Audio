import 'package:doujin_audio/core/widgets/file_tree_row.dart';
import 'package:doujin_audio/core/widgets/shimmer_loading.dart';
import 'package:doujin_audio/app/application/browse_page_state_store.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/cover_image_retention.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/unified_popup_menu.dart';
import 'package:doujin_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entries.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entry_tile.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/library/presentation/audio_detail_sheet.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/presentation/work_image_viewer_page.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_breadcrumbs.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_store.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/library_state_models.dart';
import 'package:doujin_audio/features/library/application/library_organizer.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'support/app_runtime_test_fixture.dart';
import 'support/test_playback_commands.dart';
import 'support/test_persistence_repository.dart';

// compute uses a real isolate; advance real I/O alongside simulated frames.
Future<void> _settleDetail(WidgetTester tester) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (attempt >= 4 &&
        !tester.binding.hasScheduledFrame &&
        find
            .byKey(const ValueKey('work_detail_entries_skeleton'))
            .evaluate()
            .isEmpty) {
      break;
    }
  }
  if (find
      .byKey(const ValueKey('work_detail_entries_skeleton'))
      .evaluate()
      .isEmpty) {
    await tester.pumpAndSettle();
  }
}

Future<void> _prewarmDirectory(
  AppRuntimeWidgetTestFixture fixture,
  String folder, [
  WorkTextService? texts,
]) async {
  await WorkDirectoryInput.local(
    root: fixture.library.resolvedLibraryFolderTree(folder),
    texts: texts?.resolvedWorkTextFiles(folder) ?? const [],
    images: texts?.resolvedWorkImageFiles(folder) ?? const [],
    folderPath: folder,
  ).load();
}

Future<void> _drainDetailFixture(
  WidgetTester tester,
  AppRuntimeWidgetTestFixture fixture,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var completed = false;
  final pending = Future.wait<void>([
    fixture.library.coverArtworkCacheService.initialize(),
    fixture.library.detailCacheService.suspendAndWait(),
  ]).then((_) => fixture.library.flushPendingPersistence()).then((_) {
    completed = true;
  });
  // SQLite's shared queue can still depend on this test's fake-async zone.
  // Drain it while both its simulated clock and the real I/O loop can advance.
  for (var tick = 0; tick < 1000 && !completed; tick++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 5));
  }
  expect(completed, isTrue, reason: 'Work detail database work did not drain');
  await pending;
  await tester.pump(UiInteractionCoordinator.instance.idleDelay);
}

final _detailFixtures = <AppRuntimeWidgetTestFixture>[];

void _detailTestWidgets(
  String description,
  WidgetTesterCallback callback, {
  TestVariant<Object?> variant = const DefaultTestVariant(),
}) {
  testWidgets(description, (tester) async {
    // The 4:3 cover leaves metadata and the first lazy rows below 600 px.
    // Tests that verify geometry explicitly choose their own viewport.
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    _detailFixtures.clear();
    try {
      await callback(tester);
    } finally {
      // A failed assertion must also release SQLite while its original
      // fake-async zone is still alive, before the next test uses runAsync.
      for (final fixture in _detailFixtures) {
        await _drainDetailFixture(tester, fixture);
      }
      _detailFixtures.clear();
      await tester.binding.setSurfaceSize(null);
    }
  }, variant: variant);
}

class _CountingDetailRepository extends TestPersistenceRepository {
  int detailRequests = 0;

  @override
  Future<AudioDetail?> load(AudioDetailTarget target) {
    detailRequests++;
    return super.load(target);
  }
}

class _DeferredDetailAsmrController extends ChangeNotifier
    implements AsmrLibraryController {
  _DeferredDetailAsmrController(this.tree, {required this.cached});
  final List<AsmrTrackFile> tree;
  bool cached;
  int cacheReads = 0;
  int requests = 0;

  @override
  List<AsmrTrackFile>? trackTreeFor(String workId) {
    cacheReads++;
    return cached ? tree : null;
  }

  @override
  Future<void> initializeForVisiblePage({
    AsmrContentLanguage? defaultLanguage,
  }) async {}

  @override
  Future<List<AsmrTrackFile>> ensureTrackTree(
    AsmrWork work, {
    bool forceRefresh = false,
  }) async {
    requests++;
    cached = true;
    return tree;
  }

  @override
  bool isFavorite(String workId) => false;

  @override
  AsmrTrackTreeViewState trackTreeViewState(String workId) =>
      AsmrTrackTreeViewState(
        workKey: workId,
        tree: cached ? tree : null,
        visibleTree: cached ? tree : null,
        isLoading: false,
        isRefreshing: false,
        isStale: false,
        operationError: null,
        revision: 0,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WorkDetailAsmrMetadataService extends AsmrMetadataService {
  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.zh,
  }) async {
    return DlsiteMetadata(
      rjCode: rjCode,
      workTitle: 'Fetched work title',
      circleName: 'Fetched circle',
      voiceActors: const <String>[],
      tags: const <String>[],
    );
  }
}

class _WorkDetailFileGateway extends Fake implements FileCachePlatformGateway {
  _WorkDetailFileGateway(this.textFile);

  final File textFile;

  @override
  Future<List<Map<String, String>>> discoverWorkTexts(String folderPath) async {
    return [
      {'name': 'notes.txt', 'relativePath': 'notes.txt', 'path': textFile.path},
    ];
  }
}

class _NestedWorkDetailFileGateway extends Fake
    implements FileCachePlatformGateway {
  _NestedWorkDetailFileGateway(this.entries);

  final List<Map<String, String>> entries;

  @override
  Future<List<Map<String, String>>> discoverWorkTexts(String folderPath) async {
    return entries;
  }
}

class _PendingWorkDetailFileGateway extends Fake
    implements FileCachePlatformGateway {
  final texts = Completer<List<Map<String, String>>>();

  @override
  Future<List<Map<String, String>>> discoverWorkTexts(String folderPath) =>
      texts.future;
}

class _ControlledWorkDetailCoverService extends CoverArtworkCacheService {
  _ControlledWorkDetailCoverService() : super(libraryService: LibraryService());

  String? cachedCover;
  final images = Completer<List<String>>();
  final cover = Completer<String?>();
  int imageRequests = 0;
  int coverRequests = 0;
  int remoteCoverRequests = 0;

  @override
  String? resolvedForRemoteCover(String url) => cachedCover;

  @override
  Future<String?> futureForRemoteCover(String url) {
    remoteCoverRequests++;
    return cover.future;
  }

  @override
  String? resolvedForFolder(String folderPath) => cachedCover;

  @override
  Future<String?> futureForFolder(String folderPath) {
    coverRequests++;
    return cover.future;
  }

  @override
  Future<List<CoverImageReference>> discoverCoverImageReferencesInFolder(
    String folderPath, {
    bool refresh = false,
  }) {
    imageRequests++;
    return images.future.then(
      (paths) => paths
          .map(
            (path) => CoverImageReference(displayPath: path, sourcePath: path),
          )
          .toList(),
    );
  }

  @override
  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
    bool includeVideoFrames = true,
    bool includeEmbeddedCovers = true,
    bool propagateFailure = false,
  }) {
    expect(includeVideoFrames, isFalse);
    expect(includeEmbeddedCovers, isFalse);
    imageRequests++;
    return images.future;
  }
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

  for (final remote in [false, true]) {
    _detailTestWidgets(
      'covering work details retains loaded rows, remote=$remote',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(450, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final interaction = UiInteractionCoordinator.instance;
        interaction.resetForTest();
        addTearDown(interaction.resetForTest);
        final covers = _ControlledWorkDetailCoverService()
          ..images.complete([])
          ..cover.complete(null);
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: covers,
          asmrMetadataService: _WorkDetailAsmrMetadataService(),
        );
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);
        const folder = 'C:/works/route-cache';
        final target = AudioDetailTarget.libraryRootFolder(folder);
        final tree = List.generate(
          30,
          (index) => AsmrTrackFile.fromJson({
            'type': 'audio',
            'title': 'Audio $index',
            'mediaStreamUrl': 'https://example.test/$index.mp3',
          }),
        );
        final controller = _DeferredDetailAsmrController(tree, cached: true);
        addTearDown(controller.dispose);
        await tester.runAsync(() async {
          if (remote) {
            await WorkDirectoryInput.asmr(tree).load();
          } else {
            fixture.library.addWatchedFolder(folder, notify: false);
            fixture.library.addTracks(
              List.generate(
                30,
                (index) => testMusicTrack(
                  name: 'Track $index',
                  path: '$folder/$index.mp3',
                  groupKey: folder,
                  groupTitle: 'Work',
                ),
              ),
              persist: false,
            );
            await fixture.library.flushPendingPersistence();
            await fixture.library.loadLibraryFolderTree(folder);
            await _prewarmDirectory(fixture, folder);
          }
        });
        await tester.pumpWidget(
          fixture.build(
            const Text('home'),
            overrides: [
              if (remote)
                asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        final navigator = Navigator.of(tester.element(find.text('home')));
        unawaited(
          navigator.push<void>(
            buildAppPageRoute<void>(
              context: navigator.context,
              child: remote
                  ? WorkDetailPage.forAsmr(
                      work: AsmrWork.fromJson(const {'id': 123456, 'title': 'Work'}),
                    )
                  : WorkDetailPage.forLocal(
                      target: target,
                      initialDetail: AudioDetail.empty(target),
                    ),
            ),
          ),
        );
        await tester.pump();
        await _settleDetail(tester);
        interaction.finishInteractionsForTest();
        await tester.pump(interaction.idleDelay + const Duration(seconds: 1));
        await _settleDetail(tester);
        // Cached rows precede the independent SQLite and file discoveries.
        for (var pass = 0; pass < 3; pass++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(seconds: 1));
          await _settleDetail(tester);
        }
        final rows = tester.widget<SliverList>(find.byType(SliverList));
        for (var round = 0; round < 2; round++) {
          unawaited(
            navigator.push<void>(
              buildAppPageRoute<void>(
                context: navigator.context,
                child: const Scaffold(body: Text('cover')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget(find.byType(SliverList, skipOffstage: false)),
            same(rows),
          );
          navigator.pop();
          await tester.pumpAndSettle();
          expect(tester.widget(find.byType(SliverList)), same(rows));
        }
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await _settleDetail(tester);
        expect(
          Theme.of(tester.element(find.byType(WorkDetailPage))).brightness,
          Brightness.dark,
        );
        final themedRows = tester.widget<SliverList>(find.byType(SliverList));
        await tester.binding.setSurfaceSize(const Size(500, 800));
        await _settleDetail(tester);
        expect(tester.widget(find.byType(SliverList)), isNot(same(themedRows)));
        expect(find.byType(WorkDetailEntryTile), findsWidgets);
        await tester.pumpWidget(const SizedBox.shrink());
        await _settleDetail(tester);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  _detailTestWidgets(
    'work scrolling defers discovered files and reuses row menus',
    (tester) async {
      final interaction = UiInteractionCoordinator.instance;
      interaction.resetForTest();
      addTearDown(interaction.resetForTest);
      final covers = _ControlledWorkDetailCoverService()
        ..images.complete([])
        ..cover.complete(null);
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: covers,
      );
      _detailFixtures.add(fixture);
      addTearDown(fixture.dispose);
      const folder = 'C:/works/scroll-discovery';
      final target = AudioDetailTarget.libraryRootFolder(folder);
      fixture.library.addWatchedFolder(folder, notify: false);
      fixture.library.addTracks(
        List.generate(
          80,
          (index) => MusicTrack(
            path: '$folder/track$index.mp3',
            displayName: 'track$index.mp3',
            groupKey: folder,
            groupTitle: 'Scroll discovery',
            groupSubtitle: '',
            isSingle: false,
          ),
        ),
        persist: false,
      );
      await tester.runAsync(() async {
        await fixture.library.loadAudioDetail(target);
        await fixture.library.loadLibraryFolderTree(folder);
        await _prewarmDirectory(fixture, folder);
      });
      final images = Completer<List<CoverImageReference>>();
      final textService = WorkTextService(
        discoverImages: (_) => images.future,
        platformGateway: _NestedWorkDetailFileGateway([]),
      );
      addTearDown(textService.dispose);
      await tester.pumpWidget(
        fixture.build(
          WorkDetailPage.forLocal(target: target),
          overrides: [workTextServiceProvider.overrideWithValue(textService)],
        ),
      );
      await _settleDetail(tester);
      final scroll = find.byType(CustomScrollView);
      final controller = tester.widget<CustomScrollView>(scroll).controller!;
      final gesture = await tester.startGesture(tester.getCenter(scroll));
      await gesture.moveBy(const Offset(0, -160));
      await tester.pump();
      expect(interaction.isInteracting, isTrue);
      var commits = 0;
      interaction.scheduleCommit(
        key: 'detail-scroll-regression',
        commit: () => commits++,
      );
      images.complete([
        const CoverImageReference(
          displayPath: '$folder/000-new-cover.jpg',
          sourcePath: '$folder/000-new-cover.jpg',
        ),
      ]);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.position.isScrollingNotifier.value, isTrue);
      expect(commits, 0);
      expect(find.text('000-new-cover'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await _settleDetail(tester);
      controller.jumpTo(0);
      await _settleDetail(tester);
      expect(interaction.isInteracting, isFalse);
      expect(commits, 1);
      expect(find.text('000-new-cover'), findsOneWidget);
      final audioTiles = tester
          .widgetList<WorkDetailEntryTile>(find.byType(WorkDetailEntryTile))
          .where((tile) => tile.item.type == WorkEntryType.audio)
          .toList();
      expect(audioTiles.length, greaterThan(1));
      for (final tile in audioTiles.skip(1)) {
        expect(tile.menuEntries, same(audioTiles.first.menuEntries));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await _settleDetail(tester);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  test('WorkDirectorySnapshot preserves file sizes and original suffixes', () {
    final track = MusicTrack(
      path: r'C:\作品\音频.WAV',
      displayName: '音频',
      groupKey: 'work',
      groupTitle: 'work',
      groupSubtitle: '',
      isSingle: false,
      fileSizeBytes: 2048,
      duration: const Duration(seconds: 65),
    );
    final root = FolderNode('作品', r'C:\作品')..addChild(TrackNode(track));
    final local = buildWorkDirectorySnapshot(
      WorkDirectoryInput.local(
        root: root,
        texts: const [
          WorkTextFile(
            name: '说明.txt',
            relativePath: '说明.txt',
            path: r'C:\作品\说明.txt',
            fileSizeBytes: 0,
          ),
        ],
        images: const [
          CoverImageReference(
            displayPath: '/cache/cover.jpg',
            sourcePath: r'C:\作品\封面.png',
            fileSizeBytes: 512,
          ),
        ],
        folderPath: r'C:\作品',
      ),
    ).entriesAt([]);
    expect(local.map((item) => item.fileSizeBytes), [512, 0, 2048]);
    expect(local.map((item) => item.extension), ['.png', '.txt', '.WAV']);
    expect(local.map((item) => item.displayName), ['封面', '说明', '音频']);
    expect(local.last.duration, track.duration);

    final remote = buildWorkDirectorySnapshot(
      WorkDirectoryInput.asmr([
        AsmrTrackFile.fromJson(const {
          'title': 'Remote audio',
          'type': 'audio',
          'mediaStreamUrl': 'https://example.test/audio.flac?token=1',
          'size': 4096,
          'duration': 65,
        }),
      ]),
    ).entriesAt([]).single;
    expect(remote.fileSizeBytes, 4096);
    expect(remote.duration, track.duration);
    expect(remote.extension, '.flac');
  });

  test('Japanese ASMR detail projection hides only the site wrapper', () {
    final wrapper = AsmrTrackFile.fromJson(const {
      'type': 'folder',
      'title': 'japaneseasmr.com',
      'children': [
        {
          'type': 'audio',
          'title': 'Opening.m4a',
          'mediaStreamUrl':
              'https://v.weeab0o.xyz/work.m3u8#eara-chapter=0,1000',
        },
        {
          'type': 'folder',
          'title': 'Bonus',
          'children': [
            {
              'type': 'audio',
              'title': 'Extra.m4a',
              'mediaStreamUrl': 'https://example.test/extra.m4a',
            },
            {
              'type': 'text',
              'title': 'Notes.txt',
              'mediaDownloadUrl': 'https://example.test/notes.txt',
            },
          ],
        },
      ],
    });
    final directory = buildWorkDirectorySnapshot(
      WorkDirectoryInput.asmr([wrapper]),
    );
    final root = directory.entriesAt([]);
    expect(root.map((entry) => entry.name), ['Bonus', 'Opening']);
    expect(directory.directories.containsKey('japaneseasmr.com'), isFalse);
    expect(root.last.asmrNode, same(wrapper.children.first));
    expect(root.last.relativePath, 'japaneseasmr.com/Opening.m4a');
    expect(directory.entriesAt(['Bonus']).map((entry) => entry.name), [
      'Extra',
      'Notes.txt',
    ]);
    expect(directory.validDepth(['Bonus']), 1);
    expect(wrapper.children.last.relativePath, 'japaneseasmr.com/Bonus');
  });

  for (final cached in [false, true]) {
    _detailTestWidgets(
      'Japanese ASMR detail opens directly into tracks cached=$cached',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);
        final tree = [
          AsmrTrackFile.fromJson(const {
            'type': 'folder',
            'title': 'japaneseasmr.com',
            'children': [
              {
                'type': 'audio',
                'title': 'Opening.m4a',
                'mediaStreamUrl':
                    'https://v.weeab0o.xyz/work.m3u8#eara-chapter=0,1000',
              },
              {
                'type': 'folder',
                'title': 'Bonus',
                'children': [
                  {
                    'type': 'audio',
                    'title': 'Extra.m4a',
                    'mediaStreamUrl': 'https://example.test/extra.m4a',
                  },
                ],
              },
            ],
          }),
        ];
        final controller = _DeferredDetailAsmrController(tree, cached: cached);
        addTearDown(controller.dispose);
        final work = AsmrWork.fromJson(const {
          'id': 42,
          'title': 'Japanese Work',
          'sourceId': 'RJ000042',
          'resources': [
            {
              'source': 'japaneseAsmr',
              'id': 42,
              'code': 'RJ000042',
              'pageUrl': '',
            },
          ],
        });
        await tester.pumpWidget(
          fixture.build(
            WorkDetailPage.forAsmr(work: work),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await _settleDetail(tester);
        expect(find.text('japaneseasmr.com'), findsNothing);
        expect(find.text('Opening'), findsOneWidget);
        expect(find.text('Bonus'), findsOneWidget);
        await tester.tap(find.text('Bonus'));
        await _settleDetail(tester);
        expect(find.text('Extra'), findsOneWidget);
        expect(find.text('japaneseasmr.com'), findsNothing);
        expect(
          controller.tree.single.children.first.relativePath,
          'japaneseasmr.com/Opening.m4a',
        );
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  group('WorkDetailPage', () {
    for (final reducedMotion in [false, true]) {
      _detailTestWidgets(
        'directory switches fade out and in within 300ms, reduced=$reducedMotion',
        (tester) async {
          final fixture = AppRuntimeWidgetTestFixture();
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          final tree = [
            for (final name in ['First', 'Second', 'Empty'])
              AsmrTrackFile.fromJson({
                'type': 'folder',
                'title': name,
                'children': [
                  if (name != 'Empty')
                    {
                      'type': 'audio',
                      'title': '$name audio.mp3',
                      'mediaStreamUrl': 'https://example.test/$name.mp3',
                    },
                ],
              }),
          ];
          final controller = _DeferredDetailAsmrController(tree, cached: false);
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            fixture.build(
              MediaQuery(
                data: MediaQueryData(disableAnimations: reducedMotion),
                child: WorkDetailPage.forAsmr(
                  work: AsmrWork.fromJson(const {'id': 42, 'title': 'Work'}),
                ),
              ),
              overrides: [
                asmrLibraryControllerProvider.overrideWithValue(controller),
              ],
            ),
          );
          await _settleDetail(tester);
          double opacity() => tester.widget<SliverFadeTransition>(
            find.byKey(const ValueKey('work_detail_entries_fade')),
          ).opacity.value;
          final breadcrumbs = find.byType(WorkDetailBreadcrumbs);
          final breadcrumbsTop = tester.getTopLeft(breadcrumbs).dy;
          final root = find.text(fixture.languageProvider.tr('root_directory'));

          Future<void> finishSwitch() async {
            if (!reducedMotion) {
              await tester.pump(const Duration(milliseconds: 75));
              expect(opacity(), inExclusiveRange(0, 1));
              expect(
                find.byKey(const ValueKey('work_detail_entries_skeleton')),
                findsNothing,
              );
              await tester.pump(const Duration(milliseconds: 75));
              // Ticker completion is reported just after the final timestamp.
              await tester.pump(const Duration(microseconds: 1));
              await tester.pump();
              expect(opacity(), 0);
              await tester.pump(const Duration(milliseconds: 75));
              expect(opacity(), inExclusiveRange(0, 1));
              await tester.pump(const Duration(milliseconds: 75));
            } else {
              await tester.pump();
            }
            expect(opacity(), 1);
            expect(tester.getTopLeft(breadcrumbs).dy, breadcrumbsTop);
          }

          await tester.tap(find.text('First'));
          await tester.pump();
          if (!reducedMotion) {
            expect(find.text('First audio'), findsNothing);
            expect(opacity(), 1);
          }
          await finishSwitch();
          expect(find.text('First audio'), findsOneWidget);
          await tester.tap(root);
          await tester.pump();
          await finishSwitch();
          expect(find.text('First audio'), findsNothing);

          // A later tap supersedes a request while the old directory fades.
          await tester.tap(find.text('First'));
          await tester.pump();
          if (!reducedMotion) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.tap(find.text('Second'));
          }
          await tester.pumpAndSettle();
          expect(
            find.text(reducedMotion ? 'First audio' : 'Second audio'),
            findsOneWidget,
          );
          await tester.tap(root);
          await tester.pumpAndSettle();
          if (!reducedMotion) {
            await tester.tap(find.text('First'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 50));
            await tester.tap(root);
            await tester.pumpAndSettle();
            expect(find.text('First audio'), findsNothing);
            expect(find.text('Second'), findsOneWidget);
          }
          await tester.tap(find.text('Empty'));
          await tester.pump();
          await finishSwitch();
          expect(
            find.text(fixture.languageProvider.tr('empty_folder')),
            findsOneWidget,
          );
          await tester.tap(root);
          await tester.pump();
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.windows,
        }),
      );
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      for (final local in [false, true]) {
        _detailTestWidgets(
          'expanded work cover stays 4:3 on pane resize, local=$local on $platform',
          (tester) async {
            await tester.binding.setSurfaceSize(null);
            tester.view.physicalSize = const Size(1280, 1000);
            tester.view.devicePixelRatio = 1;
            tester.view.padding = const FakeViewPadding(top: 24);
            addTearDown(tester.view.reset);
            final covers = _ControlledWorkDetailCoverService()
              ..images.complete([])
              ..cover.complete(null);
            final fixture = AppRuntimeWidgetTestFixture(
              coverArtworkCacheService: covers,
              asmrMetadataService: _WorkDetailAsmrMetadataService(),
            );
            _detailFixtures.add(fixture);
            addTearDown(fixture.dispose);
            const folder = 'C:/works/cover-ratio';
            fixture.library.addWatchedFolder(folder, notify: false);
            fixture.library.addTracks([
              MusicTrack(
                path: '$folder/audio.mp3',
                displayName: 'Audio',
                groupKey: folder,
                groupTitle: 'Work',
                groupSubtitle: '',
                isSingle: false,
              ),
            ], persist: false);
            final width = ValueNotifier(320.0);
            addTearDown(width.dispose);
            await tester.pumpWidget(
              fixture.build(
                Align(
                  alignment: Alignment.topRight,
                  child: ValueListenableBuilder<double>(
                    valueListenable: width,
                    child: local
                        ? WorkDetailPage.forLocal(
                            target: AudioDetailTarget.libraryRootFolder(folder),
                          )
                        : WorkDetailPage.forAsmr(
                            work: AsmrWork.fromJson(const {
                              'id': 123456,
                              'title': 'Work',
                            }),
                          ),
                    builder: (_, value, child) =>
                        SizedBox(width: value, child: child),
                  ),
                ),
              ),
            );
            await _settleDetail(tester);
            final cover = find.byKey(
              const ValueKey('work_detail_cover_bounds'),
            );
            final scroll = tester
                .widget<CustomScrollView>(find.byType(CustomScrollView))
                .controller!;
            for (final value in [320.0, 560.0, 800.0, 390.0]) {
              scroll.jumpTo(0);
              width.value = value;
              await tester.pump();
              await tester.pump();
              final size = tester.getSize(cover);
              expect(size.width, value);
              expect(size.height, closeTo(value * 3 / 4, 0.001));
              expect(size.aspectRatio, closeTo(4 / 3, 0.001));
              expect(tester.getTopLeft(cover).dx, closeTo(1280 - value, 0.001));
            }
            scroll.jumpTo(40);
            await tester.pump();
            expect(
              tester.getSize(cover).height,
              closeTo(390 * 3 / 4 - 40, 0.001),
            );
            scroll.jumpTo(1000);
            await tester.pump();
            expect(
              tester.getSize(cover).height,
              closeTo(24 + 120, 0.001),
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          variant: TargetPlatformVariant.only(platform),
        );
      }
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      for (final cached in [false, true]) {
        for (final local in [false, true]) {
          _detailTestWidgets(
            '${local ? 'local' : 'ASMR'} ${cached ? 'cached' : 'cold'} detail displays content during real navigation on $platform',
            (tester) async {
              final interaction = UiInteractionCoordinator.instance;
              interaction.resetForTest();
              addTearDown(interaction.resetForTest);
              SharedPreferences.setMockInitialValues({});
              final covers = _ControlledWorkDetailCoverService()
                ..images.complete([])
                ..cover.complete(null);
              final fixture = AppRuntimeWidgetTestFixture(
                coverArtworkCacheService: covers,
              );
              _detailFixtures.add(fixture);
              addTearDown(fixture.dispose);
              const folder = 'C:/works/first-detail';
              final target = AudioDetailTarget.libraryRootFolder(folder);
              final texts = WorkTextService(
                discoverImages: (_) async => [],
                platformGateway: _NestedWorkDetailFileGateway([]),
              );
              addTearDown(texts.dispose);
              final work = AsmrWork.fromJson(const {
                'id': 10001,
                'title': 'First detail title',
                'voiceActors': ['Deferred voice actor'],
                'mainCoverUrl': 'https://example.test/first-cover.jpg',
              });
              final remote = _DeferredDetailAsmrController([
                AsmrTrackFile(
                  hash: 'first-detail',
                  title: 'Deferred audio.mp3',
                  type: 'audio',
                  streamUrl: 'https://example.test/audio.mp3',
                  downloadUrl: null,
                  lowQualityUrl: null,
                  duration: const Duration(minutes: 1),
                  size: 0,
                  children: const [],
                  workId: work.id,
                  workTitle: work.title,
                  sourceId: '',
                  relativePath: 'Deferred audio.mp3',
                ),
              ], cached: cached);
              addTearDown(remote.dispose);
              if (local) {
                fixture.library.addWatchedFolder(folder, notify: false);
                fixture.library.addTracks(
                  [
                    testMusicTrack(
                      name: 'Deferred audio.mp3',
                      path: '$folder/audio.mp3',
                      groupKey: folder,
                      groupTitle: 'First detail title',
                    ),
                  ],
                  persist: false,
                );
                if (cached) {
                  await tester.runAsync(() async {
                    await fixture.library.loadLibraryFolderTree(folder);
                    await _prewarmDirectory(fixture, folder);
                  });
                }
              } else if (cached) {
                await tester.runAsync(
                  () => WorkDirectoryInput.asmr(remote.tree).load(),
                );
              }
              final headerFinder = find.byKey(
                const ValueKey('work_detail_page_header'),
              );

              double headerOpacity() {
                final fade = find.descendant(
                  of: headerFinder,
                  matching: find.byWidgetPredicate(
                    (widget) => widget is FadeTransition,
                  ),
                ).first;
                return tester.widget<FadeTransition>(fade).opacity.value;
              }

              await tester.pumpWidget(
                AppPageTransitionHost(
                  child: fixture.build(
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => Navigator.of(context).push<void>(
                        buildAppPageRoute(
                          context: context,
                          separateHeader: true,
                          child: local
                              ? WorkDetailPage.forLocal(
                                  target: target,
                                  initialDetail: AudioDetail.empty(target)
                                      .copyWith(
                                        workTitle: 'First detail title',
                                        voiceActors: ['Deferred voice actor'],
                                      ),
                                )
                              : WorkDetailPage.forAsmr(work: work),
                        ),
                      ),
                      child: const Text('Open first detail'),
                    ),
                  ),
                  navigatorObservers: [UiInteractionNavigatorObserver()],
                  overrides: [
                    workTextServiceProvider.overrideWithValue(texts),
                    if (!local)
                      asmrLibraryControllerProvider.overrideWithValue(remote),
                  ],
                  ),
                ),
              );
              await tester.tap(find.text('Open first detail'));
              await tester.pump();
              await tester.pump();
              expect(find.text('Deferred voice actor'), findsOneWidget);
              await tester.pump(const Duration(milliseconds: 100));
              expect(headerFinder, findsOneWidget);
              expect(
                find.descendant(
                  of: headerFinder,
                  matching: find.byType(AppEdgeFadeMask),
                ),
                findsNothing,
              );
              expect(headerOpacity(), inExclusiveRange(0.0, 1.0));
              expect(find.text('First detail title'), findsOneWidget);
              expect(
                find.byType(WorkDetailEntryTile),
                cached ? findsWidgets : findsNothing,
              );
              expect(
                find.byType(AsyncLocalCoverImage),
                local ? findsOneWidget : findsNothing,
              );
              expect(
                find.byType(AsyncRemoteCoverImage),
                local ? findsNothing : findsOneWidget,
              );
              expect(find.text('Deferred voice actor'), findsOneWidget);
              expect(
                find.byType(FileTreeSkeleton),
                cached ? findsNothing : findsOneWidget,
              );
              expect(remote.cacheReads, local ? 0 : 1);
              expect(remote.requests, 0);
              await _settleDetail(tester);
              expect(headerOpacity(), 1.0);
              expect(find.byType(WorkDetailEntryTile), findsWidgets);
              expect(find.text('Deferred voice actor'), findsOneWidget);
              if (!local) {
                // Cached content is already visible while refresh waits for
                // the navigation interaction's quiet window to finish.
                await tester.pump(const Duration(milliseconds: 200));
                await _settleDetail(tester);
                expect(remote.cacheReads, 1);
                expect(remote.requests, 1);
              }
              Navigator.of(tester.element(headerFinder)).pop();
              await tester.pump();
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 100));
              expect(headerFinder, findsOneWidget);
              expect(headerOpacity(), inExclusiveRange(0.0, 1.0));
              await tester.pumpAndSettle();
              await tester.pump(Duration.zero);
              expect(headerFinder, findsNothing);
              await tester.pumpWidget(const SizedBox.shrink());
              await _settleDetail(tester);
              expect(tester.takeException(), isNull);
            },
            variant: TargetPlatformVariant({platform}),
          );
        }
      }
    }

    _detailTestWidgets('leaving the source frame cancels a pending detail push', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = AppRuntimeWidgetTestFixture();
      _detailFixtures.add(fixture);
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(
          Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  unawaited(
                    showAudioDetailSheet(
                      context,
                      AudioDetailTarget.libraryRootFolder('C:/cancelled'),
                    ),
                  );
                  unawaited(
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const Scaffold(body: Text('Other page')),
                      ),
                    ),
                  );
                },
                child: const Text('Open and leave'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open and leave'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Other page'), findsOneWidget);
      expect(find.byType(WorkDetailPage, skipOffstage: false), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      _detailTestWidgets(
        'initial library revision does not rebuild cached rows on $platform',
        (tester) async {
          final interaction = UiInteractionCoordinator.instance;
          interaction.resetForTest();
          addTearDown(interaction.resetForTest);
          SharedPreferences.setMockInitialValues({});
          final covers = _ControlledWorkDetailCoverService()
            ..images.complete([])
            ..cover.complete(null);
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          const folder = 'C:/works/initial-revision';
          final target = AudioDetailTarget.libraryRootFolder(folder);
          await tester.runAsync(() async {
            fixture.library.addWatchedFolder(folder, notify: false);
            fixture.library.addTracks(
              List.generate(
                80,
                (index) => testMusicTrack(
                  name: 'Track $index',
                  path: '$folder/$index.mp3',
                  groupKey: folder,
                  groupTitle: 'Initial revision',
                ),
              ),
              persist: false,
            );
            await fixture.library.flushPendingPersistence();
            await fixture.library.loadLibraryFolderTree(folder);
            await _prewarmDirectory(fixture, folder);
          });
          final states = StreamController<LibraryState>();
          addTearDown(states.close);
          interaction.beginNavigation(Object());
          addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
          await tester.pumpWidget(
            fixture.build(
              WorkDetailPage.forLocal(
                target: target,
                initialDetail: AudioDetail.empty(target),
              ),
              overrides: [
                libraryStateProvider.overrideWith((ref) => states.stream),
              ],
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(find.byType(WorkDetailEntryTile), findsWidgets);
          interaction.finishInteractionsForTest();
          await _settleDetail(tester);
          final list = tester.widget<SliverList>(find.byType(SliverList));
          expect(find.byType(WorkDetailEntryTile), findsWidgets);

          interaction.beginNavigation(Object());
          states.add(fixture.library.state);
          await tester.pump();
          await tester.pump();
          expect(
            tester.widget<SliverList>(find.byType(SliverList)),
            same(list),
            reason:
                'The first stream value matches the cached content revision '
                'and must not rebuild the page during navigation.',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant({platform}),
      );

      _detailTestWidgets(
        'cold directory preparation waits until the detail route finishes on $platform',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(800, 1000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          SharedPreferences.setMockInitialValues({});
          final interaction = UiInteractionCoordinator.instance;
          interaction.resetForTest();
          addTearDown(interaction.resetForTest);
          final directory = Completer<LibraryTreeSnapshot>();
          var treeRequests = 0;
          final covers = _ControlledWorkDetailCoverService()
            ..images.complete([])
            ..cover.complete(null);
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
            libraryTreeSnapshotBuilder: (_) {
              treeRequests++;
              return directory.future;
            },
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          const folder = 'C:/works/cold-directory';
          final target = AudioDetailTarget.libraryRootFolder(folder);
          final detail = AudioDetail.empty(
            target,
          ).copyWith(workTitle: 'Cold directory');
          fixture.library.addWatchedFolder(folder, notify: false);
          fixture.library.addTracks([
            MusicTrack(
              path: '$folder/audio.mp3',
              displayName: 'audio.mp3',
              groupKey: folder,
              groupTitle: '',
              groupSubtitle: '',
              isSingle: false,
            ),
          ], persist: false);
          final texts = WorkTextService(
            discoverImages: (_) async => [],
            platformGateway: _NestedWorkDetailFileGateway([]),
          );
          addTearDown(texts.dispose);
          await tester.pumpWidget(
            fixture.build(
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAudioDetailSheet(
                    context,
                    target,
                    initialDetail: detail,
                  ),
                  child: const Text('Open cold directory'),
                ),
              ),
              navigatorObservers: [UiInteractionNavigatorObserver()],
              overrides: [workTextServiceProvider.overrideWithValue(texts)],
            ),
          );
          await tester.tap(find.text('Open cold directory'));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text('Cold directory'), findsOneWidget);
          expect(treeRequests, 0);
          expect(find.text('audio'), findsNothing);
          final skeleton = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('work_detail_entries_skeleton')),
          );
          final directorySkeleton = tester.widget<FileTreeSkeleton>(
            find.byType(FileTreeSkeleton),
          );
          expect(directorySkeleton.viewportHeight, greaterThan(0));
          final skeletonBounds = tester.getRect(
            find.byKey(const ValueKey('work_detail_entries_skeleton')),
          );
          expect(skeletonBounds.bottom, greaterThanOrEqualTo(996));
          expect(skeletonBounds.bottom, lessThanOrEqualTo(996 + 48));
          final skeletonRows = find.descendant(
            of: find.byKey(const ValueKey('work_detail_entries_skeleton')),
            matching: find.byType(SizedBox),
          );
          expect(tester.getSize(skeletonRows.first).height, 48);
          final preparedPaints = skeleton.debugAsymmetricPaintCount;
          await tester.pump(const Duration(milliseconds: 20));
          expect(
            skeleton.debugAsymmetricPaintCount,
            preparedPaints,
            reason: 'The skeleton stays still during the route slide.',
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(interaction.idleDelay);
          await tester.pump();
          expect(treeRequests, 1);
          await tester.pump();
          await tester.pump(kAppMotionFast + const Duration(milliseconds: 1));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
          expect(
            const WorkDirectoryInput.local(
              root: null,
              texts: [],
              images: [],
              folderPath: folder,
            ).resolved,
            isNull,
            reason: 'Do not prepare an empty tree before sources arrive.',
          );
          await tester.binding.setSurfaceSize(const Size(800, 1200));
          await tester.pump();
          final skeletonRect = tester.getRect(
            find.byKey(const ValueKey('work_detail_entries_skeleton')),
          );
          expect(skeletonRect.height, greaterThan(skeletonBounds.height));
          expect(skeletonRect.bottom, greaterThanOrEqualTo(1196));
          expect(skeletonRect.bottom, lessThan(1200 + 48));
          final scroll = find.descendant(
            of: find.byType(WorkDetailPage),
            matching: find.byType(CustomScrollView),
          );
          final position = tester
              .state<ScrollableState>(
                find
                    .descendant(of: scroll, matching: find.byType(Scrollable))
                    .first,
              )
              .position;
          await tester.drag(scroll, const Offset(0, -250));
          await tester.pump(const Duration(milliseconds: 300));
          expect(position.pixels, 0);
          expect(
            tester.getRect(
              find.byKey(const ValueKey('work_detail_entries_skeleton')),
            ),
            skeletonRect,
          );
          directory.complete(
            const LibraryOrganizer().buildTree(
              tracks: fixture.library.library,
              watchedFolders: [folder],
            ),
          );
          for (var attempt = 0; attempt < 50; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
            if (find.text('audio').evaluate().isNotEmpty) break;
          }
          expect(find.text('audio'), findsOneWidget);
          final fade = find.byKey(const ValueKey('work_detail_entries_fade'));
          expect(tester.widget<SliverFadeTransition>(fade).opacity.value, 0);
          final skeletonFade = find
              .ancestor(
                of: find.byKey(const ValueKey('work_detail_entries_skeleton')),
                matching: find.byType(FadeTransition),
              )
              .first;
          expect(tester.widget<FadeTransition>(skeletonFade).opacity.value, 1);
          expect(
            tester.getRect(
              find.byKey(const ValueKey('work_detail_entries_skeleton')),
            ),
            skeletonRect,
          );
          final halfFadeDuration = kPlaceholderContentTransitionDuration ~/ 2;
          await tester.pump(halfFadeDuration);
          expect(
            tester.widget<SliverFadeTransition>(fade).opacity.value,
            closeTo(0.5, 0.05),
          );
          expect(
            tester.widget<FadeTransition>(skeletonFade).opacity.value +
                tester.widget<SliverFadeTransition>(fade).opacity.value,
            closeTo(1, 0.001),
          );
          await tester.pump(halfFadeDuration + const Duration(milliseconds: 1));
          await tester.pump();
          expect(tester.widget<SliverFadeTransition>(fade).opacity.value, 1);
          expect(
            find.byKey(const ValueKey('work_detail_entries_skeleton')),
            findsNothing,
          );
          await tester.binding.setSurfaceSize(const Size(800, 600));
          await tester.pump();
          await tester.drag(scroll, const Offset(0, -250));
          await tester.pump(const Duration(milliseconds: 300));
          final loadedPosition = tester
              .state<ScrollableState>(
                find
                    .descendant(of: scroll, matching: find.byType(Scrollable))
                    .first,
              )
              .position;
          expect(loadedPosition.pixels, greaterThan(0));
          await tester.binding.setSurfaceSize(const Size(800, 1200));
          await tester.pump();
          Navigator.of(tester.element(find.byType(WorkDetailPage))).pop();
          await _settleDetail(tester);
          await tester.pump(interaction.idleDelay);
          await tester.tap(find.text('Open cold directory'));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text('audio'), findsOneWidget);
          await _settleDetail(tester);
          expect(find.text('audio'), findsOneWidget);
          expect(tester.widget<SliverFadeTransition>(fade).opacity.value, 1);
          expect(
            treeRequests,
            1,
            reason: 'Reopen reuses the prepared subtree.',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          // Disposing the reopened route releases its navigation interaction.
          await tester.pump(interaction.idleDelay);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );

      _detailTestWidgets(
        'late file discoveries fade only new rows on $platform',
        (tester) async {
          final interaction = UiInteractionCoordinator.instance;
          interaction.resetForTest();
          addTearDown(interaction.resetForTest);
          SharedPreferences.setMockInitialValues({});
          final covers = _ControlledWorkDetailCoverService()
            ..images.complete([])
            ..cover.complete(null);
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          const folder = 'C:/works/late-files';
          final target = AudioDetailTarget.libraryRootFolder(folder);
          fixture.library.addWatchedFolder(folder, notify: false);
          fixture.library.addTracks([
            testMusicTrack(
              name: 'Existing audio',
              path: '$folder/audio.mp3',
              groupKey: folder,
              groupTitle: 'Late files',
            ),
          ], persist: false);
          await tester.runAsync(() async {
            await fixture.library.loadAudioDetail(target);
            await fixture.library.loadLibraryFolderTree(folder);
            await _prewarmDirectory(fixture, folder);
          });
          final gateway = _PendingWorkDetailFileGateway();
          final texts = WorkTextService(
            platformGateway: gateway,
            discoverImages: (_) async => [],
          );
          addTearDown(texts.dispose);
          await tester.pumpWidget(
            fixture.build(
              WorkDetailPage.forLocal(target: target),
              overrides: [workTextServiceProvider.overrideWithValue(texts)],
            ),
          );
          await _settleDetail(tester);
          Finder rowFade(String id) =>
              find.byKey(ValueKey('work_detail_entry_fade_$id'));
          final audioRow = find.byKey(
            const ValueKey('audio:$folder/audio.mp3'),
          );
          final audioState = tester.state<State<WorkDetailEntryTile>>(audioRow);
          int? entryIndex(String id) {
            final delegate =
                tester.widget<SliverList>(find.byType(SliverList)).delegate
                    as SliverChildBuilderDelegate;
            return delegate.findChildIndexCallback!(
              ValueKey('work_detail_entry_fade_$id'),
            );
          }

          expect(entryIndex('audio:$folder/audio.mp3'), 0);
          expect(entryIndex('text:missing.txt'), isNull);
          expect(
            tester
                .widget<FadeTransition>(rowFade('audio:$folder/audio.mp3'))
                .opacity
                .value,
            1,
          );
          gateway.texts.complete([
            {
              'name': 'notes.txt',
              'relativePath': 'notes.txt',
              'path': '$folder/notes.txt',
            },
            {
              'name': 'readme.txt',
              'relativePath': 'Extras/readme.txt',
              'path': '$folder/Extras/readme.txt',
            },
          ]);
          for (var attempt = 0; attempt < 50; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
            if (find.text('notes').evaluate().isNotEmpty) break;
          }
          expect(find.text('notes'), findsOneWidget);
          expect(entryIndex('folder:Extras'), 0);
          expect(entryIndex('audio:$folder/audio.mp3'), 1);
          expect(entryIndex('text:notes.txt'), 2);
          expect(entryIndex('text:Extras/readme.txt'), isNull);
          expect(tester.state(audioRow), same(audioState));
          expect(
            tester
                .widget<FadeTransition>(rowFade('audio:$folder/audio.mp3'))
                .opacity
                .value,
            1,
          );
          expect(
            tester
                .widget<FadeTransition>(rowFade('text:notes.txt'))
                .opacity
                .value,
            0,
          );
          final halfFadeDuration = kPlaceholderContentTransitionDuration ~/ 2;
          await tester.pump(halfFadeDuration);
          expect(
            tester
                .widget<FadeTransition>(rowFade('text:notes.txt'))
                .opacity
                .value,
            closeTo(0.5, 0.05),
          );
          expect(
            tester
                .widget<FadeTransition>(rowFade('audio:$folder/audio.mp3'))
                .opacity
                .value,
            1,
          );
          await tester.pump(halfFadeDuration + const Duration(milliseconds: 1));
          await tester.pump();
          expect(tester.state(audioRow), same(audioState));
          expect(
            tester
                .widget<FadeTransition>(rowFade('text:notes.txt'))
                .opacity
                .value,
            1,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );

      _detailTestWidgets(
        'in-flight file and cover results wait for the next route transition on $platform',
        (tester) async {
          UiInteractionCoordinator.instance.resetForTest();
          addTearDown(UiInteractionCoordinator.instance.resetForTest);
          SharedPreferences.setMockInitialValues(const <String, Object>{});
          final covers = _ControlledWorkDetailCoverService();
          final gateway = _PendingWorkDetailFileGateway();
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          const folder = 'C:/works/in-flight';
          final target = AudioDetailTarget.libraryRootFolder(folder);
          fixture.library.addWatchedFolder(folder, notify: false);
          fixture.library.addTracks([
            MusicTrack(
              path: '$folder/audio.mp3',
              displayName: 'audio.mp3',
              groupKey: folder,
              groupTitle: 'In flight',
              groupSubtitle: '',
              isSingle: false,
            ),
          ], persist: false);
          await tester.runAsync(() async {
            await fixture.library.loadAudioDetail(target);
            await fixture.library.loadLibraryFolderTree(folder);
            await _prewarmDirectory(fixture, folder);
          });
          final textService = WorkTextService(
            platformGateway: gateway,
            discoverImages:
                fixture.library.discoverCoverImageReferencesInFolder,
          );
          addTearDown(textService.dispose);
          await tester.pumpWidget(
            fixture.build(
              WorkDetailPage.forLocal(target: target),
              navigatorObservers: [UiInteractionNavigatorObserver()],
              overrides: [
                workTextServiceProvider.overrideWithValue(textService),
              ],
            ),
          );
          await _settleDetail(tester);
          expect(covers.imageRequests, 1);
          final context = tester.element(find.byType(WorkDetailPage));
          unawaited(
            Navigator.of(context).push<void>(
              buildAppPageRoute<void>(
                context: context,
                child: const Scaffold(body: Text('next page')),
                duration: const Duration(milliseconds: 500),
              ),
            ),
          );
          await tester.pump();
          expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
          gateway.texts.complete([
            {
              'name': 'notes.txt',
              'relativePath': 'notes.txt',
              'path': '$folder/notes.txt',
            },
          ]);
          covers.images.complete(['$folder/picture.jpg']);
          covers.cover.complete('$folder/cover.jpg');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text('notes', skipOffstage: false), findsNothing);
          expect(find.text('picture', skipOffstage: false), findsNothing);
          expect(
            find.byType(AsyncLocalCoverImage, skipOffstage: false),
            findsOneWidget,
          );
          expect(
            tester
                .widget<AsyncLocalCoverImage>(
                  find.byType(AsyncLocalCoverImage, skipOffstage: false),
                )
                .initialPath,
            isNot('$folder/cover.jpg'),
          );
          expect(
            find.byType(LocalCoverImage, skipOffstage: false),
            findsNothing,
          );
          await _settleDetail(tester);
          await tester.pump(const Duration(milliseconds: 200));
          await _settleDetail(tester);
          Navigator.of(context).pop();
          await _settleDetail(tester);
          await tester.pump(const Duration(milliseconds: 200));
          await _settleDetail(tester);
          expect(find.text('notes'), findsOneWidget);
          expect(find.text('picture'), findsOneWidget);
          expect(
            tester.widget<LocalCoverImage>(find.byType(LocalCoverImage)).path,
            '$folder/cover.jpg',
          );
          expect(covers.imageRequests, 1);
          expect(covers.coverRequests, 1);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      _detailTestWidgets(
        'opens with card data after shared caches clear on $platform',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final repository = _CountingDetailRepository();
          final covers = _ControlledWorkDetailCoverService()
            ..images.complete([]);
          final fixture = AppRuntimeWidgetTestFixture(
            providedPersistenceRepository: repository,
            coverArtworkCacheService: covers,
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          final target = AudioDetailTarget.libraryRootFolder('C:/works/card');
          final detail = AudioDetail.empty(target).copyWith(
            target: AudioDetailTarget.libraryRootFolder('c:/works/card'),
            workTitle: 'Card data title',
            circleName: 'Card data circle',
            voiceActors: ['Card data voice'],
            tags: ['Card data tag'],
          );
          final interaction = UiInteractionCoordinator.instance;
          interaction.resetForTest();
          addTearDown(interaction.resetForTest);
          await tester.pumpWidget(
            fixture.build(
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAudioDetailSheet(
                    context,
                    target,
                    initialDetail: detail,
                    initialCoverPath: 'C:/works/card/cover.jpg',
                  ),
                  child: const Text('Open card'),
                ),
              ),
              navigatorObservers: [UiInteractionNavigatorObserver()],
            ),
          );
          fixture.library.detailCacheService.clear();
          fixture.library.snapshotCacheService.clear();
          await tester.tap(find.text('Open card'));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          for (final text in [detail.workTitle, detail.circleName]) {
            expect(find.text(text), findsOneWidget);
          }
          expect(find.text(detail.voiceActors.single), findsOneWidget);
          expect(find.text('#${detail.tags.single}'), findsOneWidget);
          expect(find.byType(AsyncLocalCoverImage), findsOneWidget);
          expect(find.byType(LocalCoverImage), findsOneWidget);
          expect(
            tester.widget<LocalCoverImage>(find.byType(LocalCoverImage)).path,
            'C:/works/card/cover.jpg',
          );
          expect(find.byType(CoverFallbackArtwork), findsOneWidget);
          expect(repository.detailRequests, 0);
          expect(covers.imageRequests, 0);
          expect(covers.coverRequests, 0);
          Navigator.of(tester.element(find.byType(WorkDetailPage))).pop();
          await _settleDetail(tester);
          await tester.pump(interaction.idleDelay);
          expect(covers.imageRequests, 0);
          expect(repository.detailRequests, 0);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );

      _detailTestWidgets(
        'reuses remote card cover and keeps its future stable on $platform',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final covers = _ControlledWorkDetailCoverService()
            ..cachedCover = 'C:/works/remote/cover.jpg';
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          final work = AsmrWork.fromJson(const {
            'id': 321,
            'title': 'Cached remote card',
            'mainCoverUrl': 'https://example.com/cover.jpg',
          });
          Widget page() => fixture.build(WorkDetailPage.forAsmr(work: work));
          await tester.pumpWidget(page());
          expect(find.byType(AsyncRemoteCoverImage), findsOneWidget);
          await tester.pump();
          await tester.pump(UiInteractionCoordinator.instance.idleDelay);
          await tester.pump();
          final initial = tester.widget<AsyncRemoteCoverImage>(
            find.byType(AsyncRemoteCoverImage),
          );
          expect(initial.initialPath, covers.cachedCover);
          expect(initial.deferLoadDuringInteraction, isTrue);
          await tester.pump();
          await tester.pumpWidget(page());
          final rebuilt = tester.widget<AsyncRemoteCoverImage>(
            find.byType(AsyncRemoteCoverImage),
          );
          expect(identical(initial.future, rebuilt.future), isTrue);
          expect(covers.remoteCoverRequests, 0);
          // Invalidation must still resolve a missing cover through the gateway.
          covers.cachedCover = null;
          covers.invalidateAll();
          covers.cover.complete('C:/works/remote/repaired.jpg');
          await tester.pumpWidget(page());
          await _settleDetail(tester);
          expect(covers.remoteCoverRequests, 1);
          final image = tester.widget<RetryingFileImage>(
            find.byType(RetryingFileImage),
          );
          expect(image.path, 'C:/works/remote/repaired.jpg');
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );

      _detailTestWidgets(
        'reuses main-page metadata snapshot without reloading on $platform',
        (tester) async {
          SharedPreferences.setMockInitialValues(const <String, Object>{});
          final repository = _CountingDetailRepository();
          final covers = _ControlledWorkDetailCoverService()
            ..images.complete([])
            ..cover.complete(null);
          final fixture = AppRuntimeWidgetTestFixture(
            providedPersistenceRepository: repository,
            coverArtworkCacheService: covers,
            libraryTreeSnapshotBuilder: (payload) async =>
                const LibraryOrganizer().buildTree(
                  tracks: payload.tracks,
                  watchedFolders: payload.watchedFolders,
                  watchedLibraries: payload.watchedLibraries,
                ),
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          const folder = 'C:/works/card-snapshot';
          final target = AudioDetailTarget.libraryRootFolder(folder);
          fixture.library.addWatchedFolder(folder, notify: false);
          fixture.library.addTracks([
            MusicTrack(
              path: '$folder/audio.mp3',
              displayName: 'audio.mp3',
              groupKey: folder,
              groupTitle: 'Card snapshot',
              groupSubtitle: '',
              isSingle: false,
            ),
          ], persist: false);
          await tester.runAsync(() async {
            await fixture.library.saveAudioDetail(
              AudioDetail.empty(target).copyWith(
                workTitle: 'Card title',
                circleName: 'Card circle',
                voiceActors: ['Card CV'],
                tags: ['Card tag'],
              ),
            );
            await fixture.library.audioLibraryCategorySnapshot();
            await fixture.library.loadLibraryFolderTree(folder);
            await _prewarmDirectory(fixture, folder);
          });
          // The main page still owns its snapshot after the detail cache clears.
          fixture.library.detailCacheService.clear();
          expect(fixture.library.resolvedAudioDetail(target), isNull);
          expect(
            fixture.library.categorySnapshot?.detailFor(target)?.workTitle,
            'Card title',
          );
          repository.detailRequests = 0;
          final interaction = UiInteractionCoordinator.instance;
          final source = Object();
          interaction.beginNavigation(source);
          addTearDown(() => interaction.cancelNavigation(source));

          await tester.pumpWidget(
            fixture.build(
              WorkDetailPage.forLocal(target: target),
              overrides: [
                workTextServiceProvider.overrideWithValue(
                  WorkTextService(
                    discoverImages:
                        fixture.library.discoverCoverImageReferencesInFolder,
                    platformGateway: _NestedWorkDetailFileGateway([]),
                  ),
                ),
              ],
            ),
          );
          await tester.pump();
          for (final value in ['Card title', 'Card circle']) {
            expect(find.text(value), findsOneWidget);
          }
          expect(find.text('Card CV'), findsOneWidget);
          expect(find.text('#Card tag'), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 500));
          expect(repository.detailRequests, 0);
          expect(covers.imageRequests, 0);
          expect(find.text('audio'), findsOneWidget);

          interaction.cancelNavigation(source);
          await _settleDetail(tester);
          expect(find.text('Card CV'), findsOneWidget);
          expect(find.text('#Card tag'), findsOneWidget);
          expect(find.text('audio'), findsOneWidget);
          expect(covers.imageRequests, 1);
          expect(repository.detailRequests, 0);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );

      _detailTestWidgets(
        'shows cached indexed tree immediately and reuses file snapshots on $platform',
        (tester) async {
          SharedPreferences.setMockInitialValues(const <String, Object>{});
          final covers = _ControlledWorkDetailCoverService();
          var treeRequests = 0;
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
            libraryTreeSnapshotBuilder: (payload) async {
              treeRequests++;
              return const LibraryOrganizer().buildTree(
                tracks: payload.tracks,
                watchedFolders: payload.watchedFolders,
                watchedLibraries: payload.watchedLibraries,
              );
            },
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          final interaction = UiInteractionCoordinator.instance;
          final source = Object();
          interaction.beginNavigation(source);
          addTearDown(() => interaction.cancelNavigation(source));
          const folderPath = 'C:/works/independent';
          final target = AudioDetailTarget.libraryRootFolder(folderPath);
          fixture.library.addWatchedFolder(folderPath, notify: false);
          fixture.library.addTracks([
            for (final name in ['audio.mp3', 'Extras/nested.mp3'])
              MusicTrack(
                path: '$folderPath/$name',
                displayName: name,
                groupKey: folderPath,
                groupTitle: 'Independent',
                groupSubtitle: '',
                isSingle: false,
              ),
          ], persist: false);
          await tester.runAsync(() async {
            await fixture.library.loadAudioDetail(target);
            await fixture.library.loadLibraryFolderTree(folderPath);
            await _prewarmDirectory(fixture, folderPath);
          });

          final textEntries = [
            {
              'name': 'notes.txt',
              'relativePath': 'notes.txt',
              'path': '$folderPath/notes.txt',
            },
          ];
          final textService = WorkTextService(
            discoverImages:
                fixture.library.discoverCoverImageReferencesInFolder,
            platformGateway: _NestedWorkDetailFileGateway(textEntries),
          );
          addTearDown(textService.dispose);
          Widget buildPage(Key key) => fixture.build(
            WorkDetailPage.forLocal(key: key, target: target),
            overrides: [workTextServiceProvider.overrideWithValue(textService)],
          );
          await tester.pumpWidget(buildPage(const ValueKey('initial')));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(
            find.text(fixture.languageProvider.tr('empty_folder')),
            findsNothing,
          );
          expect(covers.imageRequests, 0);
          expect(covers.coverRequests, 0);
          expect(treeRequests, 1);
          expect(find.text('audio'), findsOneWidget);
          expect(find.text('Extras'), findsOneWidget);
          expect(find.text('notes'), findsNothing);

          interaction.cancelNavigation(source);
          await tester.pump();
          await tester.pump();
          await _settleDetail(tester);
          final entryKeys = [
            const ValueKey('folder:Extras'),
            const ValueKey('audio:$folderPath/audio.mp3'),
            const ValueKey('text:notes.txt'),
          ];
          for (final key in entryKeys) {
            expect(find.byKey(key), findsOneWidget);
          }
          expect(treeRequests, 1, reason: 'Opening reuses the prepared tree.');
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.text('audio'), findsOneWidget);
          expect(covers.imageRequests, 1);
          expect(covers.coverRequests, 1);
          expect(find.text('notes'), findsOneWidget);
          expect(find.text('cover'), findsNothing);

          covers.images.complete(['$folderPath/cover.jpg']);
          await tester.pump();
          await tester.pump();
          await _settleDetail(tester);
          expect(find.text('cover'), findsOneWidget);
          expect(covers.cover.isCompleted, isFalse);

          covers.cachedCover = '$folderPath/cover.jpg';
          interaction.beginNavigation(source);
          await tester.pumpWidget(buildPage(const ValueKey('reopened')));
          expect(find.text('notes'), findsOneWidget);
          expect(find.text('cover'), findsOneWidget);
          expect(covers.imageRequests, 1);
          textEntries
            ..clear()
            ..add({
              'name': 'updated.txt',
              'relativePath': 'updated.txt',
              'path': '$folderPath/updated.txt',
            });
          interaction.cancelNavigation(source);
          await _settleDetail(tester);
          expect(find.text('notes'), findsNothing);
          expect(find.text('updated'), findsOneWidget);
          expect(covers.imageRequests, 2);
          expect(covers.coverRequests, 1, reason: 'Reuse the resolved cover.');
          covers.cover.complete(null);
          await _settleDetail(tester);
          final cover = tester.widget<LocalCoverImage>(
            find.byType(LocalCoverImage),
          );
          expect(cover.path, covers.cachedCover);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      _detailTestWidgets(
        'reopens local details at root with warm or cold tree on $platform',
        (tester) async {
          SharedPreferences.setMockInitialValues(const <String, Object>{});
          final covers = _ControlledWorkDetailCoverService()
            ..images.complete([])
            ..cover.complete(null);
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
            libraryTreeSnapshotBuilder: (payload) async =>
                const LibraryOrganizer().buildTree(
                  tracks: payload.tracks,
                  watchedFolders: payload.watchedFolders,
                ),
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          const folder = 'C:/works/page-cache';
          final target = AudioDetailTarget.libraryRootFolder(folder);
          fixture.library.addWatchedFolder(folder, notify: false);
          fixture.library.addTracks([
            for (var index = 0; index < 40; index++)
              MusicTrack(
                path: '$folder/Disc/$index.mp3',
                displayName: '$index.mp3',
                groupKey: folder,
                groupTitle: 'Page cache',
                groupSubtitle: '',
                isSingle: false,
              ),
          ], persist: false);
          await tester.runAsync(() async {
            await fixture.library.loadAudioDetail(target);
            await fixture.library.loadLibraryFolderTree(folder);
            await _prewarmDirectory(fixture, folder);
          });
          final states = BrowsePageStateStore();
          final textService = WorkTextService(
            discoverImages: (_) async => [],
            platformGateway: _NestedWorkDetailFileGateway([]),
          );
          addTearDown(textService.dispose);
          Widget build(Widget child) => fixture.build(
            child,
            overrides: [
              browsePageStateStoreProvider.overrideWithValue(states),
              workTextServiceProvider.overrideWithValue(textService),
            ],
          );
          Widget page(String key) =>
              WorkDetailPage.forLocal(key: ValueKey(key), target: target);
          await tester.pumpWidget(build(page('first')));
          await _settleDetail(tester);
          await tester.tap(find.text('Disc'));
          await _settleDetail(tester);
          final scroll = find.byType(CustomScrollView);
          await tester.drag(scroll, const Offset(0, -500));
          await _settleDetail(tester);
          final offset = tester
              .widget<CustomScrollView>(scroll)
              .controller!
              .offset;
          expect(offset, greaterThan(0));
          await tester.pumpWidget(build(const SizedBox()));
          await _settleDetail(tester);
          expect(
            states.stateFor(
              'work-detail:libraryRootFolder:c:/works/page-cache',
            ),
            isEmpty,
          );
          final interaction = UiInteractionCoordinator.instance;
          final source = Object();
          interaction.beginNavigation(source);
          addTearDown(() => interaction.cancelNavigation(source));
          await tester.pumpWidget(build(page('second')));
          await tester.pump();
          expect(find.byType(WorkDetailEntryTile), findsWidgets);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          interaction.cancelNavigation(source);
          await _settleDetail(tester);
          expect(tester.widget<CustomScrollView>(scroll).controller!.offset, 0);
          expect(
            tester
                .widgetList<WorkDetailEntryTile>(
                  find.byType(WorkDetailEntryTile),
                )
                .every((tile) => tile.item.type == WorkEntryType.folder),
            isTrue,
          );
          await tester.pumpWidget(build(const SizedBox()));
          await _settleDetail(tester);
          fixture.library.snapshotCacheService.clear();
          interaction.beginNavigation(source);
          await tester.pumpWidget(build(page('cold-reopen')));
          await tester.pump();
          expect(find.byType(WorkDetailEntryTile), findsNothing);
          interaction.cancelNavigation(source);
          await tester.pump();
          await _settleDetail(tester);
          expect(find.byType(WorkDetailEntryTile), findsWidgets);
          expect(tester.widget<CustomScrollView>(scroll).controller!.offset, 0);
          expect(
            tester
                .widgetList<WorkDetailEntryTile>(
                  find.byType(WorkDetailEntryTile),
                )
                .every((tile) => tile.item.type == WorkEntryType.folder),
            isTrue,
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    _detailTestWidgets('empty local tree keeps loading until file scans finish', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final covers = _ControlledWorkDetailCoverService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: covers,
      );
      _detailFixtures.add(fixture);
      addTearDown(fixture.dispose);
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath: 'C:/works/empty',
      );
      await tester.runAsync(() async {
        await fixture.library.loadAudioDetail(target);
        await fixture.library.loadLibraryTree();
      });
      await tester.pumpWidget(
        fixture.build(
          const WorkDetailPage.forLocal(target: target),
          overrides: [
            workTextServiceProvider.overrideWithValue(
              WorkTextService(
                discoverImages:
                    fixture.library.discoverCoverImageReferencesInFolder,
                platformGateway: _NestedWorkDetailFileGateway([]),
              ),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(covers.imageRequests, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.byKey(const ValueKey('work_detail_entries_skeleton')),
        findsOneWidget,
      );
      expect(
        find.text(fixture.languageProvider.tr('empty_folder')),
        findsNothing,
      );
      covers.images.complete([]);
      await _settleDetail(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.text(fixture.languageProvider.tr('empty_folder')),
        findsOneWidget,
      );
      expect(
        covers.cover.isCompleted,
        isFalse,
        reason: 'Cover discovery must not hold the file-tree loading state.',
      );
      covers.cover.complete(null);
      await _settleDetail(tester);
    });

    _detailTestWidgets(
      'local tree shows folders containing only text or image files',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);
        final root = (await tester.runAsync<Directory>(
          () => Directory.systemTemp.createTemp('work_non_audio_folders_'),
        ))!;
        addTearDown(() async {
          PaintingBinding.instance.imageCache
            ..clear()
            ..clearLiveImages();
          try {
            if (await root.exists()) await root.delete(recursive: true);
          } on FileSystemException {
            // A failed assertion can leave the image decoder alive briefly.
          }
        });
        final textDirectory = Directory(
          '${root.path}${Platform.pathSeparator}Scripts',
        );
        final imageDirectory = Directory(
          '${root.path}${Platform.pathSeparator}Gallery',
        );
        final textFile = File(
          '${textDirectory.path}${Platform.pathSeparator}notes.txt',
        );
        final imageFile = File(
          '${imageDirectory.path}${Platform.pathSeparator}cover.jpg',
        );
        await tester.runAsync(() async {
          await textDirectory.create();
          await imageDirectory.create();
          await textFile.writeAsString('notes');
          await imageFile.writeAsBytes(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
        });
        fixture.library.addWatchedFolder(root.path, notify: false);

        await tester.pumpWidget(
          fixture.build(
            WorkDetailPage.forLocal(
              target: AudioDetailTarget.libraryRootFolder(root.path),
            ),
            overrides: [
              workTextServiceProvider.overrideWithValue(
                WorkTextService(
                  discoverImages:
                      fixture.library.discoverCoverImageReferencesInFolder,
                  platformGateway: _NestedWorkDetailFileGateway([
                    {
                      'name': 'notes.txt',
                      'relativePath': 'Scripts/notes.txt',
                      'path': textFile.path,
                    },
                  ]),
                ),
              ),
            ],
          ),
        );

        for (
          var i = 0;
          i < 40 &&
              (find.text('Scripts').evaluate().isEmpty ||
                  find.text('Gallery').evaluate().isEmpty);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }

        expect(find.text('Scripts'), findsOneWidget);
        expect(find.text('Gallery'), findsOneWidget);

        final folderMore = find.byKey(
          const ValueKey<String>('work_entry_more_Scripts'),
        );
        expect(folderMore, findsOneWidget);
        await tester.tap(folderMore);
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.text(fixture.languageProvider.tr('rename')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('audio_detail_rename_file')),
          findsNothing,
        );
        await tester.tapAt(Offset.zero);
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('Scripts'));
        await _settleDetail(tester);
        expect(find.text('notes'), findsOneWidget);

        await tester.tap(
          find.text(fixture.languageProvider.tr('root_directory')),
        );
        await _settleDetail(tester);
        await tester.tap(find.text('Gallery'));
        await _settleDetail(tester);
        expect(find.text('cover'), findsOneWidget);
      },
    );

    _detailTestWidgets('local text and image entries use contextual more menus', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      _detailFixtures.add(fixture);
      addTearDown(fixture.dispose);
      final root = (await tester.runAsync<Directory>(
        () => Directory.systemTemp.createTemp('work_actions_'),
      ))!;
      addTearDown(() async {
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } on FileSystemException {
          // A failed assertion can leave the image decoder alive briefly.
        }
      });
      final textFile = File('${root.path}${Platform.pathSeparator}notes.txt');
      final imageFile = File('${root.path}${Platform.pathSeparator}cover.jpg');
      await tester.runAsync(() async {
        await textFile.writeAsString('notes');
        await imageFile.writeAsBytes(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
      });
      fixture.library.addWatchedFolder(root.path, notify: false);
      final target = AudioDetailTarget.libraryRootFolder(root.path);

      await tester.pumpWidget(
        fixture.build(
          WorkDetailPage.forLocal(target: target),
          overrides: [
            workTextServiceProvider.overrideWithValue(
              WorkTextService(
                discoverImages:
                    fixture.library.discoverCoverImageReferencesInFolder,
                platformGateway: _WorkDetailFileGateway(textFile),
              ),
            ),
          ],
        ),
      );
      for (
        var i = 0;
        i < 40 &&
            (find.text('notes').evaluate().isEmpty ||
                find
                    .byKey(const ValueKey<String>('work_entry_more_cover.jpg'))
                    .evaluate()
                    .isEmpty);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }

      final textMore = find.byKey(
        const ValueKey<String>('work_entry_more_notes.txt'),
      );
      final imageMore = find.byKey(
        const ValueKey<String>('work_entry_more_cover.jpg'),
      );
      expect(textMore, findsOneWidget);
      expect(imageMore, findsOneWidget);

      await tester.tap(imageMore);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(fixture.languageProvider.tr('rename')), findsOneWidget);
      expect(
        find.text(fixture.languageProvider.tr('audio_detail_set_cover')),
        findsOneWidget,
      );
      await tester.tapAt(Offset.zero);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(textMore);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.text(fixture.languageProvider.tr('audio_detail_set_cover')),
        findsNothing,
      );
      expect(find.text(fixture.languageProvider.tr('rename')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });

    for (final fromLibrary in [false, true]) {
      _detailTestWidgets(
        '${fromLibrary ? 'library' : 'folder'} audio and video menus add one item and remove with undo',
        (tester) async {
          SharedPreferences.setMockInitialValues(const <String, Object>{});
          final covers = _ControlledWorkDetailCoverService()
            ..images.complete([])
            ..cover.complete(null);
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          var prepareCount = 0;
          var playSucceeds = true;
          fixture.playback.detachCommandPort();
          fixture.playback.attachPlaybackCommands(
            prepareSession:
                (
                  session, {
                  required nextPath,
                  autoPlay = true,
                  forceStartAtZero = false,
                  showLoading = true,
                  targetQueueIndex,
                }) async {
                  prepareCount++;
                  session.currentTrackPath = nextPath;
                  return playSucceeds;
                },
            pauseSession: (_) async {},
            startSession: (_, {required shouldStartTriggerCountdown}) async =>
                true,
            resolveAdvance: (_, {required forward}) => null,
            hasAdjacent: (_, {required forward}) => false,
          );
          await tester.binding.setSurfaceSize(const Size(1000, 1200));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          const folderPath = '/library/menu-work';
          const target = AudioDetailTarget(
            targetType: AudioDetailTargetType.libraryRootFolder,
            targetPath: folderPath,
          );
          final tracks = [
            for (final video in [false, true])
              MusicTrack(
                path: '$folderPath/${video ? 'video.mp4' : 'audio.mp3'}',
                displayName: video ? 'Video entry' : 'Audio entry',
                groupKey: folderPath,
                groupTitle: 'Menu work',
                groupSubtitle: '',
                isSingle: false,
                isVideo: video,
              ),
          ];
          if (fromLibrary) {
            fixture.library.addWatchedLibrary(folderPath, notify: false);
          } else {
            fixture.library.addWatchedFolder(folderPath, notify: false);
          }
          final removalLabel = fixture.languageProvider.tr(
            fromLibrary ? 'exclude' : 'remove',
          );
          final absentLabel = fixture.languageProvider.tr(
            fromLibrary ? 'remove' : 'exclude',
          );
          fixture.library.addTracks(tracks, persist: false);
          await tester.runAsync(() => fixture.library.loadAudioDetail(target));
          await tester.pumpWidget(
            fixture.build(const WorkDetailPage.forLocal(target: target)),
          );
          for (
            var i = 0;
            i < 40 && find.text('Audio entry').evaluate().isEmpty;
            i++
          ) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(find.text('Audio entry'), findsOneWidget);
          expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
          expect(find.byIcon(Icons.more_vert_rounded), findsNWidgets(2));
          final more = find.byKey(
            ValueKey('work_entry_more_${tracks.first.path}'),
          );
          await tester.tap(more);
          await _settleDetail(tester);
          expect(find.text(fixture.languageProvider.tr('play')), findsOneWidget);
          expect(find.text(removalLabel), findsOneWidget);
          expect(find.text(absentLabel), findsNothing);
          expect(
            find.text(fixture.languageProvider.tr('rename')),
            findsOneWidget,
          );
          await tester.tap(
            find.text(fixture.languageProvider.tr('detail_add_to_queue')),
          );
          await _settleDetail(tester);
          expect(fixture.playback.sessions.length, 1);
          expect(fixture.playback.sessions.values.single.isTemporary, isFalse);
          expect(
            fixture.playback.sessions.values.single.effectivePlaying,
            isFalse,
          );
          expect(
            fixture.playback.sessions.values.single.currentTrackPath,
            tracks.first.path,
          );
          expect(prepareCount, 0);

          await tester.tap(find.text('Video entry'));
          await _settleDetail(tester);
          expect(prepareCount, 1);
          expect(fixture.playback.sessions.length, 2);
          final temporary = fixture.playback.sessions.values.singleWhere(
            (session) => session.isTemporary,
          );
          expect(temporary.currentTrackPath, tracks.last.path);
          expect(temporary.customQueueTracks?.length, 2);

          await tester.tap(more);
          await _settleDetail(tester);
          await tester.tap(find.text(removalLabel));
          await _settleDetail(tester);
          expect(find.text('Audio entry'), findsNothing);
          expect(find.text('Video entry'), findsOneWidget);
          await fixture.undoableRemovalService.undoPending();
          await _settleDetail(tester);
          expect(find.text('Audio entry'), findsOneWidget);
          playSucceeds = false;
          await tester.tap(find.text('Video entry'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(prepareCount, 2);
          expect(
            find.textContaining(
              fixture.languageProvider.tr('operation_failed_retry'),
            ),
            findsOneWidget,
          );

          if (defaultTargetPlatform == TargetPlatform.windows) {
            await tester.tap(
              find.text('Audio entry'),
              buttons: kSecondaryMouseButton,
              kind: PointerDeviceKind.mouse,
            );
          } else {
            await tester.tap(more);
          }
          await _settleDetail(tester);
          await tester.tap(find.text(removalLabel));
          await _settleDetail(tester);
          expect(find.text('Audio entry'), findsNothing);
          final failures = await tester.runAsync(
            fixture.undoableRemovalService.commitPending,
          );
          await _settleDetail(tester);
          expect(failures, 0);
          expect(fixture.library.trackByPath(tracks.first.path), isNull);
          expect(find.text('Audio entry'), findsNothing);
          expect(find.text('Video entry'), findsOneWidget);
          playSucceeds = true;
          await tester.tap(find.text('Video entry'));
          await _settleDetail(tester);
          expect(temporary.customQueueTracks?.map((track) => track.path), [
            tracks.last.path,
          ]);
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.windows,
        }),
      );
    }

    _detailTestWidgets(
      'renders local work detail header, pinned RJ row and action buttons',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture(
          asmrMetadataService: _WorkDetailAsmrMetadataService(),
        );
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);

        const folderPath = r'C:\library\RJ123456 - Test Work';
        const target = AudioDetailTarget(
          targetType: AudioDetailTargetType.libraryRootFolder,
          targetPath: folderPath,
        );

        final detail = AudioDetail(
          target: target,
          rjCode: 'RJ123456',
          workTitle: 'Test Local Work Title',
          circleName: 'Test Circle',
          voiceActors: const <String>['CV Alice', 'CV Bob'],
          tags: const <String>['ASMR', 'Ear Cleaning', 'Whisper'],
        );
        await tester.runAsync(
          () => fixture.runtimeGraph.library.saveAudioDetail(detail),
        );

        await tester.pumpWidget(
          fixture.build(const WorkDetailPage.forLocal(target: target)),
        );
        for (
          var i = 0;
          i < 20 &&
              find
                  .byKey(const ValueKey('work_detail_entries_skeleton'))
                  .evaluate()
                  .isNotEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pump();

        final headerCover = tester.widget<AsyncLocalCoverImage>(
          find.byType(AsyncLocalCoverImage).first,
        );
        expect(
          coverCacheWidth(
            resolution: fixture.settings.coverImageResolution,
            cacheWidth: headerCover.cacheWidth,
            useDefaultCacheWidth: headerCover.useDefaultCacheWidth,
          ),
          coverCacheWidthForResolution(fixture.settings.coverImageResolution),
          reason: 'The work header must reuse the library card decode size.',
        );
        // Top-left floating back button
        expect(
          find.byKey(const ValueKey<String>('work_detail_back_button')),
          findsOneWidget,
        );
        final editButton = find.byKey(
          const ValueKey<String>('work_detail_edit'),
        );
        expect(editButton, findsOneWidget);
        expect(
          find.descendant(
            of: editButton,
            matching: find.text(fixture.languageProvider.tr('edit')),
          ),
          findsNothing,
        );
        expect(tester.widget<IconButton>(editButton).tooltip, isNotEmpty);
        expect(
          find.ancestor(
            of: editButton,
            matching: find.byType(HeaderFloatingButton),
          ),
          findsOneWidget,
        );
        final backFloatingButton = find.ancestor(
          of: find.byKey(const ValueKey<String>('work_detail_back_button')),
          matching: find.byType(HeaderFloatingButton),
        );
        final editFloatingButton = find.ancestor(
          of: editButton,
          matching: find.byType(HeaderFloatingButton),
        );
        expect(
          tester.getSize(editFloatingButton),
          tester.getSize(backFloatingButton),
        );
        expect(
          tester
              .widgetList<HeaderFloatingSurface>(
                find.byType(HeaderFloatingSurface),
              )
              .map((surface) => surface.backgroundOpacity),
          everyElement(0.5),
        );
        final header = find.byKey(const ValueKey('work_detail_page_header'));
        expect(
          find.descendant(
            of: header,
            matching: find.text(fixture.languageProvider.tr('audio_detail_title')),
          ),
          findsNothing,
        );
        expect(
          find.descendant(of: header, matching: find.byType(HeaderFloatingSurface)),
          findsNWidgets(3),
        );

        expect(find.text('Test Local Work Title'), findsOneWidget);
        expect(find.text('RJ123456 - Test Work'), findsNothing);
        await tester.runAsync(
          () => fixture.settings.setWorkNameDisplay(WorkNameDisplay.folderName),
        );
        await tester.pump();
        expect(find.text('RJ123456 - Test Work'), findsOneWidget);
        expect(find.text('Test Local Work Title'), findsNothing);

        // Pinned RJ | Circle row
        expect(find.text('RJ123456'), findsOneWidget);
        expect(find.text('Test Circle'), findsOneWidget);

        // CVs & Tags
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
        await _settleDetail(tester);
        expect(find.text('CV Alice'), findsOneWidget);
        expect(find.text('CV Bob'), findsOneWidget);
        expect(find.text('#ASMR'), findsOneWidget);
        expect(find.text('#Ear Cleaning'), findsOneWidget);
        expect(find.text('#Whisper'), findsOneWidget);

        // Local action buttons: 补充信息, 下载
        expect(
          find.byKey(const ValueKey<String>('work_detail_fetch_info')),
          findsOneWidget,
        );
        expect(
          tester
              .getRect(
                find.byKey(const ValueKey<String>('work_detail_fetch_info')),
              )
              .height,
          greaterThanOrEqualTo(46),
        );
        expect(
          find.byKey(const ValueKey<String>('work_detail_download')),
          findsOneWidget,
        );
        expect(
          tester
              .getRect(
                find.byKey(const ValueKey<String>('work_detail_download')),
              )
              .height,
          greaterThanOrEqualTo(46),
        );
        expect(
          find.byKey(const ValueKey<String>('work_detail_pin')),
          findsNothing,
        );

        await tester.tap(editButton);
        await _settleDetail(tester);

        expect(find.byType(DlsiteMetadataReviewPage), findsOneWidget);
        expect(
          find.text(fixture.languageProvider.tr('audio_detail_edit_info')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('dlsite_save_cover')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey<String>('dlsite_review_confirm')),
            matching: find.text(fixture.languageProvider.tr('save')),
          ),
          findsOneWidget,
        );

        final fieldKeys = <String>[
          'audio_detail_folder_name',
          'audio_detail_work_title',
          'audio_detail_rj_code',
          'audio_detail_circle_name',
          'audio_detail_voice_actors',
          'audio_detail_tags',
          'audio_detail_release_date',
          'card_info_duration',
          'audio_detail_rating',
        ];
        final editList = find.descendant(
          of: find.byType(DlsiteMetadataReviewPage),
          matching: find.byType(ListView),
        );
        for (final fieldKey in fieldKeys) {
          final field = find.byKey(ValueKey<String>('metadata_edit_$fieldKey'));
          for (var i = 0; i < 20 && field.evaluate().isEmpty; i++) {
            await tester.drag(editList, const Offset(0, -200));
            await tester.pump();
          }
          final textField = tester.widget<TextField>(
            find.descendant(of: field, matching: find.byType(TextField)),
          );
          expect(
            textField.decoration?.labelText,
            fixture.languageProvider.tr(fieldKey),
          );
          if (fieldKey == 'audio_detail_work_title') {
            await tester.enterText(
              find.descendant(of: field, matching: find.byType(TextField)),
              'Edited local work title',
            );
            tester.testTextInput.hide();
            await tester.pump();
          }
        }
        await tester.tap(
          find.byKey(const ValueKey<String>('dlsite_review_confirm')),
        );
        for (
          var i = 0;
          i < 80 && find.byType(DlsiteMetadataReviewPage).evaluate().isNotEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pump();

        expect(find.byType(WorkDetailPage), findsOneWidget);
        final savedDetail = await tester.runAsync(
          () => fixture.runtimeGraph.library.loadAudioDetail(target),
        );
        expect(savedDetail?.detail.workTitle, 'Edited local work title');

        await tester.tap(
          find.byKey(const ValueKey<String>('work_detail_fetch_info')),
        );
        await _settleDetail(tester);

        expect(find.byType(DlsiteMetadataReviewPage), findsOneWidget);
        expect(find.text('Fetched work title'), findsOneWidget);
      },
    );

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      for (final hasSubtitle in [false, true]) {
        _detailTestWidgets(
          'local work subtitle status reflects all subfolders, subtitles=$hasSubtitle on $platform',
          (tester) async {
            final covers = _ControlledWorkDetailCoverService()
              ..images.complete([])
              ..cover.complete(null);
            final fixture = AppRuntimeWidgetTestFixture(
              coverArtworkCacheService: covers,
            );
            _detailFixtures.add(fixture);
            addTearDown(fixture.dispose);
            const folder = 'C:/作品/字幕状态';
            final target = AudioDetailTarget.libraryRootFolder(folder);
            fixture.library.addWatchedFolder(folder, notify: false);
            fixture.library.addTracks([
              MusicTrack(
                path: '$folder/audio.mp3',
                displayName: 'Audio',
                groupKey: folder,
                groupTitle: 'Work',
                groupSubtitle: '',
                isSingle: false,
              ),
            ], persist: false);
            final textService = WorkTextService(
              platformGateway: _NestedWorkDetailFileGateway([
                {
                  'name': 'notes.txt',
                  'relativePath': 'notes.txt',
                  'path': '$folder/notes.txt',
                },
                if (hasSubtitle)
                  {
                    'name': 'translation.SRT',
                    'relativePath': 'Extras/字幕/translation.SRT',
                    'path': 'content://provider/document/123',
                  },
              ]),
              discoverImages: (_) async => const [],
            );
            addTearDown(textService.dispose);
            await tester.pumpWidget(
              fixture.build(
                WorkDetailPage.forLocal(target: target),
                overrides: [
                  workTextServiceProvider.overrideWithValue(textService),
                ],
              ),
            );
            await _settleDetail(tester);
            final status = find.byKey(
              const ValueKey('work_detail_subtitle_status'),
            );
            expect(status, findsOneWidget);
            expect(
              find.descendant(
                of: status,
                matching: find.text(
                  fixture.languageProvider.tr(
                    hasSubtitle ? 'asmr_has_subtitle' : 'asmr_no_subtitle',
                  ),
                ),
              ),
              findsOneWidget,
            );
            expect(
              find.byIcon(
                hasSubtitle
                    ? Icons.subtitles_rounded
                    : Icons.subtitles_off_rounded,
              ),
              findsOneWidget,
            );
            expect(find.text('translation'), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          variant: TargetPlatformVariant.only(platform),
        );
      }
    }

    _detailTestWidgets('renders ASMR.ONE work detail header and actions', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(null);
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      _detailFixtures.add(fixture);
      addTearDown(fixture.dispose);

      final asmrWork = AsmrWork(
        id: 9999,
        title: 'ASMR Remote Work Title',
        circleName: 'Remote Circle',
        sourceId: 'RJ009999',
        sourceType: 'asmr',
        sourceUrl: '',
        coverUrl: '',
        thumbnailUrl: '',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: const <String>['Remote CV'],
        tags: const <String>['Roleplay'],
        hasSubtitle: true,
      );

      await tester.pumpWidget(
        fixture.build(WorkDetailPage.forAsmr(work: asmrWork)),
      );
      await tester.pump();
      await _settleDetail(tester);

      // Title & pinned row
      expect(find.text('ASMR Remote Work Title'), findsOneWidget);
      expect(find.text('RJ009999'), findsOneWidget);
      expect(find.text('Remote Circle'), findsOneWidget);
      expect(
        find.text(fixture.languageProvider.tr('asmr_has_subtitle')),
        findsOneWidget,
      );
      final subtitleStatus = find.text(
        fixture.languageProvider.tr('asmr_has_subtitle'),
      );
      final statusIndicator = find.byKey(
        const ValueKey<String>('work_detail_subtitle_status'),
      );
      expect(
        find.ancestor(
          of: subtitleStatus,
          matching: find.byType(HeaderFloatingSurface),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: statusIndicator,
          matching: find.byIcon(Icons.subtitles_rounded),
        ),
        findsOneWidget,
      );
      expect(
        tester.getRect(statusIndicator).center.dy,
        tester.getRect(find.text('RJ009999')).center.dy,
      );
      expect(
        tester.getRect(statusIndicator).center.dy,
        tester.getRect(find.text('Remote Circle')).center.dy,
      );
      expect(tester.getRect(statusIndicator).right, 304);
      expect(
        tester.getRect(statusIndicator).left,
        greaterThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey('work_detail_circle_copy')))
              .right,
        ),
      );
      final translationButton = find.ancestor(
        of: find.byKey(const ValueKey<String>('work_detail_translation')),
        matching: find.byType(HeaderFloatingButton),
      );
      expect(
        tester.getRect(statusIndicator).top,
        greaterThan(tester.getRect(translationButton).bottom),
      );
      expect(tester.getRect(translationButton).right, 304);
      expect(
        tester
            .widgetList<HeaderFloatingSurface>(
              find.byType(HeaderFloatingSurface),
            )
            .map((surface) => surface.backgroundOpacity),
        everyElement(0.5),
      );
      expect(find.text('|'), findsOneWidget);
      expect(tester.widget<Text>(find.text('RJ009999')).style?.fontSize, 13);
      expect(
        tester.widget<Text>(find.text('Remote Circle')).style?.fontSize,
        13,
      );
      final highlightedStyle = tester.widget<Text>(subtitleStatus).style!;
      expect(
        highlightedStyle.color,
        isNot(
          Theme.of(tester.element(subtitleStatus)).colorScheme.onSurfaceVariant,
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('work_detail_edit')),
        findsNothing,
      );

      // CV & tags
      expect(find.text('Remote CV'), findsOneWidget);
      expect(find.text('#Roleplay'), findsOneWidget);
      expect(find.text('根目录'), findsOneWidget);

      // ASMR.ONE buttons: 下载, 收藏/取消收藏
      expect(
        find.byKey(const ValueKey<String>('asmr_work_detail_download')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('asmr_work_detail_favorite')),
        findsOneWidget,
      );
    });

    _detailTestWidgets('back button navigates back', (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      _detailFixtures.add(fixture);
      addTearDown(fixture.dispose);

      final asmrWork = AsmrWork(
        id: 8888,
        title: 'Nav Work',
        circleName: 'Nav Circle',
        sourceId: 'RJ008888',
        sourceType: 'asmr',
        sourceUrl: '',
        coverUrl: '',
        thumbnailUrl: '',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: const <String>[],
        tags: const <String>[],
      );

      await tester.pumpWidget(
        fixture.build(
          Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              WorkDetailPage.forAsmr(work: asmrWork),
                        ),
                      );
                    },
                    child: const Text('Go'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Go'));
      await tester.pump();
      await _settleDetail(tester);

      expect(
        find.text(fixture.languageProvider.tr('asmr_no_subtitle')),
        findsOneWidget,
      );
      final noSubtitleStatus = find.text(
        fixture.languageProvider.tr('asmr_no_subtitle'),
      );
      expect(
        find.ancestor(
          of: noSubtitleStatus,
          matching: find.byType(HeaderFloatingSurface),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('work_detail_subtitle_status')),
          matching: find.byIcon(Icons.subtitles_off_rounded),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(noSubtitleStatus).style?.color,
        Theme.of(tester.element(noSubtitleStatus)).colorScheme.onSurfaceVariant,
      );
      expect(
        tester.getRect(noSubtitleStatus).center.dy,
        tester.getRect(find.text('RJ008888')).center.dy,
      );

      expect(
        find.byKey(const ValueKey<String>('work_detail_back_button')),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey<String>('work_detail_back_button')),
          matching: find.byType(HeaderFloatingButton),
        ),
        findsOneWidget,
      );

      expect(
        ModalRoute.of(
          tester.element(find.byKey(const ValueKey('work_detail_back_button'))),
        )!.animation!.status,
        AnimationStatus.completed,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('work_detail_back_button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Go'), findsOneWidget);
    });

    _detailTestWidgets(
      'tags render in capsule style and clicking a tag copies to clipboard',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);

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
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        final asmrWork = AsmrWork(
          id: 123456,
          title: 'Work with tags',
          circleName: 'Circle',
          sourceId: 'RJ123456',
          sourceType: 'asmr',
          sourceUrl: '',
          coverUrl: '',
          thumbnailUrl: '',
          mainCoverUrl: '',
          releaseDate: null,
          createDate: null,
          duration: Duration.zero,
          dlCount: 0,
          reviewCount: 0,
          rating: 0,
          voiceActors: const <String>['CV1'],
          tags: const <String>['耳かき', '#癒やし'],
        );

        await tester.pumpWidget(
          fixture.build(WorkDetailPage.forAsmr(work: asmrWork)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('#耳かき'), findsOneWidget);
        expect(find.text('#癒やし'), findsOneWidget);

        await tester.tap(find.text('#耳かき'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(copied, contains('耳かき'));

        await tester.tap(find.text('#癒やし'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(copied, contains('癒やし'));
      },
    );

    for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
      _detailTestWidgets(
        'WorkDetailPage hides scrollbars on $platform and remains scrollable',
        (tester) async {
          SharedPreferences.setMockInitialValues(const <String, Object>{});
          final fixture = AppRuntimeWidgetTestFixture();
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);

          const folderPath = 'C:/works/no-scrollbar';
          const target = AudioDetailTarget(
            targetType: AudioDetailTargetType.libraryRootFolder,
            targetPath: folderPath,
          );
          final tracks = [
            for (var i = 1; i <= 30; i++)
              MusicTrack(
                path: '$folderPath/track_$i.mp3',
                displayName: 'Track $i',
                groupKey: folderPath,
                groupTitle: 'No Scrollbar Work',
                groupSubtitle: '',
                isSingle: false,
              ),
          ];
          fixture.library.addWatchedFolder(folderPath, notify: false);
          fixture.library.addTracks(tracks, persist: false);

          await tester.pumpWidget(
            fixture.build(const WorkDetailPage.forLocal(target: target)),
          );
          for (
            var i = 0;
            i < 40 && find.text('Track 1').evaluate().isEmpty;
            i++
          ) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }

          expect(find.byType(WorkDetailPage), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(WorkDetailPage),
              matching: find.byType(RawScrollbar),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byType(WorkDetailPage),
              matching: find.byType(DragOnlyScrollbar),
            ),
            findsNothing,
          );

          final customScrollView = find.descendant(
            of: find.byType(WorkDetailPage),
            matching: find.byType(CustomScrollView),
          );
          expect(customScrollView, findsOneWidget);

          final scrollable = tester.widget<Scrollable>(
            find
                .descendant(
                  of: customScrollView,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          final scrollController = scrollable.controller!;
          expect(scrollController.offset, 0);

          await tester.drag(customScrollView, const Offset(0, -400));
          await _settleDetail(tester);
          expect(scrollController.offset, greaterThan(0));
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  });

  group('WorkImageViewerPage', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      _detailTestWidgets(
        'fullscreen fills the window and preserves paging and zoom on $platform',
        (tester) async {
          await tester.binding.setSurfaceSize(null);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(1280, 800);
          addTearDown(tester.view.reset);
          final fixture = AppRuntimeWidgetTestFixture();
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          final pane = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            fixture.build(
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 480,
                  child: MediaQuery(
                    data: const MediaQueryData(size: Size(480, 800)),
                    child: ClipRect(
                      child: Navigator(
                        key: pane,
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (_) =>
                              const Scaffold(body: Text('Work detail')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          unawaited(
            pane.currentState!.push(
              buildAppPageRoute<void>(
                context: pane.currentContext!,
                child: const WorkImageViewerPage(
                  initialIndex: 1,
                  images: [
                    WorkImageItem(name: '1.jpg', path: '/covers/1.jpg'),
                    WorkImageItem(name: '2.jpg', path: '/covers/2.jpg'),
                    WorkImageItem(name: '3.jpg', path: '/covers/3.jpg'),
                  ],
                ),
              ),
            ),
          );
          for (var frame = 0; frame < 6; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          final viewport = find.byKey(const ValueKey('work_image_viewport'));
          final fullscreen = find.byKey(
            const ValueKey('image_viewer_fullscreen_button'),
          );
          Rect viewerRect() => tester.getRect(
            find.ancestor(of: viewport, matching: find.byType(Scaffold)).first,
          );
          final originalRect = viewerRect();
          expect(originalRect, const Rect.fromLTWH(800, 0, 480, 800));
          expect(
            tester.getCenter(fullscreen).dx,
            lessThan(originalRect.left + 80),
          );
          expect(tester.getCenter(fullscreen).dy, greaterThan(700));
          expect(find.text('2 / 3'), findsOneWidget);
          final viewportElement = tester.element(viewport);
          final image = find
              .descendant(
                of: viewport,
                matching: find.byType(InteractiveViewer),
              )
              .hitTestable()
              .first;
          final imageState = tester.state(image);
          Future<void> finishFullscreenFade() async {
            for (var frame = 0; frame < 8; frame++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
          }
          final transform = tester
              .widget<InteractiveViewer>(image)
              .transformationController!;
          transform.value = Matrix4.diagonal3Values(2, 2, 1);
          await tester.pump();
          await tester.tap(fullscreen);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 150));
          final fade = tester.widget<FadeTransition>(find.byKey(
            const ValueKey('work_image_fullscreen_fade'),
          ));
          expect(fade.opacity.value, inExclusiveRange(0, 1));
          expect(viewerRect(), originalRect);
          await finishFullscreenFade();
          expect(viewerRect(), const Rect.fromLTWH(0, 0, 1280, 800));
          expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
          expect(tester.element(viewport), same(viewportElement));
          expect(tester.state(image), same(imageState));
          expect(transform.value.getMaxScaleOnAxis(), 2);
          await tester.tap(fullscreen);
          await tester.pump();
          await finishFullscreenFade();
          expect(viewerRect(), originalRect);
          expect(tester.element(viewport), same(viewportElement));
          expect(transform.value.getMaxScaleOnAxis(), 2);
          // A second tap while fading merges into the latest inline target.
          await tester.tap(fullscreen);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 150));
          final reversedOpacity = fade.opacity.value;
          expect(reversedOpacity, inExclusiveRange(0, 1));
          await tester.tap(fullscreen);
          await tester.pump();
          expect(fade.opacity.value, reversedOpacity);
          await tester.pump(const Duration(milliseconds: 75));
          expect(fade.opacity.value, greaterThan(reversedOpacity));
          expect(viewerRect(), originalRect);
          await finishFullscreenFade();
          expect(viewerRect(), originalRect);
          expect(tester.element(viewport), same(viewportElement));
          expect(transform.value.getMaxScaleOnAxis(), 2);
          await tester.tap(fullscreen);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 301));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 150));
          expect(viewerRect(), const Rect.fromLTWH(0, 0, 1280, 800));
          final enteringOpacity = fade.opacity.value;
          expect(enteringOpacity, inExclusiveRange(0, 1));
          await tester.tap(fullscreen);
          await tester.pump();
          expect(fade.opacity.value, enteringOpacity);
          await tester.pump(const Duration(milliseconds: 75));
          expect(fade.opacity.value, lessThan(enteringOpacity));
          await finishFullscreenFade();
          expect(viewerRect(), originalRect);
          expect(tester.element(viewport), same(viewportElement));
          await tester.tap(fullscreen);
          await finishFullscreenFade();
          await tester.tap(
            find.byKey(const ValueKey('image_viewer_next_button')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('3 / 3'), findsOneWidget);
          await pane.currentState!.maybePop();
          await tester.pump();
          await finishFullscreenFade();
          expect(viewerRect(), originalRect);
          expect(find.text('3 / 3'), findsOneWidget);
          expect(pane.currentState!.canPop(), isTrue);
          await tester.tap(fullscreen);
          await tester.pump();
          // Destroying the owning route also removes the full-window overlay.
          pane.currentState!.pop();
          for (var frame = 0; frame < 6; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            find.byKey(const ValueKey('work_image_viewport')),
            findsNothing,
          );
          expect(find.text('Work detail'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }

    _detailTestWidgets(
      'portrait hides fullscreen and rotation restores the original region',
      (tester) async {
        await tester.binding.setSurfaceSize(null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 820);
        addTearDown(tester.view.reset);
        final fixture = AppRuntimeWidgetTestFixture();
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const WorkImageViewerPage(
              images: [WorkImageItem(name: '1.jpg', path: '/covers/1.jpg')],
            ),
          ),
        );
        await tester.pump();
        final fullscreen = find.byKey(
          const ValueKey('image_viewer_fullscreen_button'),
        );
        expect(fullscreen, findsNothing);
        tester.view.physicalSize = const Size(820, 390);
        await tester.pump();
        await tester.tap(fullscreen);
        await tester.pump();
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
        tester.view.physicalSize = const Size(390, 820);
        await tester.pump();
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump();
        expect(fullscreen, findsNothing);
        expect(
          find.byKey(const ValueKey('work_image_viewport')),
          findsOneWidget,
        );
        tester.view.physicalSize = const Size(820, 390);
        await tester.pump();
        expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      for (final reduceMotion in [false, true]) {
        _detailTestWidgets(
          'library motion: image navigation retains rapid targets and follows manual dragging ($reduceMotion)',
          (tester) async {
            final fixture = AppRuntimeWidgetTestFixture();
            _detailFixtures.add(fixture);
            addTearDown(fixture.dispose);
            final images = [
              for (var i = 0; i < 5; i++)
                WorkImageItem(name: '$i.jpg', path: '/covers/$i.jpg'),
            ];
            await tester.pumpWidget(
              fixture.build(
                Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(disableAnimations: reduceMotion),
                    child: WorkImageViewerPage(images: images),
                  ),
                ),
              ),
            );
            await tester.pump();
            final viewport = find.byKey(const ValueKey('work_image_viewport'));
            final controller = tester.widget<PageView>(viewport).controller!;
            final initialPage = controller.page!.round();
            final next = find.byKey(const ValueKey('image_viewer_next_button'));
            await tester.tap(next);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 40));
            await tester.tap(next);
            await tester.pump();
            if (!reduceMotion) {
              for (
                var i = 0;
                i < 30 && controller.page! < initialPage + 0.6;
                i++
              ) {
                await tester.pump(const Duration(milliseconds: 10));
              }
            }
            await tester.tap(next);
            await tester.pump();
            if (reduceMotion) expect(controller.page, initialPage + 3);
            await tester.pump(const Duration(milliseconds: 400));
            expect(controller.page, initialPage + 3);
            expect(find.text('4 / 5'), findsOneWidget);

            // A user drag interrupts the pending button target and becomes the
            // baseline for the next command, including looped image indices.
            await tester.tap(next);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 40));
            await tester.drag(viewport, const Offset(500, 0));
            await tester.pump(const Duration(milliseconds: 400));
            final draggedPage = controller.page!.round();
            await tester.tap(next);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(controller.page, draggedPage + 1);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          variant: TargetPlatformVariant({platform}),
        );
      }

      _detailTestWidgets(
        'breadcrumbs keep the file list stationary when changing directory depth',
        (tester) async {
          final fixture = AppRuntimeWidgetTestFixture();
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          for (final scale in [1.0, 1.5]) {
            Widget page(List<String> segments) => fixture.build(
              MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: SizedBox(
                  width: 240,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      WorkDetailBreadcrumbs(
                        segments: segments,
                        entryCount: 1,
                        i18n: fixture.languageProvider,
                        onNavigate: (_) {},
                      ),
                      const SizedBox(
                        key: ValueKey('breadcrumb-file-list'),
                        height: 48,
                      ),
                    ],
                  ),
                ),
              ),
            );
            await tester.pumpWidget(page([]));
            final rootBounds = tester.getRect(
              find.byType(WorkDetailBreadcrumbs),
            );
            final fileList = find.byKey(const ValueKey('breadcrumb-file-list'));
            final rootListTop = tester.getTopLeft(fileList);
            for (final segments in [
              ['first long directory'],
              ['first long directory', 'second long directory'],
              <String>[],
            ]) {
              await tester.pumpWidget(page(segments));
              await tester.pump(const Duration(milliseconds: 250));
              expect(
                tester.getRect(find.byType(WorkDetailBreadcrumbs)),
                rootBounds,
              );
              expect(tester.getTopLeft(fileList), rootListTop);
              expect(tester.takeException(), isNull);
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant({platform}),
      );

      _detailTestWidgets(
        'library motion: reduced breadcrumbs reveal the newest segment immediately',
        (tester) async {
          final fixture = AppRuntimeWidgetTestFixture();
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          Widget page(List<String> segments) => fixture.build(
            MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Center(
                child: SizedBox(
                  width: 240,
                  child: WorkDetailBreadcrumbs(
                    key: const ValueKey('motion-breadcrumbs'),
                    segments: segments,
                    entryCount: 1,
                    i18n: fixture.languageProvider,
                    onNavigate: (_) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpWidget(page(['first long directory']));
          await tester.pumpWidget(
            page([
              'first long directory',
              'second long directory',
              'third long directory',
            ]),
          );
          final position = tester
              .state<ScrollableState>(find.byType(Scrollable))
              .position;
          expect(position.maxScrollExtent, greaterThan(0));
          expect(position.pixels, position.maxScrollExtent);
          expect(position.isScrollingNotifier.value, isFalse);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    _detailTestWidgets(
      'image browsing starts at the requested entry without restoring cache',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);
        final store = BrowsePageStateStore();
        store.update('images:work', {'image': '02.jpg'});
        const images = [
          WorkImageItem(
            name: 'new.jpg',
            path: 'new-cache.jpg',
            relativePath: 'new.jpg',
          ),
          WorkImageItem(
            name: '02.jpg',
            path: 'changed-cache.jpg',
            relativePath: '02.jpg',
          ),
        ];
        Widget page({int index = 0}) => fixture.build(
          WorkImageViewerPage(images: images, initialIndex: index),
          overrides: [browsePageStateStoreProvider.overrideWithValue(store)],
        );
        await tester.pumpWidget(page());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('1 / 2'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(page(index: 1));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('2 / 2'), findsOneWidget);
      },
    );

    _detailTestWidgets(
      'displays images, switches with prev/next, and sets manual cover',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);

        var coverSelected = '';

        final images = [
          const WorkImageItem(
            name: '01.jpg',
            path: 'path/to/01.jpg',
            relativePath: '01.jpg',
          ),
          const WorkImageItem(
            name: '02.jpg',
            path: 'path/to/02.jpg',
            relativePath: '02.jpg',
          ),
        ];

        await tester.pumpWidget(
          fixture.build(
            WorkImageViewerPage(
              images: images,
              onSetAsCover: (img) async {
                coverSelected = img.path;
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.byKey(const ValueKey<String>('work_image_header')),
          findsOneWidget,
        );
        expect(find.byType(TopPageHeader), findsOneWidget);

        final prevBtn = find.byKey(
          const ValueKey<String>('image_viewer_prev_button'),
        );
        final nextBtn = find.byKey(
          const ValueKey<String>('image_viewer_next_button'),
        );
        expect(prevBtn, findsOneWidget);
        expect(nextBtn, findsOneWidget);

        final prevSurface = find.ancestor(
          of: prevBtn,
          matching: find.byType(HeaderFloatingSurface),
        );
        final nextSurface = find.ancestor(
          of: nextBtn,
          matching: find.byType(HeaderFloatingSurface),
        );
        expect(tester.widget(prevSurface), same(tester.widget(nextSurface)));

        expect(find.text('1 / 2'), findsOneWidget);
        expect(find.text('01.jpg'), findsOneWidget);
        final viewport = find.byKey(
          const ValueKey<String>('work_image_viewport'),
        );
        final themeSurface = Theme.of(
          tester.element(viewport),
        ).colorScheme.surface;
        expect(
          tester
              .widgetList<Scaffold>(
                find.ancestor(of: viewport, matching: find.byType(Scaffold)),
              )
              .any((scaffold) => scaffold.backgroundColor == themeSurface),
          isTrue,
        );
        expect(find.byType(ImageFiltered), findsNothing);
        final pageView = tester.widget<PageView>(find.byType(PageView));
        expect(pageView.physics, isA<PageScrollPhysics>());
        final foregroundImages = tester.widgetList<RetryingFileImage>(
          find.descendant(
            of: viewport,
            matching: find.byType(RetryingFileImage),
          ),
        );
        expect(foregroundImages, isNotEmpty);
        expect(
          foregroundImages.every((image) => image.fit == BoxFit.contain),
          isTrue,
        );
        expect(
          find.descendant(
            of: viewport,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsWidgets,
        );
        expect(
          tester
              .getTopLeft(
                find.byKey(const ValueKey<String>('work_image_viewport')),
              )
              .dy,
          greaterThanOrEqualTo(
            tester
                    .getBottomLeft(
                      find.byKey(const ValueKey<String>('work_image_header')),
                    )
                    .dy +
                20,
          ),
        );

        expect(
          tester
              .getBottomRight(
                find.byKey(const ValueKey<String>('work_image_viewport')),
              )
              .dy,
          lessThanOrEqualTo(tester.getTopRight(prevBtn).dy - 10),
        );

        // Previous button is enabled at first image and cycles to last image with animation
        expect(tester.widget<IconButton>(prevBtn).onPressed, isNotNull);
        await tester.tap(prevBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('2 / 2'), findsOneWidget);
        expect(find.text('02.jpg'), findsOneWidget);

        // Next button cycles from last image back to first image with animation
        expect(tester.widget<IconButton>(nextBtn).onPressed, isNotNull);
        await tester.tap(nextBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('1 / 2'), findsOneWidget);
        expect(find.text('01.jpg'), findsOneWidget);

        // Swipe right from first image cycles to last image
        await tester.drag(
          find.byKey(const ValueKey<String>('work_image_viewport')),
          const Offset(500, 0),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('2 / 2'), findsOneWidget);
        expect(find.text('02.jpg'), findsOneWidget);

        // Swipe left from last image cycles back to first image
        await tester.drag(
          find.byKey(const ValueKey<String>('work_image_viewport')),
          const Offset(-500, 0),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('1 / 2'), findsOneWidget);
        expect(find.text('01.jpg'), findsOneWidget);

        // Next button animates to next image
        await tester.tap(nextBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('2 / 2'), findsOneWidget);
        expect(find.text('02.jpg'), findsOneWidget);

        // Next button is still enabled at last image
        expect(tester.widget<IconButton>(nextBtn).onPressed, isNotNull);

        // Set as cover button
        final setCoverBtn = find.byKey(
          const ValueKey<String>('viewer_set_as_cover_button'),
        );
        expect(setCoverBtn, findsOneWidget);
        await tester.tap(setCoverBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(coverSelected, 'path/to/02.jpg');
      },
    );

    _detailTestWidgets('double-tap toggles zoom and blocks swiping when zoomed', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      _detailFixtures.add(fixture);
      addTearDown(fixture.dispose);

      final images = [
        const WorkImageItem(
          name: '01.jpg',
          path: 'path/to/01.jpg',
          relativePath: '01.jpg',
        ),
        const WorkImageItem(
          name: '02.jpg',
          path: 'path/to/02.jpg',
          relativePath: '02.jpg',
        ),
      ];

      await tester.pumpWidget(
        fixture.build(WorkImageViewerPage(images: images)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final viewportFinder = find.byKey(
        const ValueKey<String>('work_image_viewport'),
      );
      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<PageScrollPhysics>(),
      );

      // Double-tap to zoom
      await tester.tap(viewportFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(viewportFinder);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>(),
      );

      // Double-tap to reset zoom
      await tester.tap(viewportFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(viewportFinder);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<PageScrollPhysics>(),
      );
    });

    _detailTestWidgets('loads ASMR image URLs through persistent artwork cache', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final covers = _ControlledWorkDetailCoverService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: covers,
      );
      _detailFixtures.add(fixture);
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        fixture.build(
          const WorkImageViewerPage(
            images: [
              WorkImageItem(
                name: 'remote.jpg',
                path: 'https://example.com/remote.jpg',
                relativePath: 'images/remote.jpg',
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AsyncRemoteCoverImage), findsOneWidget);
      expect(find.byType(LocalCoverImage), findsNothing);
      final foregroundImage = tester.widget<AsyncRemoteCoverImage>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('work_image_viewport')),
          matching: find.byType(AsyncRemoteCoverImage),
        ),
      );
      expect(foregroundImage.fit, BoxFit.contain);
      expect(foregroundImage.cacheHeight, isNull);
      expect(foregroundImage.useDefaultCacheWidth, isFalse);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('work_image_viewport')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      covers.cover.complete(null);
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      for (final remote in [false, true]) {
        _detailTestWidgets(
          '${remote ? 'remote' : 'local'} viewer defers original image decode during navigation on $platform',
          (tester) async {
            final interaction = UiInteractionCoordinator.instance;
            interaction.resetForTest();
            addTearDown(interaction.resetForTest);
            SharedPreferences.setMockInitialValues({});
            final root = await tester.runAsync(
              () => Directory.systemTemp.createTemp('viewer_cold_decode_'),
            );
            addTearDown(() async {
              if (await root!.exists()) await root.delete(recursive: true);
            });
            final image = File('${root!.path}/first.png');
            await tester.runAsync(
              () => image.writeAsBytes(
                base64Decode(
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                ),
              ),
            );
            final covers = _ControlledWorkDetailCoverService()
              ..cachedCover = image.path
              ..cover.complete(image.path);
            final fixture = AppRuntimeWidgetTestFixture(
              coverArtworkCacheService: covers,
            );
            _detailFixtures.add(fixture);
            addTearDown(fixture.dispose);
            final source = Object();
            interaction.beginNavigation(source);
            await tester.pumpWidget(
              fixture.build(
                WorkImageViewerPage(
                  images: [
                    WorkImageItem(
                      name: 'first.png',
                      path: remote
                          ? 'https://example.test/first.png'
                          : image.path,
                    ),
                  ],
                ),
              ),
            );
            await tester.pump();
            expect(find.byType(Image), findsNothing);
            final viewerImage = tester.widget<RetryingFileImage>(
              find.byType(RetryingFileImage),
            );
            expect(viewerImage.deferLoadDuringInteraction, isTrue);
            expect(viewerImage.useDefaultCacheWidth, isFalse);
            interaction.endNavigation(source);
            await tester.pump();
            expect(find.byType(Image), findsOneWidget);
            // Finish the file read before teardown removes the temporary image
            // on Windows, where an in-flight ImmutableBuffer holds the file.
            var decoded = false;
            final provider = FileImage(image);
            final decoding = precacheImage(
              provider,
              tester.element(find.byType(Image)),
            ).then((_) => decoded = true);
            for (var attempt = 0; attempt < 100 && !decoded; attempt++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump();
            }
            expect(decoded, isTrue);
            await decoding;
            await tester.pump(interaction.idleDelay);
            await tester.pumpWidget(const SizedBox.shrink());
            releaseRetainedCoverImage(provider);
            await provider.evict();
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
          },
          variant: TargetPlatformVariant({platform}),
        );
      }

      _detailTestWidgets('reuses and repairs cached viewer artwork on $platform', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final root = await tester.runAsync(
          () => Directory.systemTemp.createTemp('作品图片 缓存 '),
        );
        addTearDown(() async {
          if (await root!.exists()) await root.delete(recursive: true);
        });
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        );
        final artworkStore = CoverArtworkStore(
          persistentDirectory: () async =>
              Directory('${root!.path}/persistent'),
          temporaryDirectory: () async => Directory('${root!.path}/temporary'),
        );
        var downloads = 0;
        final covers = CoverArtworkCacheService(
          libraryService: LibraryService(),
          artworkStore: artworkStore,
          remoteCoverDownloader: (url) async {
            expect(url, 'https://example.com/remote.png');
            downloads++;
            return artworkStore.putBytes(
              logicalKey: remoteCoverSearchKey(url)!,
              bytes: bytes,
              namespace: CoverArtworkNamespace.remote,
            );
          },
        );
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: covers,
        );
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);
        const viewer = WorkImageViewerPage(
          images: [
            WorkImageItem(
              name: 'remote.png',
              path: 'https://example.com/remote.png',
            ),
          ],
        );

        Future<void> waitForArtwork() async {
          for (var attempt = 0; attempt < 100; attempt++) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            if (find.byType(RetryingFileImage).evaluate().isNotEmpty &&
                find.byType(CircularProgressIndicator).evaluate().isEmpty) {
              return;
            }
          }
          fail('Viewer artwork did not finish loading');
        }

        await tester.pumpWidget(fixture.build(viewer));
        await waitForArtwork();
        expect(downloads, 1);
        final image = tester.widget<RetryingFileImage>(
          find.byType(RetryingFileImage),
        );
        expect(image.path, contains('persistent'));
        expect(image.fit, BoxFit.contain);
        expect(image.useDefaultCacheWidth, isFalse);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(fixture.build(viewer));
        await waitForArtwork();
        expect(downloads, 1);

        await tester.pumpWidget(const SizedBox.shrink());
        final provider = FileImage(File(image.path));
        releaseRetainedCoverImage(provider);
        await provider.evict();
        await tester.runAsync(() => File(image.path).delete());
        await tester.pumpWidget(fixture.build(viewer));
        await waitForArtwork();
        expect(downloads, 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }

    _detailTestWidgets('empty images viewer uses theme surface background', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      _detailFixtures.add(fixture);
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        fixture.build(const WorkImageViewerPage(images: [])),
      );
      await tester.pump();

      final scaffoldFinder = find.descendant(
        of: find.byType(WorkImageViewerPage),
        matching: find.byType(Scaffold),
      );
      final scaffold = tester.widget<Scaffold>(scaffoldFinder);
      final themeSurface = Theme.of(
        tester.element(scaffoldFinder),
      ).colorScheme.surface;
      expect(scaffold.backgroundColor, themeSurface);
      expect(scaffold.backgroundColor, isNot(Colors.black));
    });

    _detailTestWidgets(
      'WorkDetailPage more menu renders in overlay above playback dock',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        _detailFixtures.add(fixture);
        addTearDown(fixture.dispose);
        final root = (await tester.runAsync<Directory>(
          () => Directory.systemTemp.createTemp('work_dock_menu_'),
        ))!;
        addTearDown(() async {
          try {
            if (await root.exists()) await root.delete(recursive: true);
          } on FileSystemException {
            // A failed assertion can leave the directory locked briefly.
          }
        });
        final textFile = File('${root.path}${Platform.pathSeparator}notes.txt');
        await tester.runAsync(() async {
          await textFile.writeAsString('notes');
        });
        fixture.library.addWatchedFolder(root.path, notify: false);
        final target = AudioDetailTarget.libraryRootFolder(root.path);

        final menuOverlayKey = GlobalKey<OverlayState>();
        await tester.pumpWidget(
          fixture.build(
            MobileOverlayInset(
              bottomInset: 80,
              menuOverlayKey: menuOverlayKey,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  WorkDetailPage.forLocal(target: target),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 64,
                    child: SizedBox(
                      key: ValueKey<String>('mock_playback_dock'),
                    ),
                  ),
                  Overlay(key: menuOverlayKey),
                ],
              ),
            ),
            overrides: [
              workTextServiceProvider.overrideWithValue(
                WorkTextService(
                  discoverImages:
                      fixture.library.discoverCoverImageReferencesInFolder,
                  platformGateway: _WorkDetailFileGateway(textFile),
                ),
              ),
            ],
          ),
        );
        for (var i = 0; i < 40 && find.text('notes').evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }

        final textMore = find.byKey(
          const ValueKey<String>('work_entry_more_notes.txt'),
        );
        expect(textMore, findsOneWidget);
        await tester.tap(textMore);
        await tester.pump(const Duration(milliseconds: 250));

        final menuItem = find.text(fixture.languageProvider.tr('rename'));
        expect(menuItem, findsOneWidget);
        final mockDock = find.byKey(
          const ValueKey<String>('mock_playback_dock'),
        );
        expect(mockDock, findsOneWidget);

        final paintOrder = tester.allWidgets.toList(growable: false);
        expect(
          paintOrder.indexOf(tester.widget(mockDock)),
          lessThan(paintOrder.indexOf(tester.widget(menuItem))),
        );

        await tester.tapAt(Offset.zero);
        await tester.pump(const Duration(milliseconds: 500));
        expect(menuItem, findsNothing);
      },
    );

    _detailTestWidgets(
      'WorkDetailEntryTile hides file suffixes in names and preserves folder names',
      (tester) async {
        const samples = [
          (
            name: 'Track.MP3',
            path: 'Track.MP3',
            type: WorkEntryType.audio,
            display: 'Track',
          ),
          (
            name: 'Track.part1',
            path: 'Track.part1.mp3',
            type: WorkEntryType.audio,
            display: 'Track.part1',
          ),
          (
            name: 'read.me.txt',
            path: 'read.me.txt',
            type: WorkEntryType.text,
            display: 'read.me',
          ),
          (
            name: 'cover.JPG',
            path: 'cover.JPG',
            type: WorkEntryType.image,
            display: 'cover',
          ),
          (
            name: 'LICENSE',
            path: 'LICENSE',
            type: WorkEntryType.text,
            display: 'LICENSE',
          ),
          (
            name: 'Archive.zip',
            path: 'Archive.zip',
            type: WorkEntryType.folder,
            display: 'Archive.zip',
          ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  for (final sample in samples)
                    WorkDetailEntryTile(
                      item: WorkEntryItem(
                        name: sample.name,
                        relativePath: sample.path,
                        type: sample.type,
                        fileSizeBytes: 0,
                      ),
                      accentColor: Colors.deepPurple,
                      menuEntries: const [],
                      moreLabel: 'More',
                      onAction: (_) {},
                    ),
                ],
              ),
            ),
          ),
        );
        final rows = find.byType(WorkDetailEntryTile);
        for (var index = 0; index < samples.length; index++) {
          final sample = samples[index];
          final row = rows.at(index);
          expect(
            find.descendant(of: row, matching: find.text(sample.display)),
            findsOneWidget,
          );
          if (sample.name != sample.display) {
            expect(
              find.descendant(of: row, matching: find.text(sample.name)),
              findsNothing,
            );
          }
          final item = tester.widget<WorkDetailEntryTile>(row).item;
          if (item.type == WorkEntryType.folder) {
            expect(
              find.descendant(of: row, matching: find.byType(Text)),
              findsOneWidget,
            );
          } else {
            final info = item.extension.isEmpty
                ? '0 B'
                : '0 B · ${item.extension.substring(1)}';
            expect(
              find.descendant(of: row, matching: find.text(info)),
              findsOneWidget,
            );
          }
          expect(item.name, sample.name);
          expect(item.relativePath, sample.path);
        }
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );

    _detailTestWidgets(
      'WorkDetailEntryTile aligns more icon with the skeleton action',
      (tester) async {
        for (final width in [240.0, 800.0]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: Column(
                      children: [
                        const FileTreeSkeleton(viewportHeight: 48),
                        WorkDetailEntryTile(
                          item: const WorkEntryItem(
                            name: 'Track.mp3',
                            relativePath: 'Track.mp3',
                            type: WorkEntryType.audio,
                          ),
                          accentColor: Colors.deepPurple,
                          menuEntries: const [],
                          moreLabel: 'More',
                          onAction: (_) {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          final placeholder = find.byWidgetPredicate(
            (widget) => widget is ShimmerContainer && widget.width == 16,
          );
          final more = find.byIcon(Icons.more_vert_rounded);
          expect(
            tester.getCenter(more).dx,
            closeTo(tester.getCenter(placeholder).dx, 0.01),
          );
          expect(
            tester.getSize(find.byTooltip('More')),
            Size(44, defaultTargetPlatform == TargetPlatform.windows ? 40 : 44),
          );
          final tile = tester.widget<ListTile>(find.byType(ListTile));
          final density = Theme.of(
            tester.element(find.byType(ListTile)),
          ).visualDensity;
          final titleRect = tester.getRect(find.byWidget(tile.title!));
          final buttonRect = tester.getRect(find.byTooltip('More'));
          expect(
            buttonRect.left - titleRect.right,
            closeTo(density.horizontal * 2, 0.01),
          );
          expect(titleRect.left, closeTo(56 + density.horizontal * 2, 0.01));
          expect(tester.takeException(), isNull);
        }
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );

    for (final textScale in [1.0, 2.0]) {
      _detailTestWidgets(
        'WorkDetailEntryTile fits two name lines and one file info line at $textScale scale',
        (tester) async {
          await tester.binding.setSurfaceSize(null);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 800);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final actions = <WorkEntryAction>[];
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final type in WorkEntryType.values)
                        WorkDetailEntryTile(
                          item: WorkEntryItem(
                            name: '${type.name} with a very long file name',
                            relativePath: '${type.name}.mp3',
                            type: type,
                            fileSizeBytes: 1024,
                            duration: const Duration(seconds: 65),
                          ),
                          accentColor: Colors.deepPurple,
                          menuEntries: const [],
                          moreLabel: 'More',
                          onAction: actions.add,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
          final tiles = find.byType(WorkDetailEntryTile);
          for (var index = 0; index < WorkEntryType.values.length; index++) {
            final row = tiles.at(index);
            final type = WorkEntryType.values[index];
            final name = find.text('${type.name} with a very long file name');
            final nameRect = tester.getRect(name);
            expect(nameRect.height, closeTo(32 * textScale, 0.01));
            expect(tester.widget<Text>(name).maxLines, 2);
            final rowRect = tester.getRect(row);
            if (type == WorkEntryType.folder) {
              expect(
                find.descendant(of: row, matching: find.byType(Text)),
                findsOneWidget,
              );
              expect(rowRect.height, closeTo(textScale == 1 ? 44 : 72, 0.01));
            } else {
              final info = find.text(
                type == WorkEntryType.audio
                    ? '1.0 KB · 01:05 · mp3'
                    : '1.0 KB · mp3',
              );
              final infoInRow = find.descendant(of: row, matching: info);
              final infoRect = tester.getRect(infoInRow);
              expect(tester.widget<Text>(infoInRow).maxLines, 1);
              expect(infoRect.top - nameRect.bottom, closeTo(2, 0.01));
              expect(nameRect.top - rowRect.top, closeTo(4, 0.01));
              expect(rowRect.bottom - infoRect.bottom, closeTo(4, 0.01));
              expect(
                rowRect.height,
                greaterThan(tester.getSize(tiles.first).height),
              );
            }
            final tile = find.descendant(
              of: row,
              matching: find.byType(ListTile),
            );
            expect(tester.widget<ListTile>(tile).leading, isA<Icon>());
            final icon = tester.widget<ListTile>(tile).leading! as Icon;
            final expectedIcon = switch (WorkEntryType.values[index]) {
              WorkEntryType.folder => AppDesignTokens.folderIcon,
              WorkEntryType.audio => AppDesignTokens.audioFileIcon,
              WorkEntryType.text => AppDesignTokens.textFileIcon,
              WorkEntryType.image => AppDesignTokens.imageFileIcon,
            };
            expect(icon.icon, expectedIcon);
            expect(icon.size, AppDesignTokens.fileEntryIconSize);
            if (index > 0) {
              expect(
                tester.getRect(row).top,
                tester.getRect(tiles.at(index - 1)).bottom,
              );
            }
            await tester.tap(
              find.text(
                '${WorkEntryType.values[index].name} with a very long file name',
              ),
            );
            await tester.pump();
            expect(
              actions.last,
              type == WorkEntryType.audio
                  ? WorkEntryAction.play
                  : WorkEntryAction.open,
            );
          }
          expect(tester.takeException(), isNull);
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.windows,
        }),
      );
      _detailTestWidgets(
        'WorkDetailEntryTile adapts to name length and width at $textScale scale',
        (tester) async {
          await tester.binding.setSurfaceSize(null);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(1200, 800);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          for (final sample in [
            (name: 'Short', width: 320.0, lines: 1),
            (name: 'A reasonably long entry name', width: 320.0, lines: 2),
            (name: 'A reasonably long entry name', width: 1200.0, lines: 1),
          ]) {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: MediaQuery(
                    data: MediaQueryData(
                      textScaler: TextScaler.linear(textScale),
                    ),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: sample.width,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final type in [
                              WorkEntryType.folder,
                              WorkEntryType.audio,
                            ])
                              WorkDetailEntryTile(
                                item: WorkEntryItem(
                                  name: sample.name,
                                  relativePath: '${type.name}.mp3',
                                  type: type,
                                  fileSizeBytes: 1024,
                                  duration: const Duration(seconds: 65),
                                ),
                                accentColor: Colors.deepPurple,
                                menuEntries: const [],
                                moreLabel: 'More',
                                onAction: (_) {},
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            final rows = find.byType(WorkDetailEntryTile);
            for (var index = 0; index < 2; index++) {
              final row = rows.at(index);
              final name = find.descendant(
                of: row,
                matching: find.text(sample.name),
              );
              final nameRect = tester.getRect(name);
              expect(
                nameRect.height,
                closeTo(16 * textScale * sample.lines, 0.01),
              );
              var contentHeight = nameRect.height;
              if (index == 1) {
                final infoRect = tester.getRect(
                  find.text('1.0 KB · 01:05 · mp3'),
                );
                expect(infoRect.top - nameRect.bottom, closeTo(2, 0.01));
                contentHeight += 2 + infoRect.height;
              }
              expect(
                tester.getSize(row).height,
                closeTo(contentHeight + 8 < 44 ? 44 : contentHeight + 8, 0.01),
              );
            }
            expect(tester.takeException(), isNull);
          }
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.windows,
        }),
      );
    }

    _detailTestWidgets(
      'WorkDetailEntryTile renders transparent Material and provides feedback colors and action on tap',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        try {
          final calls = <MethodCall>[];
          final prevHaptics = AppInteractionFeedback.hapticFeedbackEnabled;
          AppInteractionFeedback.hapticFeedbackEnabled = true;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              calls.add(call);
              return null;
            },
          );
          addTearDown(() {
            AppInteractionFeedback.hapticFeedbackEnabled = prevHaptics;
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              null,
            );
          });

          WorkEntryAction? performedAction;
          const item = WorkEntryItem(
            type: WorkEntryType.folder,
            name: 'Voices',
            relativePath: 'Voices',
            fullPathOrUrl: '/work/Voices',
          );

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: WorkDetailEntryTile(
                  item: item,
                  accentColor: Colors.blue,
                  menuEntries: const [],
                  moreLabel: 'More',
                  onAction: (action) => performedAction = action,
                ),
              ),
            ),
          );

          final materialFinder = find.descendant(
            of: find.byType(WorkDetailEntryTile),
            matching: find.byWidgetPredicate(
              (w) => w is Material && w.shape is RoundedRectangleBorder,
            ),
          );
          expect(materialFinder, findsOneWidget);
          final material = tester.widget<Material>(materialFinder);
          expect(material.color, Colors.transparent);
          expect(material.clipBehavior, Clip.antiAlias);
          expect(
            material.shape,
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          );

          final listTileFinder = find.descendant(
            of: find.byType(WorkDetailEntryTile),
            matching: find.byType(ListTile),
          );
          expect(listTileFinder, findsOneWidget);
          final listTile = tester.widget<ListTile>(listTileFinder);
          expect(listTile.splashColor, isNotNull);
          expect(listTile.hoverColor, isNotNull);

          await tester.tap(listTileFinder);
          await tester.pump();

          expect(performedAction, WorkEntryAction.open);
          expect(
            calls.any(
              (call) =>
                  call.method == 'SystemSound.play' ||
                  call.method == 'HapticFeedback.vibrate',
            ),
            isTrue,
          );

          await tester.longPress(listTileFinder);
          await tester.pump();
          expect(performedAction, WorkEntryAction.copy);

          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    _detailTestWidgets(
      'WorkDetailEntryTile highlights item on Windows when more menu is opened',
      (WidgetTester tester) async {
        WorkEntryAction? performedAction;
        const item = WorkEntryItem(
          type: WorkEntryType.audio,
          name: 'Track 01.mp3',
          relativePath: 'Track 01.mp3',
          fullPathOrUrl: '/work/Track 01.mp3',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WorkDetailEntryTile(
                item: item,
                accentColor: Colors.deepPurple,
                menuEntries: const [
                  UnifiedMenuEntry.action(
                    value: WorkEntryAction.play,
                    label: 'Play',
                  ),
                ],
                moreLabel: 'More',
                onAction: (action) => performedAction = action,
              ),
            ),
          ),
        );

        final listTileFinder = find.byType(ListTile);
        expect(tester.widget<ListTile>(listTileFinder).selected, isFalse);

        // Tap the more button to open the menu
        final moreButton = find.byKey(
          const ValueKey<String>('work_entry_more_Track 01.mp3'),
        );
        await tester.tap(moreButton);
        await tester.pump();

        // While menu is opened, the tile is selected and highlighted
        expect(tester.widget<ListTile>(listTileFinder).selected, isTrue);
        expect(
          tester.widget<ListTile>(listTileFinder).selectedTileColor,
          Colors.deepPurple.withValues(alpha: 0.16),
        );

        // Tap the menu action to close menu
        await tester.tap(find.text('Play'));
        await tester.pumpAndSettle();

        // After menu closes, tile is unhighlighted and action is performed
        expect(tester.widget<ListTile>(listTileFinder).selected, isFalse);
        expect(performedAction, WorkEntryAction.play);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      _detailTestWidgets(
        'cached file rows retain their identity without row animation during entry on $platform',
        (tester) async {
          final interaction = UiInteractionCoordinator.instance;
          interaction.resetForTest();
          addTearDown(interaction.resetForTest);
          SharedPreferences.setMockInitialValues(const <String, Object>{});
          final covers = _ControlledWorkDetailCoverService()
            ..images.complete([])
            ..cover.complete(null);
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
          );
          _detailFixtures.add(fixture);
          addTearDown(fixture.dispose);
          const folder = 'C:/works/cached-rows';
          final target = AudioDetailTarget.libraryRootFolder(folder);
          fixture.library.addWatchedFolder(folder, notify: false);
          fixture.library.addTracks(
            List.generate(
              80,
              (index) => MusicTrack(
                path: '$folder/track$index.mp3',
                displayName: 'track$index.mp3',
                groupKey: folder,
                groupTitle: 'Cached rows',
                groupSubtitle: '',
                isSingle: false,
              ),
            ),
            persist: false,
          );
          await tester.runAsync(() async {
            await fixture.library.loadAudioDetail(target);
            await fixture.library.loadLibraryFolderTree(folder);
            await _prewarmDirectory(fixture, folder);
          });

          final textService = WorkTextService(
            discoverImages: (_) async => [],
            platformGateway: _NestedWorkDetailFileGateway([]),
          );
          addTearDown(textService.dispose);
          interaction.beginInteraction(Object());
          var theme = ThemeData.light();
          Widget page() => fixture.build(
            Theme(
              data: theme,
              child: WorkDetailPage.forLocal(target: target),
            ),
            overrides: [workTextServiceProvider.overrideWithValue(textService)],
          );
          await tester.pumpWidget(page());

          await tester.pump();
          await tester.pump();

          await _settleDetail(tester);

          final tileFinder = find.byType(WorkDetailEntryTile);
          expect(tileFinder, findsWidgets);
          expect(
            tester.binding.transientCallbackCount,
            0,
            reason: 'Cached rows must not start their own animation on open.',
          );
          expect(
            tester.widgetList<WorkDetailEntryTile>(tileFinder).length,
            lessThan(80),
          );
          final originalItems = tester
              .widgetList<WorkDetailEntryTile>(tileFinder)
              .map((tile) => tile.item)
              .toList();
          // Preserve the State while changing a presentation dependency.
          theme = ThemeData.dark();
          await tester.pumpWidget(page());
          for (final item in originalItems) {
            expect(
              tester
                  .widget<WorkDetailEntryTile>(
                    find.byKey(
                      ValueKey('${item.type.name}:${item.relativePath}'),
                    ),
                  )
                  .item,
              same(item),
              reason: 'Theme changes must reuse directory results.',
            );
          }

          final initialNames = tester
              .widgetList<WorkDetailEntryTile>(tileFinder)
              .map((tile) => tile.item.name)
              .toSet();
          // Jump to mount a new set of lazy rows, without a scroll animation.
          final scrollable = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          scrollable.position.jumpTo(1600);
          await tester.pump();
          expect(
            tester
                .widgetList<WorkDetailEntryTile>(tileFinder)
                .any((tile) => !initialNames.contains(tile.item.name)),
            isTrue,
          );
          expect(
            find.ancestor(of: tileFinder, matching: find.byType(Opacity)),
            findsNothing,
            reason:
                'Newly visible rows must not restart a fade while scrolling.',
          );
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          // Drain directory metadata I/O before the shared SQLite fixture closes.
          await _settleDetail(tester);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  });
}
