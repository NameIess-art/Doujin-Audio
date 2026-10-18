import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_category_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entries.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entry_tile.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';

import 'support/app_runtime_test_fixture.dart';

const _root = 'C:/音频 库/作品';

class _NoArtwork extends CoverArtworkCacheService {
  _NoArtwork() : super(libraryService: LibraryService());

  @override
  Future<String?> futureForFolder(String folderPath) => SynchronousFuture(null);

  @override
  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) =>
      SynchronousFuture(null);
}

class _WorkFiles extends WorkTextService {
  static const texts = [
    WorkTextFile(
      name: '说明 文本.txt',
      relativePath: '说明 文本.txt',
      path: '$_root/说明 文本.txt',
    ),
    WorkTextFile(
      name: '说明.txt',
      relativePath: '仅 文本/说明.txt',
      path: '$_root/仅 文本/说明.txt',
    ),
  ];
  static const images = [
    CoverImageReference(
      sourcePath: '$_root/原始 图片.jpg',
      displayPath: 'C:/cache/decoded.jpg',
    ),
  ];

  @override
  List<WorkTextFile>? resolvedWorkTextFiles(String folderPath) => texts;

  @override
  List<CoverImageReference>? resolvedWorkImageFiles(String folderPath) =>
      images;

  @override
  String sourcePathForWorkImage(String folderPath, String imagePath) =>
      images.firstWhere((image) => image.displayPath == imagePath).sourcePath;

  @override
  Future<List<WorkTextFile>> refreshWorkTextFiles(String folderPath) async =>
      texts;

  @override
  Future<List<CoverImageReference>> refreshWorkImageFiles(
    String folderPath,
  ) async => images;
}

MusicTrack _track({bool single = false, String? path}) => MusicTrack(
  path: path ?? '$_root/声音 文件.mp3',
  displayName: '声音 文件.mp3',
  groupKey: single ? '__single_files__' : _root,
  groupTitle: '作品',
  groupSubtitle: '',
  isSingle: single,
);

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  await tester.tap(
    target,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
}

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;
  late List<MethodCall> calls;
  var succeeds = true;
  setUpAll(() async {
    database = await AppRuntimeTestFixture.installSharedDatabase();
  });
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));
  setUp(() {
    UiInteractionCoordinator.instance.resetForTest();
    calls = [];
    succeeds = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, (call) async {
          if (call.method == 'openContainingFolder') {
            calls.add(call);
            return {'ok': true, 'value': succeeds};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, null);
    UiInteractionCoordinator.instance.resetForTest();
  });

  for (final kind in [
    'root folder',
    'nested folder',
    'single audio',
    'nested audio',
    'category folder',
    'category audio',
  ]) {
    testWidgets(
      '$kind context action opens its original Windows path',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: _NoArtwork(),
        );
        addTearDown(fixture.dispose);
        final isFolder = kind.contains('folder');
        final track = _track(
          single: kind == 'single audio' || kind == 'category audio',
        );
        await tester.runAsync(() async {
          fixture.library.addWatchedFolder(_root, notify: false);
          fixture.library.addTracks([track], persist: false);
          await fixture.library.flushPendingPersistence();
        });
        final path = isFolder
            ? (kind == 'nested folder' ? '$_root/子 文件夹' : _root)
            : track.path;
        final folder = FolderNode('文件夹', path)..addChild(TrackNode(track));
        final target = isFolder
            ? AudioDetailTarget.libraryRootFolder(path)
            : AudioDetailTarget.singleAudioFile(path);
        final child = kind.startsWith('category')
            ? AudioLibraryCategoryEntryCard(
                entry: AudioLibraryCategoryEntry(
                  target: target,
                  title: '条目',
                  path: path,
                  isFolder: isFolder,
                  detail: AudioDetail.empty(target),
                  tracks: [track],
                ),
                folder: isFolder ? folder : null,
                secondaryIcon: Icons.sell_outlined,
                secondaryText: '标签',
              )
            : LibraryTreeItem(node: isFolder ? folder : TrackNode(track));
        await tester.pumpWidget(fixture.build(child));
        await tester.pump(const Duration(milliseconds: 350));
        final card = find.byType(SwipeRevealCard);
        final action = fixture.languageProvider.tr('open_containing_folder');
        if (defaultTargetPlatform == TargetPlatform.android) {
          expect(tester.widget<SwipeRevealCard>(card).onTertiaryAction, isNull);
          await _rightClick(tester, card);
          expect(find.text(action), findsNothing);
          expect(calls, isEmpty);
        } else {
          await _rightClick(tester, card);
          expect(find.text(action), findsOneWidget);
          await tester.tap(find.text(action));
          await tester.pumpAndSettle();
          expect(calls.single.arguments, {'path': path});
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    'local work menus reveal every original entry path and report failure',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _NoArtwork(),
      );
      addTearDown(fixture.dispose);
      final tracks = [_track(), _track(path: '$_root/子 文件夹/声音 文件.mp3')];
      final target = AudioDetailTarget.libraryRootFolder(_root);
      final files = _WorkFiles();
      await tester.runAsync(() async {
        fixture.library.addWatchedFolder(_root, notify: false);
        fixture.library.addTracks(tracks, persist: false);
        await fixture.library.flushPendingPersistence();
        await fixture.library.loadAudioDetail(target);
        await fixture.library.loadLibraryFolderTree(_root);
        await WorkDirectoryInput.local(
          root: fixture.library.resolvedLibraryFolderTree(_root),
          texts: _WorkFiles.texts,
          images: _WorkFiles.images,
          folderPath: _root,
        ).load();
      });
      await tester.pumpWidget(
        fixture.build(
          WorkDetailPage.forLocal(
            target: target,
            initialDetail: AudioDetail.empty(target),
          ),
          overrides: [workTextServiceProvider.overrideWithValue(files)],
        ),
      );
      await pumpUntilFound(tester, find.byType(WorkDetailEntryTile));
      await tester.pumpAndSettle();
      final action = fixture.languageProvider.tr('open_containing_folder');
      final tiles = find.byType(WorkDetailEntryTile);
      expect(tiles, findsNWidgets(5));
      for (var i = 0; i < 5; i++) {
        final tile = tester.widget<WorkDetailEntryTile>(tiles.at(i));
        if (defaultTargetPlatform == TargetPlatform.android) {
          expect(
            tile.menuEntries.where(
              (entry) => entry.value == WorkEntryAction.openContainingFolder,
            ),
            isEmpty,
          );
          continue;
        }
        await _rightClick(tester, tiles.at(i));
        expect(find.text(action), findsOneWidget);
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        final expected = switch (tile.item.type) {
          WorkEntryType.folder => '$_root/${tile.item.relativePath}',
          WorkEntryType.audio => tracks.first.path,
          WorkEntryType.text => _WorkFiles.texts.first.path,
          WorkEntryType.image => _WorkFiles.images.single.sourcePath,
        };
        expect(
          (calls.last.arguments as Map)['path'].toString().replaceAll(
            r'\',
            '/',
          ),
          expected,
        );
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        succeeds = false;
        await _rightClick(tester, tiles.first);
        await tester.tap(find.text(action));
        await pumpUntilFound(
          tester,
          find.textContaining(
            fixture.languageProvider.tr('operation_failed_retry'),
          ),
        );
        expect(
          find.textContaining(
            fixture.languageProvider.tr('operation_failed_retry'),
          ),
          findsOneWidget,
        );
      } else {
        expect(calls, isEmpty);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
