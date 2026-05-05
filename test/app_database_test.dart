import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player/models/music_track.dart';
import 'package:music_player/services/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late AppDatabase appDatabase;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    appDatabase = AppDatabase.test(db);
  });

  tearDown(() => db.close());

  test(
    'saveAllTracks and loadAllTracks round-trip the music library',
    () async {
      const tracks = <MusicTrack>[
        MusicTrack(
          path: '/library/a.mp3',
          displayName: 'A',
          groupKey: '/library',
          groupTitle: 'Library',
          groupSubtitle: '2 tracks',
          isSingle: false,
        ),
        MusicTrack(
          path: 'content://media/external/audio/media/42',
          displayName: 'Content Track',
          groupKey: 'content://media',
          groupTitle: 'Imported',
          groupSubtitle: '1 track',
          isSingle: true,
        ),
      ];

      await appDatabase.saveAllTracks(tracks);

      final loaded = await appDatabase.loadAllTracks();
      expect(loaded.map((track) => track.toJson()), [
        tracks[0].toJson(),
        tracks[1].toJson(),
      ]);
    },
  );

  test(
    'insertTracks replaces existing rows and deleteTracks removes by path',
    () async {
      const original = MusicTrack(
        path: '/library/a.mp3',
        displayName: 'A',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'old',
        isSingle: false,
      );
      const replacement = MusicTrack(
        path: '/library/a.mp3',
        displayName: 'A renamed',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'new',
        isSingle: false,
      );

      await appDatabase.insertTracks([original]);
      await appDatabase.insertTracks([replacement]);

      var loaded = await appDatabase.loadAllTracks();
      expect(loaded, hasLength(1));
      expect(loaded.single.displayName, 'A renamed');
      expect(loaded.single.groupSubtitle, 'new');

      await appDatabase.deleteTracks(['/library/a.mp3']);

      loaded = await appDatabase.loadAllTracks();
      expect(loaded, isEmpty);
    },
  );

  test('tryMigrateFromJson handles legacy SharedPreferences payloads', () {
    final raw = jsonEncode([
      const MusicTrack(
        path: '/legacy/a.mp3',
        displayName: 'Legacy A',
        groupKey: '/legacy',
        groupTitle: 'Legacy',
        groupSubtitle: '1 track',
        isSingle: false,
      ).toJson(),
    ]);

    final migrated = AppDatabase.tryMigrateFromJson(raw);

    expect(migrated, isNotNull);
    expect(migrated!.single.path, '/legacy/a.mp3');
    expect(AppDatabase.tryMigrateFromJson('{bad json'), isNull);
  });
}
