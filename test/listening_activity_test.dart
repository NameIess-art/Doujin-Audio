import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/player/application/listening_activity_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_tag_interest.dart';
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
    'concurrent importer starts share hydration and disposal drains it',
    () async {
      final pending = Completer<void>();
      final started = Completer<void>();
      var reads = 0;
      final service = ListeningActivityService(
        repository: repository,
        readUsage: () async {
          reads++;
          started.complete();
          await pending.future;
          return [];
        },
        acknowledgeUsage: (_) async {},
        resolveTrack: (_) => null,
        recordInterests: ({required batchId, required contributions}) async {},
      );
      final first = service.start();
      expect(service.start(), same(first));
      await started.future;
      final shutdown = service.dispose();
      expect(service.dispose(), same(shutdown));
      await service.refresh();
      pending.complete();
      await first;
      await shutdown;
      expect(reads, 1);
      await service.start();
      expect(reads, 1);
    },
  );

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
          'vas': [
            {'id': 'voice-one', 'name': 'Voice One'},
            {'id': 'voice-two', 'name': 'Voice Two'},
          ],
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
        recordVoiceActorInterests:
            ({required batchId, required contributions}) async {
              expect(contributions.single.tags, ['Voice One', 'Voice Two']);
              expect(contributions.single.duration, const Duration(minutes: 1));
            },
        recordCircleInterests:
            ({required batchId, required contributions}) async {
              expect(contributions.single.tags, ['Circle']);
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
    'all interest rankings use full playback time and ignore unplayed manual choices',
    () async {
      final tags = AsmrTagPreferences();
      final voices = AsmrTagPreferences();
      final circles = AsmrTagPreferences();
      for (final state in [tags, voices, circles]) {
        state.setInterested(state.resolve('Never played'), true);
      }
      final tracks = [
        for (final long in [true, false])
          MusicTrack(
            path: 'https://example.com/${long ? 'long' : 'short'}.mp3',
            displayName: long ? 'Long work' : 'Short work',
            groupKey: long ? 'long' : 'short',
            groupTitle: long ? 'Long work' : 'Short work',
            groupSubtitle: '',
            isSingle: false,
            remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne,
            tags: [
              if (long) 'Long tag' else 'Short tag',
              if (long) 'Shared tag',
            ],
            remoteMetadata: {
              'voiceActors': [
                if (long) 'Long voice' else 'Short voice',
                if (long) 'Shared voice',
              ],
              'circleName': long ? 'Long circle' : 'Short circle',
            },
          ),
      ];
      final batch = PlaybackUsageBatch(
        id: 'ranking:1',
        days: [
          PlaybackUsageDay(
            date: '2026-10-25',
            totalMs: const Duration(minutes: 20).inMilliseconds,
            works: [
              for (var i = 0; i < tracks.length; i++)
                PlaybackUsageWork(
                  key: 'ranking:$i',
                  path: tracks[i].path,
                  milliseconds: Duration(
                    minutes: i == 0 ? 12 : 8,
                  ).inMilliseconds,
                  lastPlayedAtMs: 1000 + i,
                ),
            ],
          ),
        ],
      );
      final service = ListeningActivityService(
        repository: repository,
        readUsage: () async => [batch],
        acknowledgeUsage: (_) async {},
        resolveTrack: (path) =>
            tracks.firstWhere((track) => track.path == path),
        recordInterests: ({required batchId, required contributions}) async {
          tags.recordListeningBatch(batchId, contributions);
        },
        recordVoiceActorInterests:
            ({required batchId, required contributions}) async {
              voices.recordListeningBatch(batchId, contributions);
            },
        recordCircleInterests:
            ({required batchId, required contributions}) async {
              circles.recordListeningBatch(batchId, contributions);
            },
      );
      addTearDown(service.dispose);
      await service.refresh();
      await service.refresh();
      for (final state in [tags, voices, circles]) {
        final ranking = state.interests;
        expect(ranking.first.tag.name, startsWith('Long'));
        expect(ranking.first.weight, 12);
        expect(ranking.last.tag.name, startsWith('Short'));
        expect(ranking.last.weight, 8);
        expect(
          ranking.any((entry) => entry.tag.name == 'Never played'),
          isFalse,
        );
        expect(
          AsmrTagPreferences.fromJson(
            state.toJson(),
          ).interests.map((e) => e.weight),
          ranking.map((e) => e.weight),
        );
      }
      expect(tags.learned['local:shared tag'], 12);
      expect(voices.learned['local:shared voice'], 12);
      expect(
        (await repository.loadDays()).single.duration,
        const Duration(minutes: 20),
      );
    },
  );

  test(
    'voice interests import tagless local metadata before acknowledgement and retry independently',
    () async {
      final voicePreferences = AsmrTagPreferences(limit: 10);
      final tags = AsmrTagPreferences();
      var failVoices = true;
      var hasUsage = true;
      final acknowledged = <String>[];
      final batch = _batch('voices:1', 60000);
      final local = _track().copyWith(
        tags: const [],
        remoteMetadata: {
          'voiceActors': ['Voice One'],
          'vas': [
            {'name': 'Voice One'},
          ],
        },
      );
      final service = ListeningActivityService(
        repository: repository,
        readUsage: () async => hasUsage ? [batch] : [],
        acknowledgeUsage: (ids) async {
          acknowledged.addAll(ids);
          hasUsage = false;
        },
        resolveTrack: (_) => local,
        resolveLocalAudioDetail: (track) async {
          expect(track.path, local.path);
          return AudioDetail.empty(
            AudioDetailTarget.libraryRootFolder('/work'),
          ).copyWith(voiceActors: ['Voice One', 'Voice Two']);
        },
        recordInterests: ({required batchId, required contributions}) async {
          tags.recordListeningBatch(batchId, contributions);
        },
        recordVoiceActorInterests:
            ({required batchId, required contributions}) async {
              if (failVoices) throw StateError('voice preference save failed');
              voicePreferences.recordListeningBatch(batchId, contributions);
            },
        recordCircleInterests:
            ({required batchId, required contributions}) async {
              expect(contributions, isEmpty);
            },
      );
      addTearDown(service.dispose);
      await expectLater(service.refresh(), throwsStateError);
      expect(acknowledged, isEmpty);
      expect(voicePreferences.learned, isEmpty);
      failVoices = false;
      await service.refresh();
      expect(acknowledged, [batch.id]);
      expect(voicePreferences.interests.map((e) => e.tag.name), [
        'Voice One',
        'Voice Two',
      ]);
      expect(voicePreferences.learned.values, everyElement(1));
      expect(
        (await repository.loadDays()).single.duration,
        const Duration(minutes: 1),
      );
      expect(tags.interests, isEmpty);
    },
  );

  test('circle interests use explicit remote metadata only', () async {
    for (final metadata in <Map<String, Object?>>[
      {'circleName': ' Remote Circle '},
      {'circle': ' Remote Circle '},
      {
        'circle': {'name': ' Remote Circle '},
      },
      {'name': 'Album name'},
    ]) {
      final batch = _batch('circles:${metadata.keys.single}:1', 60000);
      final remote = _track().copyWith(
        remoteMetadataKind: MusicTrack.remoteMetadataKindJapaneseAsmr,
        remoteMetadata: metadata,
      );
      final service = ListeningActivityService(
        repository: repository,
        readUsage: () async => [batch],
        acknowledgeUsage: (_) async {},
        resolveTrack: (_) => remote,
        resolveLocalAudioDetail: (_) async =>
            throw StateError('remote tracks must not load local metadata'),
        recordInterests: ({required batchId, required contributions}) async {},
        recordCircleInterests:
            ({required batchId, required contributions}) async {
              if (metadata.containsKey('name')) {
                expect(contributions, isEmpty);
              } else {
                expect(contributions.single.tags, ['Remote Circle']);
                expect(
                  contributions.single.duration,
                  const Duration(minutes: 1),
                );
              }
            },
      );
      await service.refresh();
      await service.dispose();
    }
  });

  test('local voice and circle interests share one detail read', () async {
    var detailReads = 0;
    final voicePreferences = AsmrTagPreferences();
    final circlePreferences = AsmrTagPreferences();
    final batches = [_batch('local:1', 30000), _batch('local:2', 30000)];
    final service = ListeningActivityService(
      repository: repository,
      readUsage: () async => batches,
      acknowledgeUsage: (_) async {},
      resolveTrack: (_) => _track(),
      resolveLocalAudioDetail: (_) async {
        detailReads++;
        return AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder('/work'),
        ).copyWith(voiceActors: ['Local Voice'], circleName: ' Local Circle ');
      },
      recordInterests: ({required batchId, required contributions}) async {},
      recordVoiceActorInterests:
          ({required batchId, required contributions}) async {
            voicePreferences.recordListeningBatch(batchId, contributions);
          },
      recordCircleInterests:
          ({required batchId, required contributions}) async {
            circlePreferences.recordListeningBatch(batchId, contributions);
          },
    );
    addTearDown(service.dispose);
    await service.refresh();
    expect(detailReads, 1);
    expect(voicePreferences.interests.single.tag.name, 'Local Voice');
    expect(circlePreferences.interests.single.tag.name, 'Local Circle');
    expect(voicePreferences.learned.values, [1.0]);
    expect(circlePreferences.learned.values, [1.0]);
  });

  test(
    'circle write failure retries without early ack or duplicate learning',
    () async {
      var failCircles = true;
      final voicePreferences = AsmrTagPreferences();
      final circlePreferences = AsmrTagPreferences();
      final acknowledged = <String>[];
      final batch = _batch('circles:retry:1', 60000);
      final service = ListeningActivityService(
        repository: repository,
        readUsage: () async => acknowledged.isEmpty ? [batch] : [],
        acknowledgeUsage: (ids) async => acknowledged.addAll(ids),
        resolveTrack: (_) => _track(),
        resolveLocalAudioDetail: (_) async => AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder('/work'),
        ).copyWith(voiceActors: ['Local Voice'], circleName: 'Local Circle'),
        recordInterests: ({required batchId, required contributions}) async {},
        recordVoiceActorInterests:
            ({required batchId, required contributions}) async {
              voicePreferences.recordListeningBatch(batchId, contributions);
            },
        recordCircleInterests:
            ({required batchId, required contributions}) async {
              circlePreferences.recordListeningBatch(batchId, contributions);
              if (failCircles) {
                throw StateError('circle preference save failed');
              }
            },
      );
      addTearDown(service.dispose);
      await expectLater(service.refresh(), throwsStateError);
      expect(acknowledged, isEmpty);
      failCircles = false;
      await service.refresh();
      expect(acknowledged, [batch.id]);
      expect(voicePreferences.learned.values, [1.0]);
      expect(circlePreferences.learned.values, [1.0]);
      expect(
        (await repository.loadDays()).single.duration,
        const Duration(minutes: 1),
      );
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
    'unchanged polling retains its snapshot and explicit refresh observes deletions',
    () async {
      final counted = _CountingRepository(repository);
      var pending = <PlaybackUsageBatch>[];
      final service = ListeningActivityService(
        repository: counted,
        readUsage: () async => pending,
        acknowledgeUsage: (_) async {
          pending = [];
        },
        resolveTrack: (_) => _track(),
        recordInterests: ({required batchId, required contributions}) async {},
      );
      addTearDown(service.dispose);
      final snapshots = <ListeningActivityView>[];
      final subscription = service.states.listen(snapshots.add);
      addTearDown(subscription.cancel);
      await service.refresh(forceReload: false);
      final initial = await service.states.first;
      await service.refresh(forceReload: false);
      await service.refresh(forceReload: false);
      await Future<void>.delayed(Duration.zero);
      expect(counted.dayReads, 1);
      expect(counted.historyReads, 1);
      expect(snapshots, hasLength(1));
      expect(snapshots.single, same(initial));

      pending = [_batch('new', 5000)];
      await service.refresh(forceReload: false);
      expect(
        (await service.states.first).days.single.duration.inMilliseconds,
        5000,
      );
      expect(counted.dayReads, 2);
      expect(counted.historyReads, 2);
      // A repeated durable batch still needs acknowledgement but not a reload.
      pending = [_batch('new', 5000)];
      await service.refresh(forceReload: false);
      expect(pending, isEmpty);
      expect(counted.dayReads, 2);
      await db.delete('listening_days');
      await db.delete('listening_history');
      await service.refresh();
      expect((await service.states.first).days, isEmpty);
      expect((await service.states.first).history, isEmpty);
      expect(counted.dayReads, 3);
    },
  );

  test(
    'idle polling refreshes the chart date window once after local midnight',
    () async {
      final counted = _CountingRepository(repository);
      var now = DateTime(2026, 10, 23, 23, 59);
      final service = ListeningActivityService(
        repository: counted,
        readUsage: () async => [],
        acknowledgeUsage: (_) async {},
        resolveTrack: (_) => null,
        recordInterests: ({required batchId, required contributions}) async {},
        now: () => now,
      );
      addTearDown(service.dispose);
      await service.refresh(forceReload: false);
      final previous = await service.states.first;
      now = DateTime(2026, 10, 24);
      await service.refresh(forceReload: false);
      final current = await service.states.first;
      expect(current, isNot(same(previous)));
      expect(counted.dayReads, 2);
      await service.refresh(forceReload: false);
      expect(await service.states.first, same(current));
      expect(counted.dayReads, 2);
    },
  );

  test(
    'failed reload retries after the imported batch has been acknowledged',
    () async {
      final counted = _CountingRepository(repository);
      var pending = <PlaybackUsageBatch>[];
      final service = ListeningActivityService(
        repository: counted,
        readUsage: () async => pending,
        acknowledgeUsage: (_) async {
          pending = [];
        },
        resolveTrack: (_) => _track(),
        recordInterests: ({required batchId, required contributions}) async {},
      );
      addTearDown(service.dispose);
      final subscription = service.states.listen(
        (_) {},
        onError: (Object _) {},
      );
      addTearDown(subscription.cancel);
      await service.refresh(forceReload: false);
      pending = [_batch('reload-retry', 5000)];
      counted.failHistoryRead = true;
      await expectLater(service.refresh(forceReload: false), throwsStateError);
      expect(pending, isEmpty);
      counted.failHistoryRead = false;
      await service.refresh(forceReload: false);
      expect(
        (await service.states.first).days.single.duration.inMilliseconds,
        5000,
      );
      expect(counted.historyReads, 3);
      await service.refresh(forceReload: false);
      expect(counted.historyReads, 3);
    },
  );

  test(
    'seed and paging reload even after an unchanged polling snapshot',
    () async {
      final counted = _CountingRepository(repository);
      final service = ListeningActivityService(
        repository: counted,
        readUsage: () async => [],
        acknowledgeUsage: (_) async {},
        resolveTrack: (_) => null,
        recordInterests: ({required batchId, required contributions}) async {},
      );
      addTearDown(service.dispose);
      await service.refresh(forceReload: false);
      await service.seedHistory([
        for (var i = 0; i < 41; i++)
          ListeningHistoryEntry(workKey: 'seed:$i', track: _track()),
      ]);
      final first = await service.states.first;
      expect(first.history, hasLength(40));
      expect(first.hasMoreHistory, isTrue);
      await service.loadMoreHistory();
      final expanded = await service.states.first;
      expect(expanded.history, hasLength(41));
      expect(expanded.hasMoreHistory, isFalse);
      await service.refresh(forceReload: false);
      expect(await service.states.first, same(expanded));
      expect(counted.historyReads, 3);
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
      // v15 changed ASMR identity columns. Restore the actual v13 layout,
      // rather than only relabelling a current schema as an older backup.
      for (final table in [
        'asmr_works',
        'asmr_work_lists',
        'asmr_work_tags',
        'asmr_work_voice_actors',
      ]) {
        var sql =
            (await old.rawQuery(
                  'SELECT sql FROM sqlite_master WHERE name = ?',
                  [table],
                )).single['sql']!
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
        await old.execute('DROP TABLE $table');
        await old.execute(sql);
      }
      await old.insert('asmr_works', {
        'id': 7,
        'title': 'Retained work',
        'source_id': 'RJ000007',
      });
      await old.insert('asmr_work_lists', {
        'list_type': 'favorites',
        'work_id': 7,
      });
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
          AppDatabase.schemaVersion,
        );
        expect(await migrated.query('listening_history'), isEmpty);
        expect(
          (await migrated.query('asmr_works')).single['title'],
          'Retained work',
        );
        expect(
          (await migrated.query('asmr_work_lists')).single['work_id'],
          'code:RJ000007',
        );
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
      var hasUsage = false;
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
        readUsage: () async => hasUsage && acknowledged.isEmpty ? [batch] : [],
        acknowledgeUsage: (ids) async => acknowledged.addAll(ids),
        resolveTrack: (_) => _track(),
        recordInterests: ({required batchId, required contributions}) async {
          interestAttempts++;
          expect(contributions.single.duration, const Duration(minutes: 1));
          if (failInterests) throw StateError('preference write failed');
        },
      );
      addTearDown(service.dispose);
      await service.refresh(forceReload: false);
      hasUsage = true;
      await expectLater(service.refresh(forceReload: false), throwsStateError);
      expect(acknowledged, isEmpty);
      failInterests = false;
      await service.refresh(forceReload: false);
      expect(interestAttempts, 2);
      expect(acknowledged, [batch.id]);
      expect(
        (await repository.loadDays()).single.duration,
        const Duration(minutes: 1),
      );
      expect(
        (await service.states.first).days.single.duration,
        const Duration(minutes: 1),
      );
    },
  );

  test(
    'acknowledgement failure retries metadata and imports without double counting',
    () async {
      var failAck = true;
      var hasUsage = false;
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
        readUsage: () async => hasUsage ? [batch] : [],
        acknowledgeUsage: (_) async {
          if (failAck) throw StateError('ack failed');
        },
        resolveTrack: (_) => _track(),
        recordInterests: ({required batchId, required contributions}) async {},
      );
      addTearDown(service.dispose);
      await service.refresh(forceReload: false);
      hasUsage = true;
      await expectLater(service.refresh(forceReload: false), throwsStateError);
      failAck = false;
      await service.refresh(forceReload: false);
      expect(
        (await repository.loadDays()).single.duration.inMilliseconds,
        5000,
      );
      expect(
        (await service.states.first).days.single.duration.inMilliseconds,
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

PlaybackUsageBatch _batch(String id, int milliseconds) => PlaybackUsageBatch(
  id: id,
  days: [
    PlaybackUsageDay(
      date: '2026-10-23',
      totalMs: milliseconds,
      works: [
        PlaybackUsageWork(
          key: 'work',
          milliseconds: milliseconds,
          lastPlayedAtMs: 1000,
          path: '/work/1.mp3',
        ),
      ],
    ),
  ],
);

final class _CountingRepository implements ListeningActivityRepository {
  _CountingRepository(this.delegate);
  final ListeningActivityRepository delegate;
  int dayReads = 0;
  int historyReads = 0;
  bool failHistoryRead = false;

  @override
  Future<bool> importBatch(
    String batchId,
    List<ListeningDayContribution> days,
  ) => delegate.importBatch(batchId, days);

  @override
  Future<List<ListeningDay>> loadDays() {
    dayReads++;
    return delegate.loadDays();
  }

  @override
  Future<List<ListeningHistoryEntry>> loadHistory({
    int offset = 0,
    int limit = 40,
  }) async {
    historyReads++;
    if (failHistoryRead) throw StateError('history read failed');
    return delegate.loadHistory(offset: offset, limit: limit);
  }

  @override
  Future<MusicTrack?> findTrack(String workKey) => delegate.findTrack(workKey);

  @override
  Future<void> seedHistory(List<ListeningHistoryEntry> entries) =>
      delegate.seedHistory(entries);
}

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
