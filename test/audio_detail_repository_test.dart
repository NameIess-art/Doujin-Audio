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

  test('single imported audio details are database-only', () async {
    final target = AudioDetailTarget.singleAudioFile(
      '${tempDir.path}${Platform.pathSeparator}single.mp3',
    );
    final detail = AudioDetail.empty(target).copyWith(workTitle: 'Single');

    final result = await repository.save(detail);

    expect(result.backupAttempted, isFalse);
    expect(result.detail.workTitle, 'Single');
    expect(
      await File(
        '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
      ).exists(),
      isFalse,
    );
  });

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
}
