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
import 'package:doujin_audio/core/widgets/file_tree_row.dart';
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
import 'package:doujin_audio/features/settings/application/settings_state.dart';
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
  List<AsmrTrackFile>? trackTreeFor(int workId) {
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
  bool isFavorite(int workId) => false;

  @override
  bool isTrackHidden(int workId, AsmrTrackFile node) => false;

  @override
  AsmrTrackTreeViewState trackTreeViewState(int workId) =>
      AsmrTrackTreeViewState(
        workId: workId,
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

  group('WorkDetailPage', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      for (final cached in [false, true]) {
        for (final local in [false, true]) {
          testWidgets(
            '${local ? 'local' : 'ASMR'} ${cached ? 'cached' : 'cold'} detail defers rows during real navigation on $platform',
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
                  notify: false,
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
              await tester.pumpWidget(
                fixture.build(
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => Navigator.of(context).push<void>(
                        buildAppPageRoute(
                          context: context,
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
              );
              await tester.tap(find.text('Open first detail'));
              await tester.pump();
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 100));
              expect(find.text('First detail title'), findsOneWidget);
              expect(find.byType(WorkDetailEntryTile), findsNothing);
              expect(find.byType(AsyncLocalCoverImage), findsNothing);
              expect(find.byType(AsyncRemoteCoverImage), findsNothing);
              expect(find.text('Deferred voice actor'), findsNothing);
              expect(find.byType(WorkDetailDirectorySkeleton), findsOneWidget);
              expect(remote.cacheReads, 0);
              expect(remote.requests, 0);
              await _settleDetail(tester);
              expect(find.byType(WorkDetailEntryTile), findsWidgets);
              expect(find.text('Deferred voice actor'), findsOneWidget);
              if (!local) {
                expect(remote.cacheReads, 1);
                expect(remote.requests, 1);
              }
              await tester.pumpWidget(const SizedBox.shrink());
              await _settleDetail(tester);
              expect(tester.takeException(), isNull);
            },
            variant: TargetPlatformVariant({platform}),
          );
        }
      }
    }

    testWidgets('leaving the source frame cancels a pending detail push', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = AppRuntimeWidgetTestFixture();
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
      testWidgets(
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
          expect(find.byType(WorkDetailEntryTile), findsNothing);
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

      testWidgets(
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
          expect(find.text('audio.mp3'), findsNothing);
          final skeleton = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('work_detail_entries_skeleton')),
          );
          final directorySkeleton = tester.widget<WorkDetailDirectorySkeleton>(
            find.byType(WorkDetailDirectorySkeleton),
          );
          expect(directorySkeleton.viewportHeight, greaterThan(6 * 48));
          final skeletonBounds = tester.getRect(
            find.byKey(const ValueKey('work_detail_entries_skeleton')),
          );
          expect(skeletonBounds.bottom, greaterThanOrEqualTo(996));
          expect(skeletonBounds.bottom, lessThan(996 + 48));
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
          expect(skeletonRect.bottom, lessThan(1196 + 48));
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
            if (find.text('audio.mp3').evaluate().isNotEmpty) break;
          }
          expect(find.text('audio.mp3'), findsOneWidget);
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
          Navigator.of(tester.element(find.byType(WorkDetailPage))).pop();
          await _settleDetail(tester);
          await tester.pump(interaction.idleDelay);
          await tester.tap(find.text('Open cold directory'));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text('audio.mp3'), findsNothing);
          await _settleDetail(tester);
          expect(find.text('audio.mp3'), findsOneWidget);
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

      testWidgets(
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
            if (find.text('notes.txt').evaluate().isNotEmpty) break;
          }
          expect(find.text('notes.txt'), findsOneWidget);
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

      testWidgets(
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
          expect(find.text('notes.txt', skipOffstage: false), findsNothing);
          expect(find.text('picture.jpg', skipOffstage: false), findsNothing);
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
          expect(find.text('notes.txt'), findsOneWidget);
          expect(find.text('picture.jpg'), findsOneWidget);
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
      testWidgets(
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
          expect(find.text(detail.voiceActors.single), findsNothing);
          expect(find.text('#${detail.tags.single}'), findsNothing);
          expect(find.byType(AsyncLocalCoverImage), findsNothing);
          expect(find.byType(LocalCoverImage), findsNothing);
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

      testWidgets(
        'reuses remote card cover and keeps its future stable on $platform',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final covers = _ControlledWorkDetailCoverService()
            ..cachedCover = 'C:/works/remote/cover.jpg';
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: covers,
          );
          addTearDown(fixture.dispose);
          final work = AsmrWork.fromJson(const {
            'id': 321,
            'title': 'Cached remote card',
            'mainCoverUrl': 'https://example.com/cover.jpg',
          });
          Widget page() => fixture.build(WorkDetailPage.forAsmr(work: work));
          await tester.pumpWidget(page());
          expect(find.byType(AsyncRemoteCoverImage), findsNothing);
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

      testWidgets(
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
          for (final value in [
            'Card title',
            'Card circle',
          ]) {
            expect(find.text(value), findsOneWidget);
          }
          expect(find.text('Card CV'), findsNothing);
          expect(find.text('#Card tag'), findsNothing);
          await tester.pump(const Duration(milliseconds: 500));
          expect(repository.detailRequests, 0);
          expect(covers.imageRequests, 0);
          expect(find.text('audio.mp3'), findsNothing);

          interaction.cancelNavigation(source);
          await _settleDetail(tester);
          expect(find.text('Card CV'), findsOneWidget);
          expect(find.text('#Card tag'), findsOneWidget);
          expect(find.text('audio.mp3'), findsOneWidget);
          expect(covers.imageRequests, 1);
          expect(repository.detailRequests, 0);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );

      testWidgets(
        'shows cached indexed tree after the shell and reuses file snapshots on $platform',
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
          expect(find.text('audio.mp3'), findsNothing);
          expect(find.text('Extras'), findsNothing);
          expect(find.text('notes.txt'), findsNothing);

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
          expect(find.text('audio.mp3'), findsOneWidget);
          expect(covers.imageRequests, 1);
          expect(covers.coverRequests, 1);
          expect(find.text('notes.txt'), findsOneWidget);
          expect(find.text('cover.jpg'), findsNothing);

          covers.images.complete(['$folderPath/cover.jpg']);
          await tester.pump();
          await tester.pump();
          await _settleDetail(tester);
          expect(find.text('cover.jpg'), findsOneWidget);
          expect(covers.cover.isCompleted, isFalse);

          covers.cachedCover = '$folderPath/cover.jpg';
          interaction.beginNavigation(source);
          await tester.pumpWidget(buildPage(const ValueKey('reopened')));
          expect(find.text('notes.txt'), findsNothing);
          expect(find.text('cover.jpg'), findsNothing);
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
          expect(find.text('notes.txt'), findsNothing);
          expect(find.text('updated.txt'), findsOneWidget);
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
      testWidgets(
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
          expect(find.byType(WorkDetailEntryTile), findsNothing);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          interaction.cancelNavigation(source);
          await _settleDetail(tester);
          expect(tester.widget<CustomScrollView>(scroll).controller!.offset, 0);
          expect(
            tester.widgetList<WorkDetailEntryTile>(
              find.byType(WorkDetailEntryTile),
            ).every((tile) => tile.item.type == WorkEntryType.folder),
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

    testWidgets('empty local tree keeps loading until file scans finish', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final covers = _ControlledWorkDetailCoverService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: covers,
      );
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

    testWidgets(
      'local tree shows folders containing only text or image files',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
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
        expect(find.text('notes.txt'), findsOneWidget);

        await tester.tap(
          find.text(fixture.languageProvider.tr('root_directory')),
        );
        await _settleDetail(tester);
        await tester.tap(find.text('Gallery'));
        await _settleDetail(tester);
        expect(find.text('cover.jpg'), findsOneWidget);
      },
    );

    testWidgets('local text and image entries use contextual more menus', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
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
            (find.text('notes.txt').evaluate().isEmpty ||
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

    testWidgets(
      'audio and video menus add one item without starting playback and remove with undo',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final covers = _ControlledWorkDetailCoverService()
          ..images.complete([])
          ..cover.complete(null);
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: covers,
        );
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
        fixture.library.addWatchedFolder(folderPath, notify: false);
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
        await tester.tap(find.text(fixture.languageProvider.tr('exclude')));
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
        await tester.tap(find.text(fixture.languageProvider.tr('exclude')));
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

    testWidgets(
      'renders local work detail header, pinned RJ row and action buttons',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture(
          asmrMetadataService: _WorkDetailAsmrMetadataService(),
        );
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

    testWidgets('renders ASMR.ONE work detail header and actions', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final asmrWork = AsmrWork(
        id: 9999,
        title: 'ASMR Remote Work Title',
        circleName: 'Remote Circle',
        sourceId: 'RJ9999',
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
      expect(find.text('RJ9999'), findsOneWidget);
      expect(find.text('Remote Circle'), findsOneWidget);
      expect(
        find.text(fixture.languageProvider.tr('asmr_has_subtitle')),
        findsOneWidget,
      );
      final subtitleStatus = find.text(
        fixture.languageProvider.tr('asmr_has_subtitle'),
      );
      final statusCapsule = find.byKey(
        const ValueKey<String>('work_detail_subtitle_status'),
      );
      expect(
        find.ancestor(
          of: subtitleStatus,
          matching: find.byType(HeaderFloatingSurface),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: statusCapsule,
          matching: find.byIcon(Icons.subtitles_rounded),
        ),
        findsOneWidget,
      );
      expect(
        tester.getRect(statusCapsule).top,
        tester
            .getRect(
              find.ancestor(
                of: find.byKey(
                  const ValueKey<String>('work_detail_back_button'),
                ),
                matching: find.byType(HeaderFloatingButton),
              ),
            )
            .top,
      );
      final translationButton = find.ancestor(
        of: find.byKey(const ValueKey<String>('work_detail_translation')),
        matching: find.byType(HeaderFloatingButton),
      );
      expect(
        tester.getRect(statusCapsule).right,
        lessThan(tester.getRect(translationButton).left),
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
      expect(tester.widget<Text>(find.text('RJ9999')).style?.fontSize, 13);
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

    testWidgets('back button navigates back', (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final asmrWork = AsmrWork(
        id: 8888,
        title: 'Nav Work',
        circleName: 'Nav Circle',
        sourceId: 'RJ8888',
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
        findsOneWidget,
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

    testWidgets(
      'tags render in capsule style and clicking a tag copies to clipboard',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
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
      testWidgets(
        'WorkDetailPage hides scrollbars on $platform and remains scrollable',
        (tester) async {
          SharedPreferences.setMockInitialValues(const <String, Object>{});
          final fixture = AppRuntimeWidgetTestFixture();
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
      for (final reduceMotion in [false, true]) {
        testWidgets(
          'library motion: image navigation retains rapid targets and follows manual dragging ($reduceMotion)',
          (tester) async {
            final fixture = AppRuntimeWidgetTestFixture();
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

      testWidgets(
        'library motion: reduced breadcrumbs reveal the newest segment immediately',
        (tester) async {
          final fixture = AppRuntimeWidgetTestFixture();
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

    testWidgets(
      'image browsing starts at the requested entry without restoring cache',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
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

    testWidgets(
      'displays images, switches with prev/next, and sets manual cover',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
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

    testWidgets('double-tap toggles zoom and blocks swiping when zoomed', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
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

    testWidgets('loads ASMR image URLs through persistent artwork cache', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final covers = _ControlledWorkDetailCoverService();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: covers,
      );
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
        testWidgets(
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
            await tester.pump(interaction.idleDelay);
            await tester.pumpWidget(const SizedBox.shrink());
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
          },
          variant: TargetPlatformVariant({platform}),
        );
      }

      testWidgets('reuses and repairs cached viewer artwork on $platform', (
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

    testWidgets('empty images viewer uses theme surface background', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
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

    testWidgets(
      'WorkDetailPage more menu renders in overlay above playback dock',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
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
        for (
          var i = 0;
          i < 40 && find.text('notes.txt').evaluate().isEmpty;
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

    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'WorkDetailEntryTile uses bare icons and switcher row heights at $textScale scale',
        (tester) async {
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
                      const FileTreeRow(
                        title: 'Switcher reference',
                        leading: Icon(Icons.audio_file_rounded, size: 16),
                      ),
                      for (final type in WorkEntryType.values)
                        WorkDetailEntryTile(
                          item: WorkEntryItem(
                            name: '${type.name} with a very long file name',
                            relativePath: type.name,
                            type: type,
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
          final referenceHeight = tester
              .getSize(find.byType(FileTreeRow))
              .height;
          expect(referenceHeight, textScale == 1 ? 44 : greaterThan(44));
          final tiles = find.byType(WorkDetailEntryTile);
          for (var index = 0; index < WorkEntryType.values.length; index++) {
            final row = tiles.at(index);
            expect(tester.getSize(row).height, referenceHeight);
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
              WorkEntryType.values[index] == WorkEntryType.audio
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
    }

    testWidgets(
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

    testWidgets(
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
      testWidgets(
        'cached file rows retain their identity without row animation after the shell on $platform',
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
