import 'dart:io';
import 'dart:ui' as ui;

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_scan_data_source.dart';
import 'package:doujin_audio/features/library/application/library_scanner_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/data/audio_detail_json_codec.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test/support/app_runtime_test_fixture.dart';
import '../test/support/test_persistence_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('large library import preserves JSON and keeps rendering', (
    tester,
  ) async {
    final resources = await tester.runAsync(() async {
      // Keep stress-test sources, database and preferences isolated from user data.
      SharedPreferences.setMockInitialValues({});
      if (Platform.isWindows) sqfliteFfiInit();
      final factory = Platform.isWindows ? databaseFactoryFfi : databaseFactory;
      final db = await factory.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchemaForTest(db);
      final repository = TestPersistenceRepository(
        database: AppDatabase.test(db),
      );
      final root = await Directory.systemTemp.createTemp(
        'library_import_smoke_',
      );
      final service = LibraryService();
      final library = LibraryFacade.create(
        databaseRepository: repository,
        service: service,
      );
      late final AppRuntimeGraph graph;
      library.attachCoverArtworkCacheService(
        () => CoverArtworkCacheService(
          libraryService: service,
          databaseRepository: repository,
          audioDetailCacheService: library.detailCacheService,
          persistentDirectory: () async =>
              Directory(path.join(root.path, 'cache')),
          temporaryDirectory: () async =>
              Directory(path.join(root.path, 'temp')),
          isActiveCoverKey: (key) => graph.notifications.isActiveCoverKey(key),
          onActiveCoverChanged: () => graph.notifications.syncPlaybackState(),
        ),
      );
      graph = createTestRuntimeGraph(
        library: library,
        persistenceRepository: repository,
        skipPersistence: false,
      );
      // Real cover discovery, decoding and runtime notifications stay active.
      final importedRoot = await Directory(
        path.join(root.path, '导入曲库'),
      ).create();
      final existing = await Directory(path.join(root.path, '已有作品')).create();
      await File(path.join(existing.path, '已收藏音频.mp3')).writeAsBytes([0]);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 512, 512),
        Paint()..color = Colors.purple,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(512, 512);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      await File(
        path.join(existing.path, 'cover.png'),
      ).writeAsBytes(png!.buffer.asUint8List());
      await LibraryScannerService(
        dataSource: _PrivateFolderSource(existing.path),
      ).addFolder(provider: library, labels: _labels);
      await library.coverArtworkCacheService.initialize();
      library.syncPresentationState(isInitialized: true);
      await library.ensureCardSnapshot();
      for (var index = 0; index < 40; index++) {
        final work = await Directory(
          path.join(importedRoot.path, '作品 $index'),
        ).create();
        for (var track = 0; track < 30; track++) {
          await File(path.join(work.path, '$track.mp3')).writeAsBytes([0]);
        }
        await File(
          path.join(work.path, 'cover.png'),
        ).writeAsBytes(png.buffer.asUint8List());
      }
      return (
        db: db,
        repository: repository,
        root: root,
        importedRoot: importedRoot,
        library: library,
        graph: graph,
      );
    });
    final data = resources!;
    final language = AppLanguageProvider();
    addTearDown(() async {
      language.dispose();
      await data.graph.runtime.dispose();
      await data.db.close();
      await data.root.delete(recursive: true);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...createAppRuntimeOverrides(
            persistence: data.graph.persistence,
            runtime: data.graph.runtime,
            warmup: data.graph.warmup,
            playbackCommands: data.graph.playbackCommands,
            keepAlive: data.graph.keepAlive,
            library: data.library,
            playback: data.graph.playback,
            subtitles: data.graph.subtitles,
            timer: data.graph.timer,
            notifications: data.graph.notifications,
            settings: data.graph.settings,
            workTexts: data.graph.workTexts,
            browsePageStates: data.graph.browsePageStates,
          ),
          appLanguageProviderInstanceProvider.overrideWithValue(language),
        ],
        child: const MaterialApp(home: Scaffold(body: LibraryTab())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final decodedCovers = find.byWidgetPredicate(
      (widget) => widget is RawImage && widget.image != null,
    );
    for (
      var attempt = 0;
      attempt < 20 && decodedCovers.evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.byType(AsyncCoverImage), findsWidgets);
    expect(decodedCovers, findsWidgets);
    await tester.runAsync(() async {
      final library = data.library;
      final repository = data.repository;
      final jsonFiles = <File, List<int>>{};
      final timings = <FrameTiming>[];
      var renderedProgress = false;
      var renderedCoverDuringScan = false;
      void collect(List<FrameTiming> batch) {
        timings.addAll(batch);
        if (find
            .byKey(const ValueKey('library_scan_progress_card'))
            .evaluate()
            .isNotEmpty) {
          renderedProgress = true;
          renderedCoverDuringScan |= decodedCovers.evaluate().isNotEmpty;
        }
      }

      SchedulerBinding.instance.addTimingsCallback(collect);
      try {
        for (var index = 0; index < 40; index++) {
          final work = await Directory(
            path.join(data.importedRoot.path, '作品 $index'),
          ).create();
          final bytes = const AudioDetailJsonCodec().encodeNew(
            AudioDetail.empty(
              AudioDetailTarget.libraryRootFolder(work.path),
            ).copyWith(workTitle: '作品 $index', tags: ['保留标签 $index']),
          );
          final document = File(path.join(work.path, 'doujin-audio.json'));
          await document.writeAsBytes(bytes, flush: true);
          jsonFiles[document] = bytes;
        }
        timings.clear();
        final watch = Stopwatch()..start();
        final outcome = await LibraryScannerService(
          dataSource: _PrivateFolderSource(data.importedRoot.path),
        ).addLibrary(provider: library, labels: _labels);
        final details = await library.importAudioDetailBackups();
        watch.stop();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(outcome?.code, LibraryScanOutcomeCode.libraryImported);
        expect(library.library, hasLength(1201));
        expect(await repository.loadStartupTracks(), hasLength(1201));
        expect(details.failureCount, 0);
        expect(details.importedCount, 40);
        for (final entry in jsonFiles.entries) {
          expect(await entry.key.readAsBytes(), entry.value);
        }
        expect(timings.length, greaterThan(3));
        expect(
          renderedProgress,
          isTrue,
          reason: 'Measure the actual scan progress UI.',
        );
        expect(
          renderedCoverDuringScan,
          isTrue,
          reason: 'Existing decoded covers remain visible during import.',
        );
        final slowFrames = timings
            .where(
              (frame) =>
                  frame.buildDuration.inMilliseconds > 16 ||
                  frame.rasterDuration.inMilliseconds > 16,
            )
            .length;
        debugPrint(
          'LIBRARY_IMPORT platform=${Platform.operatingSystem} tracks=1200 '
          'elapsedMs=${watch.elapsedMilliseconds} frames=${timings.length} slowFrames=$slowFrames',
        );
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(collect);
      }
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

const _labels = LibraryScanLabels(
  chooseMusicFolder: 'Folder',
  chooseLibraryFolder: 'Library',
  chooseAudioFiles: 'Files',
  importedFiles: 'Imported',
  manuallySelectedFiles: 'Selected',
);

class _PrivateFolderSource extends PlatformLibraryScanDataSource {
  _PrivateFolderSource(this.folder);
  final String folder;

  @override
  Future<String?> pickAudioFolder({required String dialogTitle}) async =>
      folder;

  @override
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources) async =>
      true;
}
