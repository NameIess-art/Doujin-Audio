import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/services/app_database.dart';
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
      final tracks = <MusicTrack>[
        MusicTrack(
          path: '/library/a.mp3',
          displayName: 'A',
          groupKey: '/library',
          groupTitle: 'Library',
          groupSubtitle: '2 tracks',
          isSingle: false,
          scannedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          fileSizeBytes: 1024,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(2000),
          lastPlayedPosition: const Duration(seconds: 12),
          lastPlayedAt: DateTime.fromMillisecondsSinceEpoch(3000),
          isFavorite: true,
          tags: <String>['asmr', 'sleep'],
          coverCachePath: '/cache/cover.jpg',
          lyricsPath: '/lyrics/a.lrc',
        ),
        const MusicTrack(
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

  test('track metadata columns persist scan and library metadata', () async {
    final track = MusicTrack(
      path: '/library/meta.flac',
      displayName: 'Meta',
      groupKey: '/library',
      groupTitle: 'Library',
      groupSubtitle: '1 track',
      isSingle: false,
      scannedAt: DateTime.fromMillisecondsSinceEpoch(4000),
      fileSizeBytes: 4096,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(5000),
      lastPlayedPosition: const Duration(minutes: 5),
      lastPlayedAt: DateTime.fromMillisecondsSinceEpoch(6000),
      isFavorite: true,
      tags: const <String>['focus'],
      coverCachePath: '/cache/meta.png',
      lyricsPath: '/lyrics/meta.srt',
    );

    await appDatabase.insertTracks([track]);

    final loaded = await appDatabase.loadAllTracks();
    expect(loaded.single.toJson(), track.toJson());
  });

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

  test('scan generation helpers keep only the current scan snapshot', () async {
    const first = MusicTrack(
      path: '/library/first.mp3',
      displayName: 'First',
      groupKey: '/library',
      groupTitle: 'Library',
      groupSubtitle: '1 track',
      isSingle: false,
    );
    const second = MusicTrack(
      path: '/library/second.mp3',
      displayName: 'Second',
      groupKey: '/library',
      groupTitle: 'Library',
      groupSubtitle: '1 track',
      isSingle: false,
    );

    final generationOne = await appDatabase.nextScanGeneration();
    await appDatabase.markTracksScanned([first], generation: generationOne);

    final generationTwo = await appDatabase.nextScanGeneration();
    await appDatabase.markTracksScanned([second], generation: generationTwo);
    await appDatabase.deleteTracksMissingFromGeneration(generationTwo);

    final loaded = await appDatabase.loadAllTracks();
    expect(loaded, hasLength(1));
    expect(loaded.single.path, second.path);
  });

  test('schema creates track indexes for query-heavy columns', () async {
    final indexes = await db.rawQuery('PRAGMA index_list(tracks)');
    final indexNames = indexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();

    expect(indexNames, contains('idx_tracks_group_key'));
    expect(indexNames, contains('idx_tracks_display_name'));
    expect(indexNames, contains('idx_tracks_last_played_at'));
    expect(indexNames, contains('idx_tracks_favorite'));
    expect(indexNames, contains('idx_tracks_scan_generation'));
  });
}
