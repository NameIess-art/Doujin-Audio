import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';
import 'package:nameless_audio/features/library/application/cover_image_cache_policy.dart';
import 'package:nameless_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late AppDatabase appDatabase;
  late AudioDetailRepository repository;
  late Directory tempDir;

  final fixedNow = DateTime.fromMillisecondsSinceEpoch(123456);
  final pngCoverBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    appDatabase = AppDatabase.test(db);
    tempDir = await Directory.systemTemp.createTemp('audio_detail_test_');
    repository = AudioDetailRepository(
      databaseRepository: AudioDatabaseRepository(database: appDatabase),
      now: () => fixedNow,
      portableCoverDirectory: () async =>
          Directory('${tempDir.path}${Platform.pathSeparator}portable-covers'),
    );
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
      cardCoverPath: '${tempDir.path}${Platform.pathSeparator}cover.jpg',
      voiceActors: const <String>['A', 'A', ' B '],
      tags: const <String>['tag'],
    );

    final result = await repository.save(detail);

    expect(result.backupSaved, isTrue);
    expect(result.coverPortabilitySkipped, isFalse);
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
    expect(
      backup['cardCoverPath'],
      '${tempDir.path}${Platform.pathSeparator}cover.jpg',
    );
    expect(backup['cardCoverRelativePath'], 'cover.jpg');

    final databaseDetail = await appDatabase.loadAudioDetail(target);
    expect(databaseDetail?.workTitle, 'Work');
    expect(
      databaseDetail?.cardCoverPath,
      '${tempDir.path}${Platform.pathSeparator}cover.jpg',
    );
  });

  test('oversized external cover keeps its path without embedding', () async {
    final workDirectory = Directory(
      '${tempDir.path}${Platform.pathSeparator}work',
    );
    await workDirectory.create();
    final largeCover = File(
      '${tempDir.path}${Platform.pathSeparator}large-cover.png',
    );
    final handle = await largeCover.open(mode: FileMode.write);
    await handle.truncate(maxCoverFileBytes + 1);
    await handle.close();
    final target = AudioDetailTarget.libraryRootFolder(workDirectory.path);

    final result = await repository.save(
      AudioDetail.empty(target).copyWith(cardCoverPath: largeCover.path),
    );

    expect(result.backupSaved, isTrue);
    expect(result.coverPortabilitySkipped, isTrue);
    expect(result.detail.cardCoverPath, largeCover.path);
    final backup =
        jsonDecode(
              await File(
                '${workDirectory.path}${Platform.pathSeparator}'
                '${AudioDetailRepository.backupFileName}',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(backup['cardCoverEmbedded'], isNull);
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

  test('load restores a newer local backup over stale database detail', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final databaseDetail = AudioDetail.empty(target).copyWith(
      workTitle: 'Stale database title',
      duration: const Duration(minutes: 12),
      createdAt: DateTime.utc(2026, 7, 18),
      updatedAt: DateTime.utc(2026, 7, 18),
    );
    await appDatabase.upsertAudioDetail(databaseDetail);
    final backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    );
    await backupFile.writeAsString(
      json.encode(
        AudioDetail.empty(target)
            .copyWith(
              rjCode: 'RJ123456',
              workTitle: 'Current JSON title',
              circleName: 'Current circle',
              voiceActors: const <String>['Voice actor'],
              tags: const <String>['ASMR'],
              createdAt: DateTime.utc(2026, 7, 18),
              updatedAt: DateTime.utc(2026, 7, 19),
            )
            .toBackupJson(),
      ),
    );

    final result = await repository.load(target);

    expect(result.restoredFromBackup, isTrue);
    expect(result.detail.rjCode, 'RJ123456');
    expect(result.detail.workTitle, 'Current JSON title');
    expect(result.detail.circleName, 'Current circle');
    expect(result.detail.voiceActors, const <String>['Voice actor']);
    expect(result.detail.tags, const <String>['ASMR']);
    expect(result.detail.duration, const Duration(minutes: 12));
    final persisted = await appDatabase.loadAudioDetail(target);
    expect(persisted?.workTitle, 'Current JSON title');
    expect(persisted?.duration, const Duration(minutes: 12));
  });

  test('loadMany restores newer JSON details before automatic updates', () async {
    final workFolder = Directory(
      '${tempDir.path}${Platform.pathSeparator}batch-work',
    );
    await workFolder.create();
    final target = AudioDetailTarget.libraryRootFolder(workFolder.path);
    await appDatabase.upsertAudioDetail(
      AudioDetail.empty(target).copyWith(
        workTitle: 'Stale batch title',
        createdAt: DateTime.utc(2026, 7, 18),
        updatedAt: DateTime.utc(2026, 7, 18),
      ),
    );
    await File(
      '${workFolder.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    ).writeAsString(
      json.encode(
        AudioDetail.empty(target)
            .copyWith(
              rjCode: 'RJ654321',
              workTitle: 'Current batch JSON title',
              createdAt: DateTime.utc(2026, 7, 18),
              updatedAt: DateTime.utc(2026, 7, 19),
            )
            .toBackupJson(),
      ),
    );

    final result = (await repository.loadMany(<AudioDetailTarget>[
      target,
    ])).single;

    expect(result.restoredFromBackup, isTrue);
    expect(result.detail.rjCode, 'RJ654321');
    expect(result.detail.workTitle, 'Current batch JSON title');
  });

  test('stale automatic save cannot erase a newer JSON backup', () async {
    final workFolder = Directory(
      '${tempDir.path}${Platform.pathSeparator}stale-save-work',
    );
    await workFolder.create();
    final target = AudioDetailTarget.libraryRootFolder(workFolder.path);
    final staleDetail = AudioDetail.empty(
      target,
    ).copyWith(workTitle: 'Stale cached title');
    await File(
      '${workFolder.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    ).writeAsString(
      json.encode(
        AudioDetail.empty(target)
            .copyWith(
              rjCode: 'RJ998877',
              workTitle: 'Current JSON title',
              circleName: 'Current circle',
              createdAt: DateTime.utc(2026, 7, 18),
              updatedAt: DateTime.utc(2026, 7, 19),
            )
            .toBackupJson(),
      ),
    );

    final saved = await repository.save(
      staleDetail.copyWith(duration: const Duration(minutes: 8)),
      origin: AudioDetailSaveOrigin.automatic,
    );

    expect(saved.detail.rjCode, 'RJ998877');
    expect(saved.detail.workTitle, 'Current JSON title');
    expect(saved.detail.circleName, 'Current circle');
    expect(saved.detail.duration, const Duration(minutes: 8));
    final backup =
        json.decode(
              await File(
                '${workFolder.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(backup['rjCode'], 'RJ998877');
    expect(backup['workTitle'], 'Current JSON title');
    expect(backup['durationMs'], const Duration(minutes: 8).inMilliseconds);
  });

  test('explicit save can clear fields despite a newer JSON backup', () async {
    final workFolder = Directory(
      '${tempDir.path}${Platform.pathSeparator}explicit-save-work',
    );
    await workFolder.create();
    final target = AudioDetailTarget.libraryRootFolder(workFolder.path);
    final current = AudioDetail.empty(target).copyWith(
      rjCode: 'RJ123456',
      workTitle: 'Current title',
      tags: const <String>['old'],
      createdAt: DateTime.utc(2026, 7, 18),
      updatedAt: DateTime.utc(2026, 7, 18),
    );
    await File(
      '${workFolder.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    ).writeAsString(
      json.encode(
        current.copyWith(updatedAt: DateTime.utc(2026, 7, 19)).toBackupJson(),
      ),
    );

    final saved = await repository.save(
      current.copyWith(workTitle: 'Edited title', tags: const <String>[]),
    );

    expect(saved.detail.workTitle, 'Edited title');
    expect(saved.detail.tags, isEmpty);
    final persisted = await appDatabase.loadAudioDetail(target);
    expect(persisted?.workTitle, 'Edited title');
    expect(persisted?.tags, isEmpty);
  });

  test('commit guard prevents stale save side effects', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final original = AudioDetail.empty(target).copyWith(workTitle: 'Original');
    await appDatabase.upsertAudioDetail(
      original.normalizedForSave(DateTime.utc(2026)),
    );

    final future = AudioDetailRepository.runWithCommitGuard(
      () => false,
      () => repository.save(original.copyWith(workTitle: 'Stale')),
    );

    await expectLater(future, throwsA(isA<AudioDetailOperationCancelled>()));
    expect((await appDatabase.loadAudioDetail(target))?.workTitle, 'Original');
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
        'cardCoverPath': '${tempDir.path}${Platform.pathSeparator}legacy.jpg',
        'voiceActors': ['A', 'A', 'B'],
        'tags': ['tag'],
      }),
    );

    final result = await repository.load(target);

    expect(result.restoredFromBackup, isTrue);
    expect(result.detail.workTitle, 'Backup work');
    expect(
      result.detail.cardCoverPath,
      '${tempDir.path}${Platform.pathSeparator}legacy.jpg',
    );
    expect(result.detail.voiceActors, const <String>['A', 'B']);
    expect((await appDatabase.loadAudioDetail(target))?.rjCode, 'RJ654321');
  });

  test('root folder backup restores selected cover after re-import', () async {
    final oldFolder = Directory(
      '${tempDir.path}${Platform.pathSeparator}old-work',
    );
    final coverFolder = Directory(
      '${oldFolder.path}${Platform.pathSeparator}artwork',
    );
    await coverFolder.create(recursive: true);
    final oldCoverPath =
        '${coverFolder.path}${Platform.pathSeparator}selected.jpg';
    await File(oldCoverPath).writeAsBytes(const <int>[1, 2, 3]);
    final oldTarget = AudioDetailTarget.libraryRootFolder(oldFolder.path);

    final saved = await repository.save(
      AudioDetail.empty(
        oldTarget,
      ).copyWith(cardCoverPath: oldCoverPath, cardCoverSelected: true),
    );
    expect(saved.backupSaved, isTrue);

    final newFolder = await oldFolder.rename(
      '${tempDir.path}${Platform.pathSeparator}reimported-work',
    );
    final newTarget = AudioDetailTarget.libraryRootFolder(newFolder.path);
    final restored = await repository.load(newTarget);

    expect(restored.restoredFromBackup, isTrue);
    expect(
      restored.detail.cardCoverPath,
      '${newFolder.path}${Platform.pathSeparator}artwork'
      '${Platform.pathSeparator}selected.jpg',
    );
    expect(restored.detail.cardCoverSelected, isTrue);
  });

  test('derived audio and video covers round-trip through JSON', () async {
    for (final sourceName in <String>[
      'embedded-audio.image',
      'video-frame.jpg',
    ]) {
      final workFolder = Directory(
        '${tempDir.path}${Platform.pathSeparator}$sourceName-work',
      );
      await workFolder.create();
      final cacheFile = File(
        '${tempDir.path}${Platform.pathSeparator}cache-$sourceName',
      );
      await cacheFile.writeAsBytes(pngCoverBytes);
      final target = AudioDetailTarget.libraryRootFolder(workFolder.path);

      final saved = await repository.save(
        AudioDetail.empty(target).copyWith(
          workTitle: sourceName,
          cardCoverPath: cacheFile.path,
          cardCoverSelected: true,
        ),
      );
      expect(saved.backupSaved, isTrue);
      expect(saved.detail.cardCoverPath, isNot(cacheFile.path));
      expect(await File(saved.detail.cardCoverPath!).exists(), isTrue);
      final backupFile = File(
        '${workFolder.path}${Platform.pathSeparator}'
        '${AudioDetailRepository.backupFileName}',
      );
      final backup =
          json.decode(await backupFile.readAsString()) as Map<String, dynamic>;
      final embedded = backup['cardCoverEmbedded'] as Map<String, dynamic>;
      expect(backup['cardCoverRelativePath'], isNull);
      expect(backup['cardCoverSelected'], isTrue);
      expect(embedded['mimeType'], 'image/png');
      expect(embedded['byteLength'], pngCoverBytes.length);
      expect(base64Decode(embedded['data'] as String), pngCoverBytes);

      await cacheFile.delete();
      await repository.delete(target);
      final restored = await repository.load(target);

      expect(restored.restoredFromBackup, isTrue);
      expect(restored.detail.workTitle, sourceName);
      expect(restored.detail.cardCoverSelected, isTrue);
      final restoredCover = File(restored.detail.cardCoverPath!);
      expect(await restoredCover.exists(), isTrue);
      expect(await restoredCover.readAsBytes(), pngCoverBytes);
    }
  });

  test('missing database cache cover self-heals from JSON', () async {
    final workFolder = Directory(
      '${tempDir.path}${Platform.pathSeparator}self-heal-work',
    );
    await workFolder.create();
    final cacheFile = File(
      '${tempDir.path}${Platform.pathSeparator}self-heal-frame.jpg',
    );
    await cacheFile.writeAsBytes(pngCoverBytes);
    final target = AudioDetailTarget.libraryRootFolder(workFolder.path);
    final saved = await repository.save(
      AudioDetail.empty(target).copyWith(
        workTitle: 'Keep database metadata',
        cardCoverPath: cacheFile.path,
      ),
    );
    await cacheFile.delete();
    await File(saved.detail.cardCoverPath!).delete();

    final restored = await repository.load(target);

    expect(restored.restoredFromBackup, isFalse);
    expect(restored.detail.workTitle, 'Keep database metadata');
    expect(restored.detail.cardCoverPath, saved.detail.cardCoverPath);
    expect(
      await File(restored.detail.cardCoverPath!).readAsBytes(),
      pngCoverBytes,
    );
    expect(
      (await appDatabase.loadAudioDetail(target))?.cardCoverPath,
      restored.detail.cardCoverPath,
    );
  });

  test('standalone embedded cover round-trips in array backup', () async {
    final audioDirectory = Directory(
      '${tempDir.path}${Platform.pathSeparator}standalone-work',
    );
    await audioDirectory.create();
    final audioFile = File(
      '${audioDirectory.path}${Platform.pathSeparator}standalone.mp3',
    );
    await audioFile.writeAsBytes(const <int>[1, 2, 3]);
    final cacheFile = File(
      '${tempDir.path}${Platform.pathSeparator}standalone-embedded.image',
    );
    await cacheFile.writeAsBytes(pngCoverBytes);
    final target = AudioDetailTarget.singleAudioFile(audioFile.path);

    await repository.save(
      AudioDetail.empty(target).copyWith(cardCoverPath: cacheFile.path),
    );
    final backupFile = File(
      '${audioDirectory.path}${Platform.pathSeparator}'
      '${AudioDetailRepository.backupFileName}',
    );
    final entries = json.decode(await backupFile.readAsString()) as List;
    expect(
      (entries.single as Map<String, dynamic>)['cardCoverEmbedded'],
      isA<Map<String, dynamic>>(),
    );

    await cacheFile.delete();
    await repository.delete(target);
    final restored = await repository.load(target);

    expect(restored.restoredFromBackup, isTrue);
    expect(
      await File(restored.detail.cardCoverPath!).readAsBytes(),
      pngCoverBytes,
    );
  });

  test(
    'content folder backup restores selected cover after re-import',
    () async {
      const oldTargetPath =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic::OldWork';
      const newTargetPath =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic::ImportedWork';
      const oldCoverPath =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic/document/'
          'primary%3AMusic%2FOldWork%2Fartwork%2Fselected.jpg';
      const expectedCoverPath =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic/document/'
          'primary%3AMusic%2FImportedWork%2Fartwork%2Fselected.jpg';
      final gateway = _MemoryFileCacheGateway();
      final contentRepository = AudioDetailRepository(
        databaseRepository: AudioDatabaseRepository(database: appDatabase),
        fileCacheGateway: gateway,
        now: () => fixedNow,
        portableCoverDirectory: () async => Directory(
          '${tempDir.path}${Platform.pathSeparator}portable-content-covers',
        ),
      );
      final oldTarget = AudioDetailTarget.libraryRootFolder(oldTargetPath);

      final saved = await contentRepository.save(
        AudioDetail.empty(
          oldTarget,
        ).copyWith(cardCoverPath: oldCoverPath, cardCoverSelected: true),
      );
      expect(saved.backupSaved, isTrue);
      expect(
        (json.decode(gateway.backup!)
            as Map<String, dynamic>)['cardCoverRelativePath'],
        'artwork/selected.jpg',
      );
      expect(
        (json.decode(gateway.backup!)
            as Map<String, dynamic>)['cardCoverEmbedded'],
        isNull,
      );

      final restored = await contentRepository.load(
        AudioDetailTarget.libraryRootFolder(newTargetPath),
      );

      expect(restored.restoredFromBackup, isTrue);
      expect(restored.detail.cardCoverPath, expectedCoverPath);
      expect(restored.detail.cardCoverSelected, isTrue);
    },
  );

  test('content folder derived cover restores from embedded JSON', () async {
    const targetPath =
        'content://com.android.externalstorage.documents/tree/'
        'primary%3AMusic::DerivedWork';
    final cacheFile = File(
      '${tempDir.path}${Platform.pathSeparator}android-video-frame.jpg',
    );
    await cacheFile.writeAsBytes(pngCoverBytes);
    final gateway = _MemoryFileCacheGateway();
    final contentRepository = AudioDetailRepository(
      databaseRepository: AudioDatabaseRepository(database: appDatabase),
      fileCacheGateway: gateway,
      now: () => fixedNow,
      portableCoverDirectory: () async => Directory(
        '${tempDir.path}${Platform.pathSeparator}portable-content-derived',
      ),
    );
    final target = AudioDetailTarget.libraryRootFolder(targetPath);

    await contentRepository.save(
      AudioDetail.empty(target).copyWith(cardCoverPath: cacheFile.path),
    );
    final backup = json.decode(gateway.backup!) as Map<String, dynamic>;
    expect(backup['cardCoverRelativePath'], isNull);
    expect(backup['cardCoverEmbedded'], isA<Map<String, dynamic>>());

    // Portable covers written by older versions did not have a reliable
    // selection marker. The embedded payload itself remains authoritative.
    backup['cardCoverSelected'] = false;
    gateway.backup = json.encode(backup);
    final upgraded = await contentRepository.load(target);
    expect(upgraded.detail.cardCoverSelected, isTrue);
    expect(
      (await appDatabase.loadAudioDetail(target))?.cardCoverSelected,
      isTrue,
    );

    await cacheFile.delete();
    await contentRepository.delete(target);
    final restored = await contentRepository.load(target);

    expect(restored.restoredFromBackup, isTrue);
    expect(restored.detail.cardCoverSelected, isTrue);
    expect(
      await File(restored.detail.cardCoverPath!).readAsBytes(),
      pngCoverBytes,
    );
  });

  test('content standalone derived cover restores from array JSON', () async {
    const audioPath =
        'content://com.android.externalstorage.documents/tree/'
        'primary%3AMusic/document/primary%3AMusic%2Fsingle.m4a';
    final cacheFile = File(
      '${tempDir.path}${Platform.pathSeparator}android-embedded.image',
    );
    await cacheFile.writeAsBytes(pngCoverBytes);
    final gateway = _MemoryFileCacheGateway();
    final contentRepository = AudioDetailRepository(
      databaseRepository: AudioDatabaseRepository(database: appDatabase),
      fileCacheGateway: gateway,
      now: () => fixedNow,
      portableCoverDirectory: () async => Directory(
        '${tempDir.path}${Platform.pathSeparator}portable-content-single',
      ),
    );
    final target = AudioDetailTarget.singleAudioFile(audioPath);

    await contentRepository.save(
      AudioDetail.empty(target).copyWith(cardCoverPath: cacheFile.path),
    );
    final entries = json.decode(gateway.singleBackup!) as List;
    expect(
      (entries.single as Map<String, dynamic>)['cardCoverEmbedded'],
      isA<Map<String, dynamic>>(),
    );

    await cacheFile.delete();
    await contentRepository.delete(target);
    final restored = await contentRepository.load(target);

    expect(restored.restoredFromBackup, isTrue);
    expect(
      await File(restored.detail.cardCoverPath!).readAsBytes(),
      pngCoverBytes,
    );
  });

  test('embedded cover with invalid digest is rejected', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final missingCover =
        '${tempDir.path}${Platform.pathSeparator}missing-cache.image';
    final backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}'
      '${AudioDetailRepository.backupFileName}',
    );
    await backupFile.writeAsString(
      json.encode({
        'schemaVersion': 1,
        'type': 'audio-detail',
        'targetType': 'library-root-folder',
        'targetPath': tempDir.path,
        'cardCoverPath': missingCover,
        'cardCoverEmbedded': {
          'encoding': 'base64',
          'mimeType': 'image/png',
          'byteLength': pngCoverBytes.length,
          'sha256': List<String>.filled(64, '0').join(),
          'data': base64Encode(pngCoverBytes),
        },
      }),
    );

    final restored = await repository.load(target);

    expect(restored.restoredFromBackup, isTrue);
    expect(restored.detail.cardCoverPath, missingCover);
  });

  test('loadMany restores missing backups in caller order', () async {
    final firstDir = Directory('${tempDir.path}${Platform.pathSeparator}first');
    final secondDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}second',
    );
    await firstDir.create();
    await secondDir.create();
    final first = AudioDetailTarget.libraryRootFolder(firstDir.path);
    final second = AudioDetailTarget.libraryRootFolder(secondDir.path);
    await File(
      '${firstDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    ).writeAsString(
      jsonEncode(
        AudioDetail.empty(first).copyWith(workTitle: 'First').toBackupJson(),
      ),
    );
    await File(
      '${secondDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    ).writeAsString(
      jsonEncode(
        AudioDetail.empty(second).copyWith(workTitle: 'Second').toBackupJson(),
      ),
    );

    final results = await repository.loadMany(<AudioDetailTarget>[
      second,
      first,
      second,
    ]);

    expect(results.map((result) => result.detail.workTitle), <String>[
      'Second',
      'First',
      'Second',
    ]);
    expect(results.every((result) => result.restoredFromBackup), isTrue);
    expect((await appDatabase.loadAudioDetail(first))?.workTitle, 'First');
    expect((await appDatabase.loadAudioDetail(second))?.workTitle, 'Second');
  });

  test('loadMany reads a shared content backup once', () async {
    final gateway = _MemoryFileCacheGateway();
    repository = AudioDetailRepository(
      databaseRepository: AudioDatabaseRepository(database: appDatabase),
      fileCacheGateway: gateway,
      now: () => fixedNow,
      portableCoverDirectory: () async =>
          Directory('${tempDir.path}${Platform.pathSeparator}portable-covers'),
    );
    const tree =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic';
    const firstPath = '$tree/document/primary%3AMusic%2FAlbum%2F01.mp3';
    const secondPath = '$tree/document/primary%3AMusic%2FAlbum%2F02.mp3';
    final first = AudioDetailTarget.singleAudioFile(firstPath);
    final second = AudioDetailTarget.singleAudioFile(secondPath);
    gateway.singleBackup = jsonEncode(<Map<String, dynamic>>[
      AudioDetail.empty(first).copyWith(workTitle: 'First').toBackupJson(),
      AudioDetail.empty(second).copyWith(workTitle: 'Second').toBackupJson(),
    ]);

    final results = await repository.loadMany(<AudioDetailTarget>[
      second,
      first,
      second,
    ]);

    expect(gateway.singleBackupReadCount, 1);
    expect(results.map((result) => result.detail.workTitle), <String>[
      'Second',
      'First',
      'Second',
    ]);
    expect(results.every((result) => result.restoredFromBackup), isTrue);
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

  test('backup rejects invalid date, sales count, and rating fields', () {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    Map<String, dynamic> backupWith(String field, Object value) =>
        <String, dynamic>{
          'schemaVersion': 1,
          'type': 'audio-detail',
          'targetType': 'library-root-folder',
          'targetPath': tempDir.path,
          field: value,
        };

    expect(
      () => AudioDetail.fromBackupJson(
        target,
        backupWith('releaseDate', 'not-a-date'),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('releaseDate'),
        ),
      ),
    );
    expect(
      () => AudioDetail.fromBackupJson(target, backupWith('salesCount', -1)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('salesCount'),
        ),
      ),
    );
    expect(
      () => AudioDetail.fromBackupJson(target, backupWith('rating', 5.1)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('rating'),
        ),
      ),
    );
  });

  test('save rejects invalid numeric metadata instead of normalizing it', () {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);

    expect(
      () => AudioDetail.empty(
        target,
      ).copyWith(salesCount: -1).normalizedForSave(fixedNow),
      throwsFormatException,
    );
    expect(
      () => AudioDetail.empty(
        target,
      ).copyWith(rating: 6.0).normalizedForSave(fixedNow),
      throwsFormatException,
    );
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
      // Backup is written as an array entry in nameless-audio.json in the
      // same directory as the audio file.
      final backupFile = File(
        '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
      );
      expect(await backupFile.exists(), isTrue);
      final decoded = json.decode(await backupFile.readAsString());
      expect(decoded, isA<List<Object?>>());
      final entries = decoded as List<Object?>;
      expect(entries.length, 1);
      expect((entries.first as Map<String, dynamic>)['workTitle'], 'Single');
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
      // Write the new array-format backup in the same directory.
      final backupFile = File(
        '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
      );
      await backupFile.writeAsString(
        json.encode([
          {
            'schemaVersion': 1,
            'type': 'audio-detail',
            'targetType': 'single-audio-file',
            'targetPath': target.targetPath,
            'rjCode': 'RJ998877',
            'workTitle': 'Single backup work',
            'circleName': 'Single backup circle',
            'voiceActors': ['A', 'B'],
            'tags': ['tag'],
          },
        ]),
      );

      final result = await repository.load(target);

      expect(result.restoredFromBackup, isTrue);
      expect(result.detail.rjCode, 'RJ998877');
      expect(result.detail.workTitle, 'Single backup work');
      expect((await appDatabase.loadAudioDetail(target))?.rjCode, 'RJ998877');
    },
  );

  test(
    'single audio load matches shared backup entry by decoded file name',
    () async {
      const fileName = '#羊娘めめ 20260326 nico 【限定ASMR┊睡眠導入】ゆっくりはむちゅ.mp3';
      final target = AudioDetailTarget.singleAudioFile(
        '${tempDir.path}${Platform.pathSeparator}$fileName',
      );
      final backupFile = File(
        '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
      );
      const backedUpFileName =
          '#羊娘めめ 20260326 nico 【限定ASMR┊睡眠導入】ゆっくりはむちゅ (1).mp3';
      final contentPath =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3ADocuments%2F.ASMR/document/'
          '${Uri.encodeComponent('primary:Documents/.ASMR/$backedUpFileName')}';

      await backupFile.writeAsString(
        json.encode([
          {
            'schemaVersion': 1,
            'type': 'audio-detail',
            'targetType': 'single-audio-file',
            'targetPath': contentPath,
            'rjCode': 'RJ112233',
            'workTitle': 'Decoded file backup',
            'voiceActors': ['羊娘めめ'],
            'tags': ['ASMR'],
          },
        ]),
      );

      final result = await repository.load(target);

      expect(result.restoredFromBackup, isTrue);
      expect(result.detail.rjCode, 'RJ112233');
      expect(result.detail.workTitle, 'Decoded file backup');
      expect(result.detail.voiceActors, const <String>['羊娘めめ']);
      expect((await appDatabase.loadAudioDetail(target))?.rjCode, 'RJ112233');
    },
  );

  test('single audio save updates decoded file-name backup entry', () async {
    const fileName = 'single.mp3';
    final target = AudioDetailTarget.singleAudioFile(
      '${tempDir.path}${Platform.pathSeparator}$fileName',
    );
    final backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
    );
    final contentPath =
        'content://com.android.externalstorage.documents/tree/'
        'primary%3AMusic/document/'
        '${Uri.encodeComponent('primary:Music/$fileName')}';

    await backupFile.writeAsString(
      json.encode([
        {
          'schemaVersion': 1,
          'type': 'audio-detail',
          'targetType': 'single-audio-file',
          'targetPath': contentPath,
          'workTitle': 'Old',
        },
      ]),
    );

    await repository.save(
      AudioDetail.empty(target).copyWith(workTitle: 'Updated'),
    );

    final decoded = json.decode(await backupFile.readAsString()) as List;
    expect(decoded.length, 1);
    expect((decoded.single as Map<String, dynamic>)['workTitle'], 'Updated');
    expect(
      (decoded.single as Map<String, dynamic>)['targetPath'],
      target.targetPath,
    );
  });

  test(
    'multiple single files in the same directory each get their own entry',
    () async {
      final target1 = AudioDetailTarget.singleAudioFile(
        '${tempDir.path}${Platform.pathSeparator}track1.mp3',
      );
      final target2 = AudioDetailTarget.singleAudioFile(
        '${tempDir.path}${Platform.pathSeparator}track2.mp3',
      );

      await repository.save(
        AudioDetail.empty(target1).copyWith(workTitle: 'Track One'),
      );
      await repository.save(
        AudioDetail.empty(target2).copyWith(workTitle: 'Track Two'),
      );

      final backupFile = File(
        '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
      );
      expect(await backupFile.exists(), isTrue);
      final decoded = json.decode(await backupFile.readAsString()) as List;
      expect(decoded.length, 2);

      final result1 = await repository.load(target1);
      final result2 = await repository.load(target2);
      expect(result1.detail.workTitle, 'Track One');
      expect(result2.detail.workTitle, 'Track Two');
    },
  );

  test(
    'updating a single file entry does not duplicate it in the backup',
    () async {
      final target = AudioDetailTarget.singleAudioFile(
        '${tempDir.path}${Platform.pathSeparator}single.mp3',
      );

      await repository.save(
        AudioDetail.empty(target).copyWith(workTitle: 'First'),
      );
      await repository.save(
        AudioDetail.empty(target).copyWith(workTitle: 'Updated'),
      );

      final backupFile = File(
        '${tempDir.path}${Platform.pathSeparator}${AudioDetailRepository.backupFileName}',
      );
      final decoded = json.decode(await backupFile.readAsString()) as List;
      // Still only one entry — no duplicate.
      expect(decoded.length, 1);
      expect((decoded.first as Map<String, dynamic>)['workTitle'], 'Updated');
    },
  );

  test('legacy hidden backup file is ignored', () async {
    final target = AudioDetailTarget.libraryRootFolder(tempDir.path);
    final legacyBackupFile = File(
      '${tempDir.path}${Platform.pathSeparator}.nameless-audio.json',
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

    expect(result.restoredFromBackup, isFalse);
    expect(result.detail.isEmpty, isTrue);
    expect(await appDatabase.loadAudioDetail(target), isNull);
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

class _MemoryFileCacheGateway extends FileCachePlatformGateway {
  _MemoryFileCacheGateway() : super(isAndroid: () => true);

  String? backup;
  String? singleBackup;
  int singleBackupReadCount = 0;

  @override
  Future<bool> writeAudioDetailBackup({
    required String folder,
    required String json,
  }) async {
    backup = json;
    return true;
  }

  @override
  Future<String?> readAudioDetailBackup(String folderPath) async => backup;

  @override
  Future<bool> writeSingleFileDetailBackup({
    required String filePath,
    required String json,
  }) async {
    singleBackup = json;
    return true;
  }

  @override
  Future<String?> readSingleFileDetailBackup(String filePath) async {
    singleBackupReadCount++;
    return singleBackup;
  }
}
