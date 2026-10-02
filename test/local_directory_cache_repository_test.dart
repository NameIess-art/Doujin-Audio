import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late AppDatabase database;
  late SqliteLibraryRepository repository;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    database = AppDatabase.test(db);
    repository = SqliteLibraryRepository(database: database);
  });
  tearDown(() => db.close());

  test(
    'persists text and image discoveries including successful empty results',
    () async {
      const files = {
        'version': 1,
        'files': [
          {'name': '台本.txt', 'relativePath': '台本.txt', 'path': r'E:\作品\台本.txt'},
        ],
      };
      await repository.saveDirectorySnapshot(
        kind: 'work_texts',
        key: 'work',
        payload: files,
      );
      await repository.saveDirectorySnapshot(
        kind: 'work_images',
        key: 'work',
        payload: {'version': 1, 'files': []},
      );
      final reopened = SqliteLibraryRepository(database: database);
      expect(
        await reopened.loadDirectorySnapshot(kind: 'work_texts', key: 'work'),
        files,
      );
      expect(
        await reopened.loadDirectorySnapshot(kind: 'work_images', key: 'work'),
        {'version': 1, 'files': <Object?>[]},
      );
    },
  );

  test(
    'clearing discoveries preserves remote browse content and user settings',
    () async {
      await database.saveBrowseSnapshot(
        kind: 'asmr_category',
        scope: 'account',
        key: 'root',
        payload: {'version': 1},
      );
      await repository.saveAppSetting('user_setting', '保留');
      await repository.saveDirectorySnapshot(
        kind: 'work_texts',
        key: 'work',
        payload: {'version': 1, 'files': []},
      );
      await repository.saveDirectorySnapshot(
        kind: 'work_images',
        key: 'work',
        payload: {'version': 1, 'files': []},
      );
      await repository.clearDirectorySnapshots();
      expect(
        await repository.loadDirectorySnapshot(kind: 'work_texts', key: 'work'),
        isNull,
      );
      expect(
        await repository.loadDirectorySnapshot(
          kind: 'work_images',
          key: 'work',
        ),
        isNull,
      );
      expect(
        await database.loadBrowseSnapshot(
          kind: 'asmr_category',
          scope: 'account',
          key: 'root',
        ),
        {'version': 1},
      );
      expect(await repository.loadAppSetting('user_setting'), '保留');
    },
  );
}
