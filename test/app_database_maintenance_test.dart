import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;
  late String databasePath;
  late AppDatabase appDatabase;

  Future<Database> openManagedDatabase() {
    return databaseFactoryFfi.openDatabase(databasePath);
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'app_database_maintenance_',
    );
    databasePath =
        '${tempDirectory.path}${Platform.pathSeparator}audio_player.db';
    final database = await openManagedDatabase();
    await AppDatabase.createSchemaForTest(database);
    await database.setVersion(AppDatabase.schemaVersion);
    appDatabase = AppDatabase.test(
      database,
      databaseOpener: openManagedDatabase,
      filePathProvider: () async => databasePath,
    );
  });

  tearDown(() async {
    await appDatabase.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test(
    'a write submitted during replacement cannot overwrite restored data',
    () async {
      final actionEntered = Completer<void>();
      final releaseAction = Completer<void>();
      final maintenance = appDatabase.runExclusiveMaintenance<void>(
        replacesDatabase: true,
        action: (_) async {
          actionEntered.complete();
          await releaseAction.future;
        },
      );
      await actionEntered.future;

      final staleWrite = appDatabase.insertTracks(const <MusicTrack>[
        MusicTrack(
          path: '/library/stale.mp3',
          displayName: 'stale',
          groupKey: '/library',
          groupTitle: 'Library',
          groupSubtitle: 'Library',
          isSingle: false,
        ),
      ]);
      releaseAction.complete();
      await maintenance;
      await staleWrite;

      expect(await appDatabase.loadAllTracks(), isEmpty);
    },
  );

  test(
    'a failed replacement releases queued writes without changing epoch',
    () async {
      final actionEntered = Completer<void>();
      final releaseAction = Completer<void>();
      final maintenance = appDatabase.runExclusiveMaintenance<void>(
        replacesDatabase: true,
        action: (_) async {
          actionEntered.complete();
          await releaseAction.future;
          throw StateError('restore failed');
        },
      );
      final maintenanceExpectation = expectLater(maintenance, throwsStateError);
      await actionEntered.future;

      final queuedWrite = appDatabase.insertTracks(const <MusicTrack>[
        MusicTrack(
          path: '/library/queued.mp3',
          displayName: 'queued',
          groupKey: '/library',
          groupTitle: 'Library',
          groupSubtitle: 'Library',
          isSingle: false,
        ),
      ]);
      releaseAction.complete();
      await maintenanceExpectation;
      await queuedWrite;

      expect(
        (await appDatabase.loadAllTracks()).map((track) => track.path),
        <String>['/library/queued.mp3'],
      );
    },
  );
}
