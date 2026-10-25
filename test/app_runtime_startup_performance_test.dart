import 'dart:async';

import 'package:doujin_audio/core/logging/app_log_service.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/player/application/listening_activity_service.dart';
import 'package:doujin_audio/features/player/domain/listening_activity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/test_persistence_repository.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  test(
    'controlled startup comparison excludes statistics from core readiness',
    () async {
      const delay = Duration(milliseconds: 200);
      final tracks = AppLogService.measureSync(
        'controlled_startup_dataset',
        () => List.generate(
          1000,
          (i) => MusicTrack(
            path: 'E:/benchmark/work-${i ~/ 10}/track-$i.mp3',
            displayName: 'Track $i',
            groupKey: 'work-${i ~/ 10}',
            groupTitle: 'Work ${i ~/ 10}',
            groupSubtitle: '',
            isSingle: false,
          ),
        ),
        details: {'tracks': 1000},
      );
      final timings = <String, int>{};
      for (final legacyOrder in [true, false]) {
        final label = legacyOrder
            ? 'legacy_dependency_order'
            : 'deferred_statistics';
        final database = await AppRuntimeTestFixture.installSharedDatabase();
        final repository = TestPersistenceRepository();
        final statisticsStarted = Completer<void>();
        final statisticsGate = Completer<void>();
        var reads = 0;
        final activity = ListeningActivityService(
          repository: _EmptyListeningRepository(),
          readUsage: () async {
            if (++reads == 1) {
              statisticsStarted.complete();
              await Future<void>.delayed(delay);
              await statisticsGate.future;
            }
            return [];
          },
          acknowledgeUsage: (_) async {},
          resolveTrack: (_) => null,
          recordInterests:
              ({required batchId, required contributions}) async {},
        );
        final graph = createTestRuntimeGraph(
          persistenceRepository: repository,
          listeningActivity: activity,
          skipPersistence: false,
        );
        Future<void>? secondary;
        Future<void>? ready;
        try {
          await repository.upsertTracks(tracks);
          var coreReady = false;
          final stopwatch = Stopwatch()..start();
          // Current code in both runs; only the former dependency order is simulated.
          ready = AppLogService.measureAsync(
            'controlled_startup_$label',
            () async {
              await graph.runtime.start();
              if (legacyOrder) await activity.start();
              stopwatch.stop();
              timings[label] = stopwatch.elapsedMicroseconds;
              coreReady = true;
            },
            details: {
              'tracks': tracks.length,
              'statisticsDelayMs': delay.inMilliseconds,
            },
          );
          if (legacyOrder) {
            await Future.any([statisticsStarted.future, ready]);
            expect(coreReady, isFalse);
          } else {
            await ready;
            expect(reads, 0);
            secondary = graph.runtime.initializeSecondaryData();
            await statisticsStarted.future;
            expect(coreReady, isTrue);
          }
          expect(graph.persistence.hasLoadedState, isTrue);
          expect(graph.library.library.length, tracks.length);
          expect(statisticsGate.isCompleted, isFalse);
          statisticsGate.complete();
          await ready;
          await secondary;
        } finally {
          if (!statisticsGate.isCompleted) statisticsGate.complete();
          try {
            await ready;
            await secondary;
          } finally {
            try {
              await graph.runtime.dispose();
            } finally {
              await AppRuntimeTestFixture.disposeSharedDatabase(database);
            }
          }
        }
      }
      debugPrint(
        'Controlled dependency-order comparison: tracks=${tracks.length} '
        'firstStatisticsReadMs=${delay.inMilliseconds} coreReadyUs=$timings. '
        'Current code in both runs; no historical binary or device measurement.',
      );
    },
  );
}

class _EmptyListeningRepository extends Fake
    implements ListeningActivityRepository {
  @override
  Future<List<ListeningDay>> loadDays() async => [];

  @override
  Future<List<ListeningHistoryEntry>> loadHistory({
    int offset = 0,
    int limit = 40,
  }) async => [];
}
