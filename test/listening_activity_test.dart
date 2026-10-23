import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/player/application/listening_activity_service.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/features/player/domain/listening_activity.dart';
import 'package:doujin_audio/features/player/domain/playback_usage.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_listening_activity_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late SqliteListeningActivityRepository repository;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    repository = SqliteListeningActivityRepository(
      database: AppDatabase.test(db),
    );
  });
  tearDown(() => db.close());

  test(
    'Android channel remote usage imports metadata and can be retried',
    () async {
      const channel = MethodChannel(NativePlaybackChannel.name);
      final remote = MusicTrack(
        path: 'https://example.com/audio.mp3',
        displayName: 'Remote track',
        groupKey: 'asmr:123',
        groupTitle: 'Remote work',
        groupSubtitle: 'RJ123456',
        isSingle: false,
        remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne,
        remoteMetadata: {
          'id': 123,
          'title': 'Remote work',
          'tags': [
            {'id': 7, 'name': 'ASMR'},
          ],
          'circle': {'id': 8, 'name': 'Circle'},
        },
      );
      final batch = PlaybackUsageBatch(
        id: 'android:channel:1',
        days: [
          PlaybackUsageDay(
            date: '2026-10-23',
            totalMs: 60000,
            works: [
              PlaybackUsageWork(
                key: 'rj:RJ123456',
                milliseconds: 60000,
                lastPlayedAtMs: 1000,
                path: remote.path,
                descriptor: remote.toJson(),
              ),
            ],
          ),
        ],
      );
      final acknowledged = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'readUsage') {
              return {
                'ok': true,
                'value': [batch.toMap()],
              };
            }
            expect(call.method, 'acknowledgeUsage');
            acknowledged.addAll(
              List<String>.from((call.arguments as Map)['batchIds'] as List),
            );
            return {'ok': true, 'value': null};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final bridge = NativePlaybackBridge.instance;
      final service = ListeningActivityService(
        repository: repository,
        readUsage: bridge.readUsage,
        acknowledgeUsage: bridge.acknowledgeUsage,
        resolveTrack: (_) => null,
        recordInterests: ({required batchId, required contributions}) async {
          expect(contributions.single.tags, ['ASMR']);
          expect(contributions.single.duration, const Duration(minutes: 1));
        },
      );
      addTearDown(service.dispose);
      await service.refresh();
      await service.refresh();
      final view = await service.states.first;
      expect(view.days.single.duration, const Duration(minutes: 1));
      expect(view.history.single.track.remoteMetadata, remote.remoteMetadata);
      expect(view.history.single.track.groupTitle, 'Remote work');
      expect(acknowledged, [batch.id, batch.id]);
    },
  );

  test(
    'activity waits for the first read and replays only loaded snapshots',
    () async {
      var usage = Completer<List<PlaybackUsageBatch>>();
      final service = ListeningActivityService(
        repository: repository,
        readUsage: () => usage.future,
        acknowledgeUsage: (_) async {},
        resolveTrack: (_) => null,
        recordInterests: ({required batchId, required contributions}) async {},
      );
      addTearDown(service.dispose);
      final snapshots = <ListeningActivityView>[];
      final errors = <Object>[];
      final subscription = service.states.listen(
        snapshots.add,
        onError: (Object error, StackTrace stack) => errors.add(error),
      );
      addTearDown(subscription.cancel);
      final refresh = service.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, isEmpty);
      usage.completeError(StateError('first read failed'));
      await expectLater(refresh, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect(snapshots, isEmpty);
      usage = Completer<List<PlaybackUsageBatch>>();
      final retry = service.refresh();
      usage.complete([]);
      await retry;
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, hasLength(1));
      expect(snapshots.single.history, isEmpty);
      expect(await service.states.first, same(snapshots.single));
    },
  );

  test(
    'real version 13 backup without listening tables validates and migrates',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'listening-restore-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/old.db';
      final old = await databaseFactoryFfi.openDatabase(path);
      await AppDatabase.createSchemaForTest(old);
      for (final table in [
        'listening_days',
        'listening_work_days',
        'listening_history',
        'listening_imports',
      ]) {
        await old.execute('DROP TABLE $table');
      }
      await old.execute('PRAGMA user_version = 13');
      await old.close();
      expect(
        await AppDatabase.test(db).validateAndMigrateRestoreCandidate(path),
        13,
      );
      final migrated = await databaseFactoryFfi.openDatabase(path);
      try {
        expect(
          (await migrated.rawQuery(
            'PRAGMA user_version',
          )).single['user_version'],
          14,
        );
        expect(await migrated.query('listening_history'), isEmpty);
      } finally {
        await migrated.close();
      }
    },
  );

  test(
    'version 13 migration adds listening tables without changing existing settings',
    () async {
      final database = AppDatabase.test(db);
      await database.saveAppSetting('preserve', 'value');
      for (final table in [
        'listening_days',
        'listening_work_days',
        'listening_history',
        'listening_imports',
      ]) {
        await db.execute('DROP TABLE $table');
      }
      await AppDatabase.upgradeSchemaForTest(db, 13, 14);
      expect(await database.loadAppSetting('preserve'), 'value');
      expect(await repository.importBatch('migration:1', [_day(1000)]), isTrue);
      expect((await repository.loadDays()).single.duration.inSeconds, 1);
    },
  );

  test('batch import is atomic and idempotent across restart', () async {
    final days = [_day(60000)];
    expect(await repository.importBatch('android:epoch:1', days), isTrue);
    final reopened = SqliteListeningActivityRepository(
      database: AppDatabase.test(db),
    );
    expect(await reopened.importBatch('android:epoch:1', days), isFalse);
    expect(
      (await reopened.loadDays()).single.duration,
      const Duration(minutes: 1),
    );
    expect((await reopened.loadHistory()).single.track.groupTitle, 'Work');
    expect(await reopened.importBatch('android:epoch:2', days), isTrue);
    expect(
      (await reopened.loadDays()).single.duration,
      const Duration(minutes: 2),
    );
  });

  test(
    'legacy seed preserves history without adding listening time and runs once',
    () async {
      await repository.seedHistory([
        ListeningHistoryEntry(workKey: 'work', track: _track()),
      ]);
      await repository.seedHistory([
        ListeningHistoryEntry(workKey: 'other', track: _track()),
      ]);
      expect(await repository.loadDays(), isEmpty);
      expect((await repository.loadHistory()).length, 1);
      expect((await repository.loadHistory()).single.lastPlayedAt, isNull);
    },
  );

  test(
    'legacy remote history retains source order without invented timestamps',
    () async {
      await repository.seedHistory([
        ListeningHistoryEntry(workKey: 'z-recent', track: _track()),
        ListeningHistoryEntry(workKey: 'a-older', track: _track()),
      ]);
      final history = await repository.loadHistory();
      expect(history.map((entry) => entry.workKey), ['z-recent', 'a-older']);
      expect(history.every((entry) => entry.lastPlayedAt == null), isTrue);
    },
  );

  test('history paging is deterministic for identical timestamps', () async {
    for (var i = 0; i < 45; i++) {
      await repository.importBatch('batch:$i', [
        ListeningDayContribution(
          date: '2026-10-23',
          totalMs: 1,
          works: [
            ListeningWorkContribution(
              workKey: 'work-${i.toString().padLeft(2, '0')}',
              track: _track(),
              milliseconds: 1,
              lastPlayedAtMs: 1000,
            ),
          ],
        ),
      ]);
    }
    final first = await repository.loadHistory();
    final second = await repository.loadHistory(offset: 40);
    expect(first.length, 40);
    expect(second.length, 5);
    expect(
      {...first.map((e) => e.workKey), ...second.map((e) => e.workKey)}.length,
      45,
    );
  });

  test(
    'failed interest import retries batch without duplicating duration or early acknowledgement',
    () async {
      var failInterests = true;
      var interestAttempts = 0;
      final acknowledged = <String>[];
      const batch = PlaybackUsageBatch(
        id: 'android:epoch:1',
        days: [
          PlaybackUsageDay(
            date: '2026-10-23',
            totalMs: 60000,
            works: [
              PlaybackUsageWork(
                key: 'work',
                milliseconds: 60000,
                lastPlayedAtMs: 1000,
                path: '/work/1.mp3',
              ),
            ],
          ),
        ],
      );
      final service = ListeningActivityService(
        repository: repository,
        readUsage: () async => acknowledged.isEmpty ? [batch] : [],
        acknowledgeUsage: (ids) async => acknowledged.addAll(ids),
        resolveTrack: (_) => _track(),
        recordInterests: ({required batchId, required contributions}) async {
          interestAttempts++;
          expect(contributions.single.duration, const Duration(minutes: 1));
          if (failInterests) throw StateError('preference write failed');
        },
      );
      addTearDown(service.dispose);
      await expectLater(service.refresh(), throwsStateError);
      expect(acknowledged, isEmpty);
      failInterests = false;
      await service.refresh();
      expect(interestAttempts, 2);
      expect(acknowledged, [batch.id]);
      expect(
        (await repository.loadDays()).single.duration,
        const Duration(minutes: 1),
      );
    },
  );

  test(
    'acknowledgement failure retries metadata and imports without double counting',
    () async {
      var failAck = true;
      const batch = PlaybackUsageBatch(
        id: 'windows:epoch:1',
        days: [
          PlaybackUsageDay(
            date: '2026-10-23',
            totalMs: 5000,
            works: [
              PlaybackUsageWork(
                key: 'work',
                milliseconds: 5000,
                lastPlayedAtMs: 1000,
                path: '/work/1.mp3',
              ),
            ],
          ),
        ],
      );
      final service = ListeningActivityService(
        repository: repository,
        readUsage: () async => [batch],
        acknowledgeUsage: (_) async {
          if (failAck) throw StateError('ack failed');
        },
        resolveTrack: (_) => _track(),
        recordInterests: ({required batchId, required contributions}) async {},
      );
      addTearDown(service.dispose);
      await expectLater(service.refresh(), throwsStateError);
      failAck = false;
      await service.refresh();
      expect(
        (await repository.loadDays()).single.duration.inMilliseconds,
        5000,
      );
    },
  );
}

MusicTrack _track() => MusicTrack(
  path: '/work/1.mp3',
  displayName: 'Track',
  groupKey: '/work',
  groupTitle: 'Work',
  groupSubtitle: '',
  isSingle: false,
  tags: ['ASMR'],
);

ListeningDayContribution _day(int milliseconds) => ListeningDayContribution(
  date: '2026-10-23',
  totalMs: milliseconds,
  works: [
    ListeningWorkContribution(
      workKey: 'work',
      track: _track(),
      milliseconds: milliseconds,
      lastPlayedAtMs: 1000,
    ),
  ],
);
