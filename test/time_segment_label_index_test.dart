import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/persistence/persistence_records.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late AppDatabase database;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    database = AppDatabase.test(db);
  });
  tearDown(() => db.close());

  TimeSegmentLabelRecord label(String id, String track, {int start = 0}) =>
      TimeSegmentLabelRecord(
        id: id,
        trackKey: track,
        name: id,
        startMs: start,
        endMs: start + 1000,
        colorValue: 0xff123456,
        createdAtMs: 1,
        updatedAtMs: 2,
      );

  test(
    'version 11 migration backfills every chunk and preserves labels',
    () async {
      await db.execute('DROP TABLE time_segment_labels');
      await db.execute('''
      CREATE TABLE time_segment_labels (
        id TEXT PRIMARY KEY, track_key TEXT NOT NULL, name TEXT NOT NULL,
        start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
        color_value INTEGER NOT NULL, created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    ''');
      final originals = [
        for (var i = 0; i < 1201; i++)
          label(
            '$i',
            r'C:\音声 作品\Album'
                '\\$i.mp3',
            start: i,
          ),
      ];
      final batch = db.batch();
      for (final value in originals) {
        batch.insert('time_segment_labels', value.toRow());
      }
      await batch.commit(noResult: true);

      await AppDatabase.upgradeSchemaForTest(db, 11, 12);
      await AppDatabase.upgradeSchemaForTest(db, 11, 12);

      final rows = await db.query('time_segment_labels');
      expect(rows, hasLength(originals.length));
      for (final row in rows) {
        final original = originals[int.parse(row['id'] as String)];
        expect(TimeSegmentLabelRecord.fromRow(row).toRow(), original.toRow());
        expect(
          row['track_match_key'],
          PathMatcher.equivalenceKey(original.trackKey),
        );
      }
      expect(
        (await database.loadTimeSegmentLabels(
          r'c:/音声 作品/ALBUM/1200.mp3',
        )).single.id,
        '1200',
      );
    },
  );

  test(
    'single-track lookup uses its ordered match index among unrelated labels',
    () async {
      await database.importAudioDetails([], [
        for (var i = 0; i < 2000; i++) label('other-$i', '/other/$i.mp3'),
        label('later', r'C:\音声 作品\Album\01.mp3', start: 50),
        label('earlier', r'c:/音声 作品/ALBUM/01.mp3', start: 10),
      ]);

      final matches = await database.loadTimeSegmentLabels(
        r'C:/音声 作品/album/01.mp3',
      );
      expect(matches.map((value) => value.id), ['earlier', 'later']);
      final plan = await db.rawQuery(
        'EXPLAIN QUERY PLAN SELECT * FROM time_segment_labels '
        'WHERE track_match_key = ? ORDER BY start_ms ASC, created_at_ms ASC',
        [PathMatcher.equivalenceKey(r'C:/音声 作品/album/01.mp3')],
      );
      final details = plan.map((row) => row['detail']).join(' ');
      expect(details, contains('SEARCH'));
      expect(details, contains('idx_time_segment_labels_match'));
      expect(details, isNot(contains('TEMP B-TREE')));
    },
  );

  test(
    'folder ranges preserve SAF, Unicode, wildcard and sibling boundaries',
    () async {
      const root =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic';
      final actual =
          '$root/document/${Uri.encodeComponent('primary:Music/作品/01.mp3')}';
      await database.importAudioDetails([], [
        label('saf', actual),
        label('saf-sibling', '$root::作品 2/01.mp3'),
        label('windows', r'C:\音声 作品\Album_%\Disc\01.mp3'),
        label('windows-sibling', r'C:\音声 作品\Album_ab\01.mp3'),
        label('other-drive', r'D:\音声 作品\Album_%\01.mp3'),
      ]);
      expect(
        (await database.loadTimeSegmentLabels('$root::作品/01.mp3')).single.id,
        'saf',
      );
      expect(
        (await database.loadTimeSegmentLabelsForTarget(
          '$root::作品',
          isFolder: true,
        )).map((value) => value.id),
        ['saf'],
      );
      expect(
        (await database.loadTimeSegmentLabelsForTarget(
          r'c:/音声 作品/ALBUM_%',
          isFolder: true,
        )).map((value) => value.id),
        ['windows'],
      );
      expect(
        (await database.loadTimeSegmentLabelsForTarget(
          'C:\\',
          isFolder: true,
        )).map((value) => value.id),
        ['windows', 'windows-sibling'],
      );
    },
  );

  test(
    'upsert, single rename and folder rename keep matching keys current',
    () async {
      await database.upsertTimeSegmentLabel(label('one', r'C:\Old\01.mp3'));
      await database.retargetTimeSegmentLabels(
        oldTrackKey: r'C:\Old\01.mp3',
        newTrackKey: r'C:\Old\02.mp3',
      );
      expect(await database.loadTimeSegmentLabels(r'c:/old/01.mp3'), isEmpty);
      expect(
        (await database.loadTimeSegmentLabels(r'c:/old/02.mp3')).single.id,
        'one',
      );
      await database.retargetTimeSegmentLabelsWithinPath(
        oldRoot: r'C:\Old',
        newRoot: r'D:\新 目录',
      );
      expect(await database.loadTimeSegmentLabels(r'C:/Old/02.mp3'), isEmpty);
      expect(
        (await database.loadTimeSegmentLabels(r'd:/新 目录/02.mp3')).single.id,
        'one',
      );
      await database.upsertTimeSegmentLabel(label('one', '/replacement.mp3'));
      expect(await database.loadTimeSegmentLabels(r'D:\新 目录\02.mp3'), isEmpty);
      expect(
        (await database.loadTimeSegmentLabels('/replacement.mp3')).single.id,
        'one',
      );
    },
  );
}
