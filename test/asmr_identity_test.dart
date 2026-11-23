import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AsmrWork work(
  int id,
  String code, {
  AsmrCatalogSource source = AsmrCatalogSource.asmrOne,
}) => AsmrWork.fromJson({
  'id': id,
  'title': '$source $id',
  'sourceId': code,
  'resources': [
    {
      'source': source.name,
      'id': id,
      'code': code,
      'pageUrl': 'https://example.com/$id',
    },
  ],
});

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'work identity normalizes codes without pretending other codes are RJ',
    () {
      expect(work(1, ' rj_00123 ').workKey, 'code:RJ000123');
      expect(work(1, 'RJ1').workKey, work(1, 'RJ000001').workKey);
      expect(work(1, 'RJ01000001').workKey, 'code:RJ01000001');
      expect(work(1, 'UN00123').workCode, 'UN00123');
      expect(work(1, 'und-00123').workCode, 'UND00123');
      expect(work(1, 'd_00123').workCode, 'UND00123');
      expect(work(1, 'UN00123').rjCode, isEmpty);
      expect(work(1, 'unknown').workKey, 'source:asmrOne:1');
      expect(
        work(1, 'unknown', source: AsmrCatalogSource.japaneseAsmr).workKey,
        'source:japaneseAsmr:1',
      );
    },
  );

  test('same code merges both resources and prefers ASMR.ONE metadata', () {
    final one = work(123, 'RJ00123');
    expect(one.mergedWith(one), same(one));
    final jp = work(99, 'rj00123', source: AsmrCatalogSource.japaneseAsmr);
    final merged = jp.mergedWith(one);
    expect(merged.id, 123);
    expect(merged.title, one.title);
    expect(
      merged.resources.map((resource) => resource.source),
      AsmrCatalogSource.values,
    );
    final restored = AsmrWork.fromJson(
      jsonDecode(jsonEncode(merged.toJson())) as Map<String, dynamic>,
    );
    expect(restored.workKey, merged.workKey);
    expect(
      restored.resources.map((resource) => resource.toJson()),
      merged.resources.map((resource) => resource.toJson()),
    );
    expect(() => one.mergedWith(work(123, 'UN00123')), throwsArgumentError);
  });

  test('old JSON defaults to ASMR.ONE resource', () {
    final legacy = AsmrWork.fromJson(const {'id': 123, 'source_id': 'RJ00123'});
    expect(legacy.resources.single.source, AsmrCatalogSource.asmrOne);
    expect(legacy.workKey, 'code:RJ000123');
  });

  test('legacy Japanese ASMR JSON preserves its catalog source', () {
    const pageUrl = 'https://japaneseasmr.com/work/151961';
    const legacy = {
      'id': 151961,
      'sourceId': 'RJ01741028',
      'sourceType': 'jp-asmr',
      'sourceUrl': pageUrl,
    };
    final legacyResource = work(151961, 'RJ01741028').resources.single;
    final mislabeled = {...legacyResource.toJson(), 'pageUrl': pageUrl};
    for (final json in [
      legacy,
      {
        ...legacy,
        'resources': [mislabeled],
      },
    ]) {
      final restored = AsmrWork.fromJson(json);
      expect(restored.resources.single.source, AsmrCatalogSource.japaneseAsmr);
      expect(restored.workKey, 'code:RJ01741028');
    }
    final dual = AsmrWork.fromJson({
      ...legacy,
      'resources': [
        mislabeled,
        work(1741028, 'RJ01741028').resources.single.toJson(),
      ],
    });
    expect(dual.resourceFor(AsmrCatalogSource.asmrOne)?.id, 1741028);
    expect(dual.resourceFor(AsmrCatalogSource.japaneseAsmr)?.id, 151961);
  });

  test(
    'identity remains stable across reads and resolves new resources on copy',
    () {
      final original = work(
        99,
        'unknown',
        source: AsmrCatalogSource.japaneseAsmr,
      );
      expect(original.workCode, isEmpty);
      expect(original.workKey, 'source:japaneseAsmr:99');
      final merged = original.mergeResources(const [
        AsmrWorkResource(
          source: AsmrCatalogSource.asmrOne,
          id: 123,
          code: 'rj_00123',
          pageUrl: 'https://example.com/123',
        ),
      ]);
      for (var i = 0; i < 20; i++) {
        expect(merged.workCode, 'RJ000123');
        expect(merged.workKey, 'code:RJ000123');
        expect(merged.rjCode, 'RJ000123');
        expect(original.workCode, isEmpty);
        expect(original.workKey, 'source:japaneseAsmr:99');
      }
      expect(merged.copyWith(isFavorite: true).workKey, merged.workKey);
      expect(AsmrWork.fromJson(merged.toJson()).workKey, merged.workKey);
      final preferred = work(7, 'UND7').mergeResources(merged.resources);
      expect(preferred.workCode, 'UND7');
      expect(preferred.workKey, 'code:UND7');
    },
  );

  test('SQLite preserves equal numeric IDs from different sources', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await AppDatabase.createSchemaForTest(db);
    final repository = SqliteAsmrRepository(database: AppDatabase.test(db));
    final one = work(1, 'RJ1');
    final jp = work(1, 'UN1', source: AsmrCatalogSource.japaneseAsmr);
    await repository.saveWorkList('favorites', [one, jp]);
    await repository.saveHistoryState(work: jp, historyWorkKeys: [jp.workKey]);
    final favorites = await repository.loadWorkList('favorites');
    expect(favorites.map((work) => work.workKey), [
      'code:RJ000001',
      'code:UN1',
    ]);
    expect(
      favorites.last.resources.single.source,
      AsmrCatalogSource.japaneseAsmr,
    );
    expect(
      (await repository.loadWorkList('history')).single.workKey,
      jp.workKey,
    );
    expect(await repository.loadSyncOperations(), isEmpty);
  });

  test(
    'version 14 migration keeps list order, metadata and sync outbox',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await AppDatabase.createSchemaForTest(db);
      await createLegacyAsmrTables(db);
      for (final id in [2, 1]) {
        await db.insert('asmr_works', {
          'id': id,
          'title': 'Kept $id',
          'source_id': 'RJ$id',
        });
        await db.insert('asmr_work_lists', {
          'list_type': 'favorites',
          'work_id': id,
          'sort_order': 2 - id,
        });
        await db.insert('asmr_work_lists', {
          'list_type': 'history',
          'work_id': id,
          'sort_order': id,
        });
        await db.insert('asmr_work_tags', {
          'work_id': id,
          'tag': 'tag$id',
          'sort_order': 0,
        });
        await db.insert('asmr_work_voice_actors', {
          'work_id': id,
          'name': 'voice$id',
          'sort_order': 0,
        });
      }
      await db.insert('asmr_sync_operations', {
        'type': 'favoriteAdd',
        'work_id': 2,
        'source_id': 'RJ2',
        'created_at_ms': 42,
      });
      await AppDatabase.upgradeSchemaForTest(db, 14, 15);
      final repository = SqliteAsmrRepository(database: AppDatabase.test(db));
      final favorites = await repository.loadWorkList('favorites');
      expect(favorites.map((work) => work.workKey), [
        'code:RJ000002',
        'code:RJ000001',
      ]);
      expect(
        (await repository.loadWorkList('history')).map((work) => work.workKey),
        ['code:RJ000001', 'code:RJ000002'],
      );
      expect(favorites.first.tags, ['tag2']);
      expect(favorites.first.voiceActors, ['voice2']);
      expect(
        favorites.first.resources.single.source,
        AsmrCatalogSource.asmrOne,
      );
      expect((await repository.loadSyncOperations()).single.workId, 2);
    },
  );
  test(
    'version 19 backup repairs Japanese ASMR resources and obsolete uploads',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asmr_source_restore_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/legacy.db';
      final legacy = await databaseFactoryFfi.openDatabase(path);
      await AppDatabase.createSchemaForTest(legacy);
      const code = 'RJ01741028';
      const workId = 151961;
      const key = 'code:$code';
      const pageUrl = 'https://japaneseasmr.com/work/151961';
      await legacy.insert('asmr_works', {
        'work_key': key,
        'id': workId,
        'source_id': code,
        'source_type': 'jp-asmr',
        'source_url': pageUrl,
        'resources_json': jsonEncode([
          {'source': 'asmrOne', 'id': workId, 'code': code, 'pageUrl': pageUrl},
          work(1741028, code).resources.single.toJson(),
        ]),
      });
      for (final list in ['favorites', 'history']) {
        await legacy.insert('asmr_work_lists', {
          'list_type': list,
          'work_id': key,
        });
      }
      final operations = [
        ('historyListening', workId, code),
        ('favoriteRemove', workId, code),
        ('favoriteAdd', workId, 'RJ000004'),
        ('favoriteAdd', 1741028, code),
      ];
      for (final (index, (type, id, source)) in operations.indexed) {
        await legacy.insert('asmr_sync_operations', {
          'type': type,
          'work_id': id,
          'source_id': source,
          'created_at_ms': 42,
          'sort_order': index,
        });
      }
      await legacy.setVersion(19);
      await legacy.close();

      expect(
        await AppDatabase.instance.validateAndMigrateRestoreCandidate(path),
        19,
      );
      final migrated = await databaseFactoryFfi.openDatabase(path);
      addTearDown(migrated.close);
      final repository = SqliteAsmrRepository(
        database: AppDatabase.test(migrated),
      );
      for (final list in ['favorites', 'history']) {
        final entry = (await repository.loadWorkList(list)).single;
        expect(entry.workKey, key);
        expect(entry.resourceFor(AsmrCatalogSource.japaneseAsmr)?.id, workId);
        expect(entry.resourceFor(AsmrCatalogSource.asmrOne)?.id, 1741028);
      }
      final persisted = (await migrated.query('asmr_works')).single;
      final resources =
          jsonDecode(persisted['resources_json'] as String) as List;
      expect(resources.map((resource) => resource['source']), [
        'japaneseAsmr',
        'asmrOne',
      ]);
      expect(
        (await repository.loadSyncOperations()).map(
          (op) => (op.workId, op.sourceId),
        ),
        [(workId, 'RJ000004'), (1741028, code)],
      );
      expect(await migrated.getVersion(), AppDatabase.schemaVersion);
    },
  );
  test(
    'restore validation accepts and migrates an actual version 14 backup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'online_library_restore_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/legacy.db';
      final legacy = await databaseFactoryFfi.openDatabase(path);
      await AppDatabase.createSchemaForTest(legacy);
      await createLegacyAsmrTables(legacy);
      await legacy.insert('asmr_works', {
        'id': 7,
        'title': 'Retained',
        'source_id': 'RJ000007',
      });
      await legacy.insert('asmr_work_lists', {
        'list_type': 'favorites',
        'work_id': 7,
        'sort_order': 0,
      });
      await legacy.insert('asmr_works', {
        'id': 8,
        'title': 'Japanese ASMR',
        'source_type': 'jp-asmr',
      });
      await legacy.insert('asmr_work_lists', {
        'list_type': 'history',
        'work_id': 8,
      });
      await legacy.insert('asmr_work_tags', {
        'work_id': 8,
        'tag': 'Retained tag',
      });
      await legacy.insert('asmr_sync_operations', {
        'type': 'historyListening',
        'work_id': 8,
        'created_at_ms': 42,
      });
      await legacy.setVersion(14);
      await legacy.close();
      final unused = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      addTearDown(unused.close);
      final validator = AppDatabase.test(unused);
      expect(await validator.validateAndMigrateRestoreCandidate(path), 14);
      final migrated = await databaseFactoryFfi.openDatabase(path);
      addTearDown(migrated.close);
      final repository = SqliteAsmrRepository(
        database: AppDatabase.test(migrated),
      );
      expect(
        (await repository.loadWorkList('favorites')).single.workKey,
        'code:RJ000007',
      );
      final history = (await repository.loadWorkList('history')).single;
      expect(history.workKey, 'source:japaneseAsmr:8');
      expect(history.tags, ['Retained tag']);
      expect(await repository.loadSyncOperations(), isEmpty);
      expect(await migrated.getVersion(), AppDatabase.schemaVersion);
    },
  );
}

Future<void> createLegacyAsmrTables(Database db) async {
  for (final table in [
    'asmr_works',
    'asmr_work_lists',
    'asmr_work_tags',
    'asmr_work_voice_actors',
  ]) {
    var sql =
        (await db.rawQuery('SELECT sql FROM sqlite_master WHERE name = ?', [
              table,
            ])).single['sql']!
            as String;
    if (table == 'asmr_works') {
      sql = sql
          .replaceFirst('work_key TEXT PRIMARY KEY,', '')
          .replaceFirst('resources_json TEXT,', '')
          .replaceFirst('id INTEGER NOT NULL,', 'id INTEGER PRIMARY KEY,');
    } else {
      sql = sql.replaceFirst(
        'work_id TEXT NOT NULL',
        'work_id INTEGER NOT NULL',
      );
    }
    await db.execute('DROP TABLE $table');
    await db.execute(sql);
  }
}
