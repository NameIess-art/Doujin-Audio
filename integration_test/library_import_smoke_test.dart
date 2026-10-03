import 'dart:io';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_scan_data_source.dart';
import 'package:doujin_audio/features/library/application/library_scanner_service.dart';
import 'package:doujin_audio/features/library/data/audio_detail_json_codec.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('large library import preserves JSON and keeps rendering', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: CircularProgressIndicator())),
    );
    await tester.runAsync(() async {
      // Keep stress-test sources, database and preferences isolated from user data.
      SharedPreferences.setMockInitialValues({});
      if (Platform.isWindows) sqfliteFfiInit();
      final factory = Platform.isWindows ? databaseFactoryFfi : databaseFactory;
      final db = await factory.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchemaForTest(db);
      final repository = SqliteLibraryRepository(
        database: AppDatabase.test(db),
      );
      final library = LibraryFacade.create(databaseRepository: repository);
      final root = await Directory.systemTemp.createTemp(
        'library_import_smoke_',
      );
      final jsonFiles = <File, List<int>>{};
      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> batch) => timings.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(collect);
      try {
        for (var index = 0; index < 40; index++) {
          final work = await Directory(
            path.join(root.path, '作品 $index'),
          ).create();
          for (var track = 0; track < 30; track++) {
            await File(path.join(work.path, '$track.mp3')).writeAsBytes([0]);
          }
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
        final outcome =
            await LibraryScannerService(
              dataSource: _PrivateFolderSource(root.path),
            ).addLibrary(
              provider: library,
              labels: const LibraryScanLabels(
                chooseMusicFolder: 'Folder',
                chooseLibraryFolder: 'Library',
                chooseAudioFiles: 'Files',
                importedFiles: 'Imported',
                manuallySelectedFiles: 'Selected',
              ),
            );
        final details = await library.importAudioDetailBackups();
        watch.stop();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(outcome?.code, LibraryScanOutcomeCode.libraryImported);
        expect(library.library, hasLength(1200));
        expect(await repository.loadStartupTracks(), hasLength(1200));
        expect(details.failureCount, 0);
        expect(details.importedCount, 40);
        for (final entry in jsonFiles.entries) {
          expect(await entry.key.readAsBytes(), entry.value);
        }
        expect(timings.length, greaterThan(3));
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
        await library.dispose();
        await db.close();
        await root.delete(recursive: true);
      }
    });
  });
}

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
