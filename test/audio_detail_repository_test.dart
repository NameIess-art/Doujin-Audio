import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/audio_detail.dart';
import 'package:nameless_audio/services/app_database.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/audio_detail_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late AppDatabase appDatabase;
  late AudioDetailRepository repository;
  late Directory tempDir;

  final fixedNow = DateTime.fromMillisecondsSinceEpoch(123456);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    appDatabase = AppDatabase.test(db);
    repository = AudioDetailRepository(
      databaseRepository: AudioDatabaseRepository(database: appDatabase),
      now: () => fixedNow,
    );
    tempDir = await Directory.systemTemp.createTemp('audio_detail_test_');
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('root folder save writes database and local backup', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final detail = AudioDetail.empty(target).copyWith(
      rjCode: 'rj123456',
      workTitle: ' Work ',
      voiceActors: const <String>['A', 'A', ' B '],
      tags: const <String>['tag'],
    );

    final result = await repository.save(detail);

    expect(result.backupSaved, isTrue);
    expect(result.detail.rjCode, 'RJ123456');
    expect(result.detail.workTitle, 'Work');
    expect(result.detail.voiceActors, const <String>['A', 'B']);

    final backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    );
    expect(await backupFile.exists(), isTrue);

    final backup = json.decode(await backupFile.readAsString());
    expect(backup, isA<Map<String, dynamic>>());
    expect((backup as Map<String, dynamic>)['rjCode'], 'RJ123456');

    final databaseDetail = await appDatabase.loadAudioDetail(target);
    expect(databaseDetail?.workTitle, 'Work');
  });

  test('load prefers normalized database path before local backup', () async {
    final normalizedTarget = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final variantTarget = AudioDetailTarget.libraryRootFolder(
      '${tempDir.path}${Platform.pathSeparator}.',
    );
    final detail = AudioDetail.empty(
      variantTarget,
    ).copyWith(rjCode: 'RJ333333', workTitle: 'Normalized');

    await repository.save(detail);

    final result = await repository.load(normalizedTarget);

    expect(result.restoredFromBackup, isFalse);
    expect(result.detail.rjCode, 'RJ333333');
    expect(result.detail.workTitle, 'Normalized');
  });

  test('manual edits overwrite the local backup file', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final first = AudioDetail.empty(
      target,
    ).copyWith(rjCode: 'RJ111111', workTitle: 'First title');
    final second = AudioDetail.empty(target).copyWith(
      rjCode: 'RJ222222',
      workTitle: 'Second title',
      circleName: 'Circle',
    );

    await repository.save(first);
    final result = await repository.save(second);

    expect(result.backupSaved, isTrue);
    final backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    );
    final backup = json.decode(await backupFile.readAsString());
    expect(backup, isA<Map<String, dynamic>>());
    expect((backup as Map<String, dynamic>)['rjCode'], 'RJ222222');
    expect(backup['workTitle'], 'Second title');
    expect(backup['circleName'], 'Circle');
  });

  test('saving root folder detail removes stale legacy hidden backup', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final legacyBackupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.legacyBackupFileName}',
    );
    await legacyBackupFile.writeAsString(
      json.encode({
        'schemaVersion': 1,
        'type': 'audio-detail',
        'targetType': 'library-root-folder',
        'targetPath': '${tempDir.path}${Platform.pathSeparator}old',
        'rjCode': 'RJ000001',
      }),
    );

    final result = await repository.save(
      AudioDetail.empty(target).copyWith(workTitle: 'Current'),
    );

    expect(result.backupSaved, isTrue);
    expect(await legacyBackupFile.exists(), isFalse);
    expect(
      await File(
        '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
      ).exists(),
      isTrue,
    );
  });

  test('root folder load restores from backup when database is empty', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    );
    await backupFile.writeAsString(
      json.encode({
        'schemaVersion': 1,
        'type': 'audio-detail',
        'targetType': 'library-root-folder',
        'targetPath': tempDir.path,
        'rjCode': 'RJ654321',
        'workTitle': 'Backup work',
        'circleName': 'Backup circle',
        'voiceActors': ['A', 'A', 'B'],
        'tags': ['tag'],
      }),
    );

    final result = await repository.load(target);

    expect(result.restoredFromBackup, isTrue);
    expect(result.detail.workTitle, 'Backup work');
    expect(result.detail.voiceActors, const <String>['A', 'B']);
    expect((await appDatabase.loadAudioDetail(target))?.rjCode, 'RJ654321');
  });

  test('malformed backup returns an empty root detail', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    );
    await backupFile.writeAsString('{bad json');

    final result = await repository.load(target);

    expect(result.restoredFromBackup, isFalse);
    expect(result.detail.isEmpty, isTrue);
  });

  test(
    'single imported audio details use database with local backup fallback',
    () async {
      final target = AudioDetailTarget.singleAudioFile(
        '${tempDir.path}${Platform.pathSeparator}single.mp3',
      );
      final detail = AudioDetail.empty(target).copyWith(workTitle: 'Single');

      final result = await repository.save(detail);

      expect(result.backupAttempted, isTrue);
      expect(result.backupSaved, isTrue);
      expect(result.detail.workTitle, 'Single');
      expect(
        await File(
          '${target.targetPath}${AudioDetailRepository.singleBackupSuffix}',
        ).exists(),
        isTrue,
      );
    },
  );

  test(
    'prefill extracts RJ code from folder name without overwriting',
    () async {
      final target = AudioDetailTarget.libraryRootFolder(tempDir.path);

      final first = await repository.prefillRjCodeFromText(
        target,
        '[RJ123456] Work title',
      );

      expect(first?.detail.rjCode, 'RJ123456');
      expect((await appDatabase.loadAudioDetail(target))?.rjCode, 'RJ123456');

      final second = await repository.prefillRjCodeFromText(
        target,
        'RJ654321 Other work',
      );

      expect(second, isNull);
      expect((await appDatabase.loadAudioDetail(target))?.rjCode, 'RJ123456');
    },
  );

  test('RJ extraction accepts embedded lower-case codes', () {
    expect(AudioDetail.findRjCodeInText('circle_rj987654_title'), 'RJ987654');
    expect(AudioDetail.findRjCodeInText('no code here'), isNull);
  });

  test(
    'single audio load restores from local backup when database is empty',
    () async {
      final target = AudioDetailTarget.singleAudioFile(
        '${tempDir.path}${Platform.pathSeparator}single.mp3',
      );
      final backupFile = File(
        '${target.targetPath}${AudioDetailRepository.singleBackupSuffix}',
      );
      await backupFile.writeAsString(
        json.encode({
          'schemaVersion': 1,
          'type': 'audio-detail',
          'targetType': 'single-audio-file',
          'targetPath': target.targetPath,
          'rjCode': 'RJ998877',
          'workTitle': 'Single backup work',
          'circleName': 'Single backup circle',
          'voiceActors': ['A', 'B'],
          'tags': ['tag'],
        }),
      );

      final result = await repository.load(target);

      expect(result.restoredFromBackup, isTrue);
      expect(result.detail.rjCode, 'RJ998877');
      expect(result.detail.workTitle, 'Single backup work');
      expect((await appDatabase.loadAudioDetail(target))?.rjCode, 'RJ998877');
    },
  );

  test('legacy hidden backup file is still readable', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final legacyBackupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.legacyBackupFileName}',
    );
    await legacyBackupFile.writeAsString(
      json.encode({
        'schemaVersion': 1,
        'type': 'audio-detail',
        'targetType': 'library-root-folder',
        'targetPath': tempDir.path,
        'rjCode': 'RJ777777',
        'workTitle': 'Legacy backup',
      }),
    );

    final result = await repository.load(target);

    expect(result.restoredFromBackup, isTrue);
    expect(result.detail.rjCode, 'RJ777777');
    expect(result.detail.workTitle, 'Legacy backup');
  });

  test('legacy backup cannot retarget the current folder path', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final stalePath =
        '${tempDir.parent.path}${Platform.pathSeparator}Old Folder Name';
    final legacyBackupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.legacyBackupFileName}',
    );
    await legacyBackupFile.writeAsString(
      json.encode({
        'schemaVersion': 1,
        'type': 'audio-detail',
        'targetType': 'library-root-folder',
        'targetPath': stalePath,
        'rjCode': 'RJ111222',
        'workTitle': 'Stale backup',
      }),
    );

    final result = await repository.load(target);

    expect(result.restoredFromBackup, isTrue);
    expect(result.detail.target.targetPath, target.targetPath);
    expect(
      (await appDatabase.loadAudioDetail(target))?.target.targetPath,
      target.targetPath,
    );
  });

  test('backup with mismatched target type is ignored', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    );
    await backupFile.writeAsString(
      json.encode({
        'schemaVersion': 1,
        'type': 'audio-detail',
        'targetType': 'single-audio-file',
        'targetPath': '${tempDir.path}${Platform.pathSeparator}single.mp3',
        'rjCode': 'RJ333444',
        'workTitle': 'Wrong target',
      }),
    );

    final result = await repository.load(target);

    expect(result.restoredFromBackup, isFalse);
    expect(result.detail.isEmpty, isTrue);
    expect(await appDatabase.loadAudioDetail(target), isNull);
  });
}
