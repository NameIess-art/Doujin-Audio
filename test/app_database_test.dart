import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/features/library/domain/library_entry.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'package:doujin_audio/features/player/domain/time_segment_label.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/test_persistence_repository.dart';

void main() {
  late Database db;
  late AppDatabase appDatabase;
  late TestPersistenceRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    appDatabase = AppDatabase.test(db);
    repository = TestPersistenceRepository(database: appDatabase);
  });

  tearDown(() => db.close());

  test('schema starts from version 6', () {
    expect(AppDatabase.schemaVersion, 6);
  });

  test('version 3 migration adds audio detail duration', () async {
    await db.execute('DROP TABLE audio_details');
    await db.execute('''
      CREATE TABLE audio_details (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target_type TEXT NOT NULL,
        target_path TEXT NOT NULL,
        card_cover_path TEXT
      )
    ''');

    await AppDatabase.upgradeSchemaForTest(db, 2, 3);

    final columns = await db.rawQuery('PRAGMA table_info(audio_details)');
    expect(columns.map((row) => row['name']), contains('duration_ms'));
  });

  test('version 4 migration marks existing covers as automatic', () async {
    await db.execute('DROP TABLE audio_details');
    await db.execute('''
      CREATE TABLE audio_details (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target_type TEXT NOT NULL,
        target_path TEXT NOT NULL,
        card_cover_path TEXT,
        duration_ms INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await AppDatabase.upgradeSchemaForTest(db, 3, 4);

    final columns = await db.rawQuery('PRAGMA table_info(audio_details)');
    expect(columns.map((row) => row['name']), contains('card_cover_selected'));
    final selectedColumn = columns.singleWhere(
      (row) => row['name'] == 'card_cover_selected',
    );
    expect(selectedColumn['dflt_value'], '0');
  });

  test('version 6 migration normalizes lists and removes sync table', () async {
    await db.execute('DROP TABLE audio_details');
    await db.execute('DELETE FROM audio_detail_voice_actors');
    await db.execute('DELETE FROM audio_detail_tags');
    await db.execute('''
      CREATE TABLE audio_details (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target_type TEXT NOT NULL,
        target_path TEXT NOT NULL,
        rj_code TEXT NOT NULL DEFAULT '',
        work_title TEXT NOT NULL DEFAULT '',
        circle_name TEXT NOT NULL DEFAULT '',
        voice_actors_json TEXT NOT NULL DEFAULT '[]',
        tags_json TEXT NOT NULL DEFAULT '[]',
        card_cover_path TEXT,
        card_cover_selected INTEGER NOT NULL DEFAULT 0,
        release_date_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        sales_count INTEGER,
        rating REAL,
        created_at_ms INTEGER NOT NULL DEFAULT 0,
        updated_at_ms INTEGER NOT NULL DEFAULT 0,
        UNIQUE(target_type, target_path)
      )
    ''');
    await db.execute('''
      CREATE TABLE audio_detail_backup_sync (
        target_type TEXT NOT NULL,
        target_path TEXT NOT NULL,
        generation INTEGER NOT NULL,
        PRIMARY KEY(target_type, target_path)
      )
    ''');
    await db.insert('audio_details', <String, Object?>{
      'target_type': 'libraryRootFolder',
      'target_path': '/library/work',
      'work_title': 'Kept',
      'voice_actors_json': '["A", "B", "A"]',
      'tags_json': '{broken',
    });

    await AppDatabase.upgradeSchemaForTest(db, 5, 6);

    final columns = await db.rawQuery('PRAGMA table_info(audio_details)');
    expect(
      columns.map((row) => row['name']),
      isNot(contains('voice_actors_json')),
    );
    expect(columns.map((row) => row['name']), isNot(contains('tags_json')));
    final actors = await db.query(
      'audio_detail_voice_actors',
      orderBy: 'sort_order',
    );
    expect(
      actors.map((row) => row['voice_actor']),
      orderedEquals(<String>['A', 'B']),
    );
    expect(await db.query('audio_detail_tags'), isEmpty);
    expect((await db.query('audio_details')).single['work_title'], 'Kept');
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    expect(
      tables.map((row) => row['name']),
      isNot(contains('audio_detail_backup_sync')),
    );
  });

  test(
    'ASMR work list and outbox roll back together on write failure',
    () async {
      final originalWork = _asmrWork(1, 'Original');
      final replacementWork = _asmrWork(1, 'Replacement');
      final originalOperation = AsmrSyncOperation(
        type: AsmrSyncOperationType.favoriteAdd,
        workId: originalWork.id,
        sourceId: originalWork.sourceId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      );
      final replacementOperation = AsmrSyncOperation(
        type: AsmrSyncOperationType.favoriteAdd,
        workId: replacementWork.id,
        sourceId: replacementWork.sourceId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(2),
      );
      await repository.saveAccountSyncState(
        favoriteWorks: <AsmrWork>[originalWork],
        historyWorks: const <AsmrWork>[],
        operations: <AsmrSyncOperation>[originalOperation],
      );
      await db.execute('''
      CREATE TRIGGER fail_sync_operation_insert
      BEFORE INSERT ON asmr_sync_operations
      BEGIN
        SELECT RAISE(ABORT, 'forced sync write failure');
      END
    ''');

      await expectLater(
        repository.saveAccountSyncState(
          favoriteWorks: const <AsmrWork>[],
          historyWorks: <AsmrWork>[replacementWork],
          operations: <AsmrSyncOperation>[replacementOperation],
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(
        (await repository.loadWorkList('favorites')).single.title,
        originalWork.title,
      );
      expect(await repository.loadWorkList('history'), isEmpty);
      expect(
        (await repository.loadSyncOperations()).map(
          (operation) => operation.workId,
        ),
        <int>[originalOperation.workId],
      );
    },
  );

  test('ASMR account state rolls back when history membership fails', () async {
    final original = _asmrWork(1, 'Original', isFavorite: true);
    final replacement = _asmrWork(1, 'Replacement', isFavorite: true);
    final operation = AsmrSyncOperation(
      type: AsmrSyncOperationType.favoriteAdd,
      workId: 1,
      sourceId: original.sourceId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
    );
    await repository.saveAccountSyncState(
      favoriteWorks: <AsmrWork>[original],
      historyWorks: <AsmrWork>[original],
      operations: <AsmrSyncOperation>[operation],
    );
    await db.execute('''
      CREATE TRIGGER fail_history_membership_insert
      BEFORE INSERT ON asmr_work_lists
      WHEN NEW.list_type = 'history'
      BEGIN
        SELECT RAISE(ABORT, 'forced history write failure');
      END
    ''');

    await expectLater(
      repository.saveAccountSyncState(
        favoriteWorks: <AsmrWork>[replacement],
        historyWorks: <AsmrWork>[replacement],
        operations: const <AsmrSyncOperation>[],
      ),
      throwsA(isA<DatabaseException>()),
    );

    expect(
      (await repository.loadWorkList('favorites')).single.title,
      'Original',
    );
    expect((await repository.loadWorkList('history')).single.title, 'Original');
    expect(await repository.loadSyncOperations(), hasLength(1));
  });

  test('ASMR account state writes shared work metadata once', () async {
    final history = _asmrWork(7, 'History metadata', isFavorite: true);
    final favorite = _asmrWork(7, 'Favorite metadata');
    final historyOnly = _asmrWork(8, 'History only', isFavorite: true);

    await repository.saveAccountSyncState(
      favoriteWorks: <AsmrWork>[favorite],
      historyWorks: <AsmrWork>[history, historyOnly],
      operations: const <AsmrSyncOperation>[],
    );

    final reloadedFavorite = (await repository.loadWorkList(
      'favorites',
    )).single;
    final reloadedHistory = await repository.loadWorkList('history');
    expect(reloadedFavorite.title, 'Favorite metadata');
    expect(reloadedHistory.first.title, 'Favorite metadata');
    expect(reloadedFavorite.isFavorite, isTrue);
    expect(reloadedHistory.first.isFavorite, isTrue);
    expect(reloadedHistory.last.isFavorite, isFalse);
  });

  test('ASMR account state removes only unreferenced work metadata', () async {
    final initialHistory = List<AsmrWork>.generate(
      61,
      (index) => _asmrWork(
        index + 1,
        'Work ${index + 1}',
        voiceActors: <String>['Actor ${index + 1}'],
        tags: <String>['Tag ${index + 1}'],
      ),
    );
    final favorite = initialHistory[1];
    await repository.saveAccountSyncState(
      favoriteWorks: <AsmrWork>[favorite],
      historyWorks: initialHistory,
      operations: const <AsmrSyncOperation>[],
    );

    final retainedHistory = <AsmrWork>[
      ...initialHistory.skip(2),
      _asmrWork(62, 'Work 62'),
    ];
    await repository.saveAccountSyncState(
      favoriteWorks: <AsmrWork>[favorite],
      historyWorks: retainedHistory,
      operations: const <AsmrSyncOperation>[],
    );

    expect(await db.query('asmr_works', where: 'id = 1'), isEmpty);
    expect(
      await db.query('asmr_work_voice_actors', where: 'work_id = 1'),
      isEmpty,
    );
    expect(await db.query('asmr_work_tags', where: 'work_id = 1'), isEmpty);
    expect(await db.query('asmr_works', where: 'id = 2'), hasLength(1));
    expect(
      await db.query('asmr_work_voice_actors', where: 'work_id = 2'),
      hasLength(1),
    );
    expect(
      await db.query('asmr_work_tags', where: 'work_id = 2'),
      hasLength(1),
    );
    expect(await repository.loadWorkList('history'), hasLength(60));
  });

  test('ASMR orphan cleanup retains pending remove operation', () async {
    final work = _asmrWork(
      9,
      'Removed work',
      voiceActors: const <String>['Actor'],
      tags: const <String>['Tag'],
    );
    final operation = AsmrSyncOperation(
      type: AsmrSyncOperationType.favoriteRemove,
      workId: work.id,
      sourceId: work.sourceId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
    );
    await repository.saveWorkList('favorites', <AsmrWork>[work]);
    await repository.saveSyncOperations(<AsmrSyncOperation>[operation]);
    await repository.saveWorkList('favorites', const <AsmrWork>[]);

    expect(await db.query('asmr_works'), isEmpty);
    expect(await db.query('asmr_work_voice_actors'), isEmpty);
    expect(await db.query('asmr_work_tags'), isEmpty);
    expect((await repository.loadSyncOperations()).single.workId, work.id);
  });

  test(
    'ASMR orphan cleanup failure rolls back the whole account state',
    () async {
      final original = _asmrWork(1, 'Original', tags: const <String>['Kept']);
      final stale = _asmrWork(
        2,
        'Stale',
        voiceActors: const <String>['Actor'],
        tags: const <String>['Trigger'],
      );
      final originalOperation = AsmrSyncOperation(
        type: AsmrSyncOperationType.favoriteAdd,
        workId: original.id,
        sourceId: original.sourceId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      );
      await repository.saveAccountSyncState(
        favoriteWorks: <AsmrWork>[original],
        historyWorks: <AsmrWork>[stale],
        operations: <AsmrSyncOperation>[originalOperation],
      );
      await db.execute('''
      CREATE TRIGGER fail_orphan_tag_delete
      BEFORE DELETE ON asmr_work_tags
      WHEN OLD.work_id = 2
      BEGIN
        SELECT RAISE(ABORT, 'forced orphan cleanup failure');
      END
    ''');

      await expectLater(
        repository.saveAccountSyncState(
          favoriteWorks: <AsmrWork>[_asmrWork(1, 'Replacement')],
          historyWorks: const <AsmrWork>[],
          operations: const <AsmrSyncOperation>[],
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(
        (await repository.loadWorkList('favorites')).single.title,
        'Original',
      );
      expect((await repository.loadWorkList('history')).single.title, 'Stale');
      expect(
        await db.query('asmr_work_voice_actors', where: 'work_id = 2'),
        hasLength(1),
      );
      expect(
        await db.query('asmr_work_tags', where: 'work_id = 2'),
        hasLength(1),
      );
      expect(await repository.loadSyncOperations(), hasLength(1));
    },
  );

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
          remoteCoverUrl: 'https://example.com/a-cover.jpg',
          remoteMetadataKind: 'asmr.one',
          remoteMetadata: const <String, Object?>{
            'trackRelativePath': 'disc1/a.mp3',
            'playbackUrls': <String>['https://example.com/a.mp3'],
          },
        ),
        MusicTrack(
          path: 'content://media/external/audio/media/42',
          displayName: 'Content Track',
          groupKey: 'content://media',
          groupTitle: 'Imported',
          groupSubtitle: '1 track',
          isSingle: true,
          isVideo: true,
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
      isVideo: true,
      scannedAt: DateTime.fromMillisecondsSinceEpoch(4000),
      fileSizeBytes: 4096,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(5000),
      lastPlayedPosition: const Duration(minutes: 5),
      lastPlayedAt: DateTime.fromMillisecondsSinceEpoch(6000),
      isFavorite: true,
      tags: const <String>['focus'],
      coverCachePath: '/cache/meta.png',
      lyricsPath: '/lyrics/meta.srt',
      remoteCoverUrl: 'https://example.com/meta-cover.jpg',
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: const <String, Object?>{
        'workId': 123,
        'trackRelativePath': 'meta.flac',
      },
    );

    await appDatabase.insertTracks([track]);

    final loaded = await appDatabase.loadAllTracks();
    expect(loaded.single.toJson(), track.toJson());
  });

  test(
    'insertTracks replaces existing rows and deleteTracks removes by path',
    () async {
      final original = MusicTrack(
        path: '/library/a.mp3',
        displayName: 'A',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'old',
        isSingle: false,
      );
      final replacement = MusicTrack(
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

  test('replaceTrackPaths only rewrites affected track rows', () async {
    final original = MusicTrack(
      path: '/library/old/a.flac',
      displayName: 'A',
      groupKey: '/library/old',
      groupTitle: 'Old',
      groupSubtitle: 'Old',
      isSingle: false,
      tags: <String>['asmr'],
      coverCachePath: '/library/old/cover.jpg',
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: <String, Object?>{'workId': 1},
    );
    final untouched = MusicTrack(
      path: '/library/other/b.flac',
      displayName: 'B',
      groupKey: '/library/other',
      groupTitle: 'Other',
      groupSubtitle: 'Other',
      isSingle: false,
      tags: <String>['sleep'],
    );
    final replacement = MusicTrack(
      path: '/library/new/a.flac',
      displayName: 'A',
      groupKey: '/library/new',
      groupTitle: 'New',
      groupSubtitle: 'New',
      isSingle: false,
      tags: <String>['asmr'],
      coverCachePath: '/library/new/cover.jpg',
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: <String, Object?>{'workId': 1},
    );
    await appDatabase.saveAllTracks(<MusicTrack>[original, untouched]);

    await appDatabase.replaceTrackPaths(<String, MusicTrack>{
      original.path: replacement,
    });

    final loaded = await appDatabase.loadAllTracks();
    expect(
      loaded.map((track) => track.path),
      unorderedEquals(<String>[replacement.path, untouched.path]),
    );
    expect(
      (await appDatabase.loadTrackDetail(replacement.path))?.toJson(),
      replacement.toJson(),
    );
    expect(
      (await appDatabase.loadTrackDetail(untouched.path))?.toJson(),
      untouched.toJson(),
    );
    expect(await appDatabase.loadTrackDetail(original.path), isNull);
  });

  test(
    'replaceTrackPaths rejects duplicate destinations before writing',
    () async {
      final first = MusicTrack(
        path: '/library/a.flac',
        displayName: 'A',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'Library',
        isSingle: false,
      );
      final second = MusicTrack(
        path: '/library/b.flac',
        displayName: 'B',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'Library',
        isSingle: false,
      );
      await appDatabase.saveAllTracks(<MusicTrack>[first, second]);

      await expectLater(
        appDatabase.replaceTrackPaths(<String, MusicTrack>{
          first.path: MusicTrack(
            path: '/library/same.flac',
            displayName: 'A',
            groupKey: '/library',
            groupTitle: 'Library',
            groupSubtitle: 'Library',
            isSingle: false,
          ),
          second.path: MusicTrack(
            path: '/library/same.flac',
            displayName: 'B',
            groupKey: '/library',
            groupTitle: 'Library',
            groupSubtitle: 'Library',
            isSingle: false,
          ),
        }),
        throwsArgumentError,
      );

      expect(
        (await appDatabase.loadAllTracks()).map((track) => track.path),
        <String>[first.path, second.path],
      );
    },
  );

  test(
    'deleteTracks batches more than SQLite variable limit atomically',
    () async {
      final tracks = List<MusicTrack>.generate(
        1801,
        (index) => MusicTrack(
          path: '/library/$index.mp3',
          displayName: '$index',
          groupKey: '/library',
          groupTitle: 'Library',
          groupSubtitle: 'Library',
          isSingle: false,
          tags: const <String>['bulk'],
        ),
      );
      await appDatabase.insertTracks(tracks);

      await appDatabase.deleteTracks(
        tracks.map((track) => track.path).toList(growable: false),
      );

      expect(await appDatabase.loadAllTracks(), isEmpty);
      for (final table in <String>[
        'track_tags',
        'track_remote_metadata',
        'track_assets',
        'track_playback_state',
        'track_scan_info',
        'tracks',
      ]) {
        final rows = await db.rawQuery('SELECT COUNT(*) AS count FROM $table');
        final count = (rows.single['count'] as num).toInt();
        expect(count, 0, reason: table);
      }
    },
  );

  test('scan generation helpers keep only the current scan snapshot', () async {
    final first = MusicTrack(
      path: '/library/first.mp3',
      displayName: 'First',
      groupKey: '/library',
      groupTitle: 'Library',
      groupSubtitle: '1 track',
      isSingle: false,
    );
    final second = MusicTrack(
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

    final playbackIndexes = await db.rawQuery(
      'PRAGMA index_list(track_playback_state)',
    );
    final playbackIndexNames = playbackIndexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();
    expect(playbackIndexNames, contains('idx_tracks_last_played_at'));
    expect(playbackIndexNames, contains('idx_tracks_favorite'));

    final scanIndexes = await db.rawQuery('PRAGMA index_list(track_scan_info)');
    final scanIndexNames = scanIndexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();
    expect(scanIndexNames, contains('idx_tracks_scan_generation'));

    final columns = await db.rawQuery('PRAGMA table_info(tracks)');
    final columnNames = columns
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();

    expect(columnNames, isNot(contains('remote_cover_url')));
    expect(columnNames, isNot(contains('remote_metadata_kind')));
    expect(columnNames, isNot(contains('remote_metadata_json')));

    final assetColumns = await db.rawQuery('PRAGMA table_info(track_assets)');
    expect(
      assetColumns.map((row) => row['name']),
      containsAll([
        'cover_cache_path',
        'manual_cover_path',
        'remote_cover_url',
      ]),
    );
    final remoteColumns = await db.rawQuery(
      'PRAGMA table_info(track_remote_metadata)',
    );
    expect(
      remoteColumns.map((row) => row['name']),
      containsAll(['remote_metadata_kind', 'remote_metadata_json']),
    );
  });

  test('loadTrackSummaries reads only main track table fields', () async {
    final track = MusicTrack(
      path: '/library/meta.flac',
      displayName: 'Meta',
      groupKey: '/library',
      groupTitle: 'Library',
      groupSubtitle: '1 track',
      isSingle: false,
      lastPlayedPosition: const Duration(minutes: 5),
      isFavorite: true,
      tags: <String>['focus'],
      coverCachePath: '/cache/meta.png',
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: <String, Object?>{'workId': 123},
    );
    await appDatabase.insertTracks([track]);

    final summary = (await appDatabase.loadTrackSummaries()).single;
    final detail = await appDatabase.loadTrackDetail(track.path);

    expect(summary.path, track.path);
    expect(summary.coverCachePath, isNull);
    expect(summary.remoteMetadataKind, isNull);
    expect(summary.tags, isEmpty);
    expect(summary.isFavorite, isFalse);
    expect(detail?.toJson(), track.toJson());
  });

  test(
    'loadStartupTracks keeps UI fields without eager metadata JSON',
    () async {
      final track = MusicTrack(
        path: '/library/startup.flac',
        displayName: 'Startup',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: '1 track',
        isSingle: false,
        lastPlayedPosition: const Duration(minutes: 3),
        isFavorite: true,
        tags: <String>['focus'],
        coverCachePath: '/cache/startup.png',
        manualCoverPath: '/manual/startup.png',
        remoteCoverUrl: 'https://example.com/startup.jpg',
        remoteMetadataKind: 'asmr.one',
        remoteMetadata: <String, Object?>{'workId': 456},
      );
      await appDatabase.insertTracks([track]);

      final startup = (await appDatabase.loadStartupTracks()).single;
      final detail = await appDatabase.loadTrackDetail(track.path);

      expect(startup.path, track.path);
      expect(startup.coverCachePath, track.coverCachePath);
      expect(startup.manualCoverPath, track.manualCoverPath);
      expect(startup.remoteCoverUrl, track.remoteCoverUrl);
      expect(startup.remoteMetadataKind, track.remoteMetadataKind);
      expect(startup.remoteMetadata, isNull);
      expect(startup.tags, isEmpty);
      expect(startup.isFavorite, isTrue);
      expect(startup.lastPlayedPosition, const Duration(minutes: 3));
      expect(detail?.toJson(), track.toJson());
    },
  );

  test('sessions persist custom queue tracks', () async {
    final queueTrack = MusicTrack(
      path: 'https://example.com/track.mp3',
      displayName: 'Track',
      groupKey: 'asmr-work-1',
      groupTitle: 'ASMR Work',
      groupSubtitle: 'RJ000001',
      isSingle: false,
      remoteCoverUrl: 'https://example.com/cover.jpg',
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: <String, Object?>{
        'trackRelativePath': '01_mp3/track.mp3',
        'subtitleUrl': 'https://example.com/track.vtt',
      },
    );

    await repository.saveAllSessions(<PersistedPlaybackSession>[
      PersistedPlaybackSession(
        id: 'session_1',
        trackPath: 'https://example.com/track.mp3',
        loopModeIndex: 1,
        volume: 0.8,
        speed: 1.5,
        positionMs: 1200,
        durationMs: 3200,
        customQueueTracks: <MusicTrack>[queueTrack],
        channelSwapEnabled: false,
        audioEffects: AudioEffectsState(
          skipSilenceEnabled: true,
          noiseReductionEnabled: true,
          eqEnabled: true,
          eqPresetId: 'voice_clear',
          eqBandLevels: <int, double>{1000: 2.5},
        ),
        sortOrder: 0,
      ),
    ]);

    final loaded = await repository.loadAllSessions();
    expect(loaded, hasLength(1));
    expect(loaded.single.trackPath, 'https://example.com/track.mp3');
    expect(loaded.single.speed, closeTo(1.5, 0.001));
    expect(loaded.single.audioEffects.skipSilenceEnabled, isTrue);
    expect(loaded.single.audioEffects.noiseReductionEnabled, isTrue);
    expect(loaded.single.audioEffects.eqPresetId, 'voice_clear');
    expect(loaded.single.audioEffects.eqBandLevels[1000], 2.5);
    expect(loaded.single.customQueueTracks, hasLength(1));
    expect(
      loaded.single.customQueueTracks!.single.toJson(),
      queueTrack.toJson(),
    );
  });

  test(
    'sessions persist playback queue definition and duplicate index',
    () async {
      final track = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      final queue = PlaybackQueueDefinition(
        name: 'Night queue',
        colorValue: 0xFF336699,
        entries: <PlaybackQueueEntry>[
          PlaybackQueueEntry(
            id: 'entry_1',
            kind: PlaybackQueueEntryKind.track,
            title: '01',
            tracks: <MusicTrack>[track],
          ),
          PlaybackQueueEntry(
            id: 'entry_2',
            kind: PlaybackQueueEntryKind.work,
            title: 'Work',
            workRootPath: '/library/work',
            tracks: <MusicTrack>[track],
          ),
        ],
      );

      await repository.saveAllSessions(<PersistedPlaybackSession>[
        PersistedPlaybackSession(
          id: 'queue_1',
          trackPath: track.path,
          loopModeIndex: 1,
          volume: 1,
          positionMs: 1500,
          durationMs: 3000,
          customQueueTracks: <MusicTrack>[track, track],
          playbackQueue: queue,
          currentQueueIndex: 1,
          channelSwapEnabled: false,
          sortOrder: 0,
        ),
      ]);

      final loaded = (await repository.loadAllSessions()).single;
      expect(loaded.playbackQueue?.name, 'Night queue');
      expect(loaded.playbackQueue?.colorValue, 0xFF336699);
      expect(loaded.playbackQueue?.entries, hasLength(2));
      expect(loaded.playbackQueue?.entries.last.workRootPath, '/library/work');
      expect(loaded.playbackQueue?.expandedTracks, hasLength(2));
      expect(loaded.currentQueueIndex, 1);
    },
  );

  test(
    'loadAllSessions restores multiple sessions with queues and effects',
    () async {
      final firstTrack = MusicTrack(
        path: '/library/work-a/01.mp3',
        displayName: 'A 01',
        groupKey: '/library/work-a',
        groupTitle: 'Work A',
        groupSubtitle: 'A',
        isSingle: false,
      );
      final secondTrack = MusicTrack(
        path: '/library/work-a/02.mp3',
        displayName: 'A 02',
        groupKey: '/library/work-a',
        groupTitle: 'Work A',
        groupSubtitle: 'A',
        isSingle: false,
      );
      final thirdTrack = MusicTrack(
        path: '/library/work-b/01.mp3',
        displayName: 'B 01',
        groupKey: '/library/work-b',
        groupTitle: 'Work B',
        groupSubtitle: 'B',
        isSingle: false,
      );
      final firstQueue = PlaybackQueueDefinition(
        name: 'Queue A',
        colorValue: 0xFFAA5500,
        entries: <PlaybackQueueEntry>[
          PlaybackQueueEntry(
            id: 'a_entry_1',
            kind: PlaybackQueueEntryKind.track,
            title: 'A 01',
            tracks: <MusicTrack>[firstTrack, firstTrack],
          ),
          PlaybackQueueEntry(
            id: 'a_entry_2',
            kind: PlaybackQueueEntryKind.track,
            title: 'A 02',
            tracks: <MusicTrack>[secondTrack],
          ),
        ],
      );
      final secondQueue = PlaybackQueueDefinition(
        name: 'Queue B',
        entries: <PlaybackQueueEntry>[
          PlaybackQueueEntry(
            id: 'b_entry_1',
            kind: PlaybackQueueEntryKind.work,
            title: 'Work B',
            workRootPath: '/library/work-b',
            tracks: <MusicTrack>[thirdTrack],
          ),
        ],
      );

      await repository.saveAllSessions(<PersistedPlaybackSession>[
        PersistedPlaybackSession(
          id: 'session_b',
          trackPath: '/library/work-b/01.mp3',
          loopModeIndex: 2,
          volume: 0.6,
          positionMs: 600,
          durationMs: 3000,
          customQueueTracks: <MusicTrack>[thirdTrack],
          playbackQueue: secondQueue,
          channelSwapEnabled: true,
          audioEffects: AudioEffectsState(
            volumeNormalizationEnabled: true,
            eqEnabled: true,
            eqBandLevels: <int, double>{400: -1.5, 1600: 2.0},
          ),
          sortOrder: 0,
        ),
        PersistedPlaybackSession(
          id: 'session_a',
          trackPath: '/library/work-a/01.mp3',
          loopModeIndex: 1,
          volume: 0.9,
          positionMs: 1200,
          durationMs: 5000,
          customQueueTracks: <MusicTrack>[firstTrack, secondTrack, firstTrack],
          playbackQueue: firstQueue,
          currentQueueIndex: 2,
          channelSwapEnabled: false,
          audioEffects: AudioEffectsState(
            skipSilenceEnabled: true,
            eqEnabled: true,
            eqPresetId: 'voice_clear',
            eqBandLevels: <int, double>{1000: 2.5},
          ),
          sortOrder: 1,
        ),
        PersistedPlaybackSession(
          id: 'session_c',
          trackPath: '/library/work-a/02.mp3',
          loopModeIndex: 1,
          volume: 1,
          positionMs: 0,
          durationMs: 1000,
          customQueueTracks: <MusicTrack>[firstTrack, secondTrack, firstTrack],
          channelSwapEnabled: false,
          sortOrder: 2,
        ),
      ]);

      final loaded = await repository.loadAllSessions();

      expect(loaded.map((session) => session.id), <String>[
        'session_b',
        'session_a',
        'session_c',
      ]);
      expect(loaded.first.channelSwapEnabled, isTrue);
      expect(loaded.first.audioEffects.volumeNormalizationEnabled, isTrue);
      expect(loaded.first.audioEffects.eqBandLevels, <int, double>{
        400: -1.5,
        1600: 2.0,
      });
      expect(
        loaded.first.playbackQueue?.entries.single.workRootPath,
        '/library/work-b',
      );
      expect(loaded.first.customQueueTracks, isNull);

      final restoredQueue = loaded[1].playbackQueue!;
      expect(restoredQueue.name, 'Queue A');
      expect(restoredQueue.colorValue, 0xFFAA5500);
      expect(restoredQueue.entries.map((entry) => entry.id), <String>[
        'a_entry_1',
        'a_entry_2',
      ]);
      expect(
        restoredQueue.entries.first.tracks.map((track) => track.path),
        <String>[firstTrack.path, firstTrack.path],
      );
      expect(
        loaded.last.customQueueTracks?.map((track) => track.path),
        <String>[firstTrack.path, secondTrack.path, firstTrack.path],
      );
      expect(loaded[1].currentQueueIndex, 2);
      expect(loaded[1].audioEffects.eqPresetId, 'voice_clear');
      expect(loaded[1].audioEffects.eqBandLevels[1000], 2.5);
    },
  );

  test('updateSessionOrder only changes session sort order', () async {
    await repository.saveAllSessions(<PersistedPlaybackSession>[
      PersistedPlaybackSession(
        id: 'session_1',
        trackPath: '/library/a.mp3',
        loopModeIndex: 1,
        volume: 0.8,
        positionMs: 1200,
        durationMs: 3200,
        customQueueTracks: null,
        channelSwapEnabled: false,
        sortOrder: 0,
      ),
      PersistedPlaybackSession(
        id: 'session_2',
        trackPath: '/library/b.mp3',
        loopModeIndex: 1,
        volume: 0.4,
        positionMs: 2200,
        durationMs: 4200,
        customQueueTracks: null,
        channelSwapEnabled: true,
        sortOrder: 1,
      ),
    ]);

    await repository.updateSessionOrder(['session_2', 'session_1']);

    final loaded = await repository.loadAllSessions();
    expect(loaded.map((session) => session.id), ['session_2', 'session_1']);
    expect(loaded.first.volume, closeTo(0.4, 0.001));
    expect(loaded.first.channelSwapEnabled, isTrue);
    expect(loaded.last.positionMs, 1200);
  });

  test(
    'updatePlaybackQueueEntryOrder only changes queue entry order',
    () async {
      final firstTrack = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      final secondTrack = MusicTrack(
        path: '/library/work/02.mp3',
        displayName: '02',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      final queue = PlaybackQueueDefinition(
        name: 'Night queue',
        entries: <PlaybackQueueEntry>[
          PlaybackQueueEntry(
            id: 'entry_1',
            kind: PlaybackQueueEntryKind.track,
            title: '01',
            tracks: <MusicTrack>[firstTrack],
          ),
          PlaybackQueueEntry(
            id: 'entry_2',
            kind: PlaybackQueueEntryKind.track,
            title: '02',
            tracks: <MusicTrack>[secondTrack],
          ),
        ],
      );

      await repository.saveAllSessions(<PersistedPlaybackSession>[
        PersistedPlaybackSession(
          id: 'queue_1',
          trackPath: firstTrack.path,
          loopModeIndex: 1,
          volume: 1,
          positionMs: 0,
          durationMs: 0,
          customQueueTracks: queue.expandedTracks,
          playbackQueue: queue,
          channelSwapEnabled: false,
          sortOrder: 0,
        ),
      ]);

      await repository.updatePlaybackQueueEntryOrder('queue_1', [
        'entry_2',
        'entry_1',
      ]);

      final loaded = (await repository.loadAllSessions()).single;
      expect(loaded.playbackQueue?.entries.map((entry) => entry.id), [
        'entry_2',
        'entry_1',
      ]);
      expect(
        loaded.playbackQueue?.entries.first.tracks.single.path,
        secondTrack.path,
      );
      expect(loaded.volume, closeTo(1, 0.001));
    },
  );

  test('audio details round-trip and delete targets in one batch', () async {
    final target = AudioDetailTarget.libraryRootFolder('/library/root');
    final secondTarget = AudioDetailTarget.libraryRootFolder(
      '/library/root/work',
    );
    final detail = AudioDetail(
      target: target,
      rjCode: 'RJ123456',
      workTitle: 'Work',
      circleName: 'Circle',
      voiceActors: const <String>['A', 'B'],
      tags: const <String>['tag'],
      cardCoverPath: '/library/root/cover.jpg',
      cardCoverSelected: true,
      releaseDate: DateTime(2024, 5, 6),
      duration: const Duration(hours: 1, minutes: 2, seconds: 3),
      salesCount: 1234,
      rating: 4.5,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
    );

    await repository.upsert(detail);
    await repository.upsert(AudioDetail.empty(secondTarget));

    final loaded = await repository.load(target);
    expect(loaded?.rjCode, 'RJ123456');
    expect(loaded?.voiceActors, const <String>['A', 'B']);
    expect(loaded?.tags, const <String>['tag']);
    expect(loaded?.cardCoverPath, '/library/root/cover.jpg');
    expect(loaded?.cardCoverSelected, isTrue);
    expect(loaded?.releaseDate, DateTime(2024, 5, 6));
    expect(loaded?.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(loaded?.salesCount, 1234);
    expect(loaded?.rating, 4.5);

    await repository.deleteMany(<AudioDetailTarget>[
      target,
      secondTarget,
      target,
    ]);

    expect(await repository.load(target), isNull);
    expect(await repository.load(secondTarget), isNull);
  });

  test('schema creates audio detail target index', () async {
    final indexes = await db.rawQuery('PRAGMA index_list(audio_details)');
    final indexNames = indexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();

    expect(indexNames, contains('idx_audio_details_target'));
  });

  test('time segment labels round-trip sort and delete by id', () async {
    final first = TimeSegmentLabel(
      id: 'segment_1',
      trackKey: '/library/a.mp3',
      name: 'Opening',
      start: const Duration(seconds: 5),
      end: const Duration(seconds: 12),
      colorValue: 0xFFE57373,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    final second = TimeSegmentLabel(
      id: 'segment_2',
      trackKey: '/library/a.mp3',
      name: 'Earlier',
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 3),
      colorValue: 0xFF64B5F6,
      createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
    );

    await repository.upsertTimeSegmentLabel(first);
    await repository.upsertTimeSegmentLabel(second);

    var labels = await repository.loadTimeSegmentLabels('/library/a.mp3');
    expect(labels.map((label) => label.id), ['segment_2', 'segment_1']);
    expect(labels.last.name, 'Opening');
    expect(labels.last.start, const Duration(seconds: 5));

    await repository.deleteTimeSegmentLabel('segment_2');

    labels = await repository.loadTimeSegmentLabels('/library/a.mp3');
    expect(labels.map((label) => label.id), ['segment_1']);
  });

  test('time segment labels retarget track keys after rename', () async {
    final label = TimeSegmentLabel(
      id: 'segment_1',
      trackKey: PathMatcher.normalize('/library/old/01.mp3'),
      name: 'Part',
      start: const Duration(seconds: 2),
      end: const Duration(seconds: 8),
      colorValue: 0xFFE57373,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    await repository.upsertTimeSegmentLabel(label);

    await appDatabase.retargetTimeSegmentLabelsWithinPath(
      oldRoot: '/library/old',
      newRoot: '/library/new',
    );

    expect(
      await repository.loadTimeSegmentLabels(
        PathMatcher.normalize('/library/old/01.mp3'),
      ),
      isEmpty,
    );
    final moved = await repository.loadTimeSegmentLabels(
      PathMatcher.normalize('/library/new/01.mp3'),
    );
    expect(moved.single.id, 'segment_1');

    await appDatabase.retargetTimeSegmentLabels(
      oldTrackKey: PathMatcher.normalize('/library/new/01.mp3'),
      newTrackKey: PathMatcher.normalize('/library/new/renamed.mp3'),
    );

    expect(
      await repository.loadTimeSegmentLabels(
        PathMatcher.normalize('/library/new/01.mp3'),
      ),
      isEmpty,
    );
    final renamed = await repository.loadTimeSegmentLabels(
      PathMatcher.normalize('/library/new/renamed.mp3'),
    );
    expect(renamed.single.name, 'Part');
  });

  test('schema creates time segment label track index', () async {
    final indexes = await db.rawQuery('PRAGMA index_list(time_segment_labels)');
    final indexNames = indexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();

    expect(indexNames, contains('idx_time_segment_labels_track'));
  });

  test('library entries persist full tree rows and state updates', () async {
    final folder = LibraryEntry.folder(
      libraryPath: '/library',
      path: '/library/work',
      parentPath: '/library',
      state: LibraryEntryState.active,
      displayName: 'work',
    );
    final track = LibraryEntry.track(
      libraryPath: '/library',
      track: MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'work',
        groupSubtitle: '/library/work',
        isSingle: false,
        isVideo: true,
        scannedAt: DateTime.fromMillisecondsSinceEpoch(7000),
        fileSizeBytes: 128,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(8000),
      ),
      parentPath: '/library/work',
      state: LibraryEntryState.active,
    );

    await repository.upsertLibraryEntries([folder, track]);
    await repository.setLibraryEntriesState('/library', [
      '/library/work',
      '/library/work/01.mp3',
    ], LibraryEntryState.excluded);

    final loaded = await repository.loadLibraryEntries('/library');
    expect(loaded, hasLength(2));
    expect(
      loaded.where((entry) => entry.isExcluded).map((entry) => entry.path),
      containsAll([
        PathMatcher.normalize('/library/work'),
        PathMatcher.normalize('/library/work/01.mp3'),
      ]),
    );
    expect(
      loaded.singleWhere((entry) => entry.isTrack).toTrack().isVideo,
      true,
    );

    final indexes = await db.rawQuery('PRAGMA index_list(library_entries)');
    final indexNames = indexes
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();
    expect(indexNames, contains('idx_library_entries_library'));
    expect(indexNames, contains('idx_library_entries_state'));
  });
}

AsmrWork _asmrWork(
  int id,
  String title, {
  bool isFavorite = false,
  List<String> voiceActors = const <String>[],
  List<String> tags = const <String>[],
}) {
  return AsmrWork(
    id: id,
    title: title,
    circleName: 'Circle',
    sourceId: 'RJ${id.toString().padLeft(6, '0')}',
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
    voiceActors: voiceActors,
    tags: tags,
    isFavorite: isFavorite,
  );
}
