import 'dart:convert';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_scan_models.dart';
import 'package:doujin_audio/features/library/application/library_scanner_isolate.dart';
import 'package:doujin_audio/features/library/domain/library_entry.dart';
import 'package:doujin_audio/features/library/presentation/library_view_models.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('LIBRARY_OFFLINE_BENCHMARK');
const _root = 'C:/Music Library';
const _samples = 5;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'catalog startup and derived snapshots at 10k and 50k tracks',
    () async {
      sqfliteFfiInit();
      SharedPreferences.setMockInitialValues({});
      for (final trackCount in [10000, 50000]) {
        final tracks = _makeTracks(trackCount);
        final workPaths = tracks
            .map((track) => track.groupKey)
            .toSet()
            .toList();
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        try {
          await AppDatabase.createSchemaForTest(db);
          final appDatabase = AppDatabase.test(db);
          final repository = SqliteLibraryRepository(database: appDatabase);
          await appDatabase.upsertTracks(tracks);
          await repository.commitLibraryBatch(
            tracks: [],
            entries: [
              for (final track in tracks)
                LibraryEntry.track(
                  libraryPath: _root,
                  track: track,
                  parentPath: track.groupKey,
                  state: LibraryEntryState.active,
                ),
            ],
            catalogSettings: {
              'group_order_v1': jsonEncode(workPaths),
              'watched_folders_v1': '[]',
              'watched_libraries_v1': jsonEncode([_root]),
            },
          );
          final detailTargets = workPaths
              .map(AudioDetailTarget.libraryRootFolder)
              .toList();
          await repository.upsertMany([
            for (final target in detailTargets)
              AudioDetail.empty(
                target,
              ).copyWith(voiceActors: ['Voice 2', 'Voice 1'], tags: ['Z', 'A']),
          ]);

          final startupUs = <int>[];
          final derivedUs = <int>[];
          final detailsUs = <int>[];
          final firstSearchUs = <int>[];
          final repeatSearchUs = <int>[];
          for (var sample = 0; sample <= _samples; sample++) {
            final facade = LibraryFacade.create(databaseRepository: repository);
            try {
              final startup = Stopwatch()..start();
              await facade.loadPersistedState();
              startup.stop();
              expect(facade.library, hasLength(trackCount));
              expect(facade.libraryCards, hasLength(workPaths.length));
              expect(facade.state.isInitialized, isTrue);

              final build = Stopwatch()..start();
              final derived = await facade.snapshotCacheService
                  .buildDerivedSnapshot();
              build.stop();
              expect(derived.libraryByPath, hasLength(trackCount));
              expect(derived.cardSnapshot.tree, hasLength(workPaths.length));

              final detailRead = Stopwatch()..start();
              final details = await repository.loadMany(detailTargets);
              detailRead.stop();
              expect(details, hasLength(detailTargets.length));
              expect(details.last.voiceActors, ['Voice 2', 'Voice 1']);
              final tree = await facade.loadLibraryTree();
              final index = LibrarySearchIndex();
              final firstSearch = Stopwatch()..start();
              final firstResult = index.resolve(
                tree: tree,
                query: 'Track 0',
                structureRevision: 1,
              );
              firstSearch.stop();
              expect(firstResult.matchCount, workPaths.length);
              final repeatedSearch = Stopwatch()..start();
              for (var trackIndex = 1; trackIndex <= 4; trackIndex++) {
                final result = index.resolve(
                  tree: tree,
                  query: 'Track $trackIndex',
                  structureRevision: 1,
                );
                expect(result.matchCount, workPaths.length);
              }
              repeatedSearch.stop();
              if (sample > 0) {
                startupUs.add(startup.elapsedMicroseconds);
                derivedUs.add(build.elapsedMicroseconds);
                detailsUs.add(detailRead.elapsedMicroseconds);
                firstSearchUs.add(firstSearch.elapsedMicroseconds);
                repeatSearchUs.add(repeatedSearch.elapsedMicroseconds);
              }
            } finally {
              await facade.dispose();
            }
          }
          _report('persisted_library_ready', trackCount, startupUs);
          _report('derived_snapshot_worker', trackCount, derivedUs);
          _report('sqlite_audio_details_read', detailTargets.length, detailsUs);
          _report('first_search', trackCount, firstSearchUs);
          _report('four_new_searches', trackCount, repeatSearchUs);
        } finally {
          await db.close();
        }
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'scan merge isolates at 10k and 50k tracks',
    () async {
      const chunkSize = 120;
      for (final trackCount in [10000, 50000]) {
        final tracks = _makeTracks(trackCount);
        final chunks = [
          for (var offset = 0; offset < trackCount; offset += chunkSize)
            ScanMergeIsolatePayload(
              scannedTracks: [
                for (final track in tracks.skip(offset).take(chunkSize))
                  ScannedTrack(
                    path: track.path,
                    displayName: track.displayName,
                    groupKey: track.groupKey,
                    groupTitle: track.groupTitle,
                    groupSubtitle: track.groupSubtitle,
                    isSingle: track.isSingle,
                    isVideo: track.isVideo,
                    scannedAt: track.scannedAt,
                  ),
              ],
              library: [],
              libraryRoot: _root,
              promoteRootTracksToSingles: false,
              i18nImportedFiles: 'Imported',
              i18nManuallySelectedFiles: 'Selected',
              exclusionMatcher: null,
            ),
        ];
        final repeatedSpawnUs = <int>[];
        final reusedWorkerUs = <int>[];
        for (var sample = 0; sample <= _samples; sample++) {
          for (final reuse in sample.isEven ? [false, true] : [true, false]) {
            final worker = reuse ? LibraryScanMergeWorker() : null;
            final timer = Stopwatch()..start();
            var added = 0;
            try {
              for (final chunk in chunks) {
                final result = worker == null
                    ? await compute(processScannedTracksInIsolate, chunk)
                    : await worker.merge(chunk);
                added += result.trackBatch.length;
                expect(
                  result.trackBatch.last.path,
                  chunk.scannedTracks.last.path,
                );
              }
            } finally {
              await worker?.dispose();
              timer.stop();
            }
            expect(added, trackCount);
            if (sample > 0) {
              (reuse ? reusedWorkerUs : repeatedSpawnUs).add(
                timer.elapsedMicroseconds,
              );
            }
          }
        }
        _report('scan_compute_per_chunk', trackCount, repeatedSpawnUs);
        _report('scan_reused_merge_worker', trackCount, reusedWorkerUs);
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

List<MusicTrack> _makeTracks(int trackCount) =>
    List.generate(trackCount, (index) {
      final workName = 'Work ${index ~/ 10}';
      final work = '$_root/$workName';
      return MusicTrack(
        path: '$work/Disc 1/Track ${index % 10}.mp3',
        displayName: 'Track ${index % 10}',
        groupKey: work,
        groupTitle: workName,
        groupSubtitle: work,
        isSingle: false,
        scannedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
    });

void _report(String operation, int count, List<int> samplesUs) {
  final sorted = [...samplesUs]..sort();
  debugPrint(
    'LIBRARY_PERF ${jsonEncode({'operation': operation, 'count': count, 'samplesUs': samplesUs, 'medianUs': sorted[sorted.length ~/ 2], 'p95Us': sorted[(sorted.length * 0.95).ceil() - 1]})}',
  );
}
