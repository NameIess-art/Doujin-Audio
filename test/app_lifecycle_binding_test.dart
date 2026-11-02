import 'dart:async';

import 'package:doujin_audio/features/player/application/listening_activity_service.dart';
import 'package:doujin_audio/features/player/domain/listening_activity.dart';
import 'package:doujin_audio/features/player/domain/playback_usage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  test(
    'core readiness excludes secondary hydration and merges requests',
    () async {
      final online = Completer<void>();
      final history = Completer<void>();
      final started = Completer<void>();
      var onlineStarts = 0;
      var historyStarts = 0;
      var disposals = 0;
      final graph = createTestRuntimeGraph(
        initializeSecondaryData: () {
          onlineStarts++;
          started.complete();
          return online.future;
        },
        initializeListeningHistory: () {
          historyStarts++;
          return history.future;
        },
        disposeSecondaryData: () => disposals++,
      );
      addTearDown(graph.runtime.dispose);
      final secondary = graph.runtime.initializeSecondaryData();
      expect(graph.runtime.initializeSecondaryData(), same(secondary));
      await graph.runtime.start();
      await started.future;
      expect(graph.persistence.hasLoadedState, isTrue);
      expect(online.isCompleted, isFalse);
      expect(history.isCompleted, isFalse);
      online.complete();
      history.complete();
      await secondary;
      await graph.runtime.initializeSecondaryData();
      expect(onlineStarts, 1);
      expect(historyStarts, 1);
      await graph.runtime.dispose();
      expect(disposals, 1);
    },
  );

  test('shutdown drains secondary work before releasing its owners', () async {
    final pending = Completer<void>();
    final started = Completer<void>();
    var released = false;
    final graph = createTestRuntimeGraph(
      initializeSecondaryData: () {
        started.complete();
        return pending.future;
      },
      disposeSecondaryData: () => released = true,
    );
    final secondary = graph.runtime.initializeSecondaryData();
    await started.future;
    final shutdown = graph.runtime.dispose();
    expect(graph.runtime.dispose(), same(shutdown));
    await expectLater(graph.runtime.start(), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);
    pending.complete();
    await secondary;
    await shutdown;
    expect(released, isTrue);
    await graph.runtime.initializeSecondaryData();
  });

  test(
    'shutdown before secondary dispatch prevents all secondary work',
    () async {
      var starts = 0;
      final graph = createTestRuntimeGraph(
        initializeSecondaryData: () async => starts++,
        initializeListeningHistory: () async => starts++,
      );
      final secondary = graph.runtime.initializeSecondaryData();
      await graph.runtime.dispose();
      await secondary;
      expect(starts, 0);
    },
  );

  test(
    'secondary failure leaves core ready and successful history reusable',
    () async {
      var attempts = 0;
      var historyStarts = 0;
      final graph = createTestRuntimeGraph(
        initializeSecondaryData: () async {
          if (++attempts == 1) throw StateError('online restore failed');
        },
        initializeListeningHistory: () async => historyStarts++,
      );
      addTearDown(graph.runtime.dispose);
      await expectLater(
        graph.runtime.initializeSecondaryData(),
        throwsStateError,
      );
      expect(graph.persistence.hasLoadedState, isTrue);
      expect(historyStarts, 1);
      await graph.runtime.initializeSecondaryData();
      expect(attempts, 2);
      expect(historyStarts, 1);
    },
  );

  test(
    'foreground restoration completes while statistics import is pending',
    () async {
      final pending = Completer<void>();
      final importing = Completer<void>();
      var reads = 0;
      final activity = ListeningActivityService(
        repository: _EmptyListeningRepository(),
        readUsage: () async {
          if (++reads == 2) {
            importing.complete();
            await pending.future;
          }
          return [];
        },
        acknowledgeUsage: (_) async {},
        resolveTrack: (_) => null,
        recordInterests: ({required batchId, required contributions}) async {},
      );
      final graph = createTestRuntimeGraph(listeningActivity: activity);
      await graph.runtime.initializeSecondaryData();
      final resume = graph.runtime.resumeForeground();
      await importing.future;
      await resume;
      expect(pending.isCompleted, isFalse);
      var closed = false;
      final shutdown = graph.runtime.dispose().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      pending.complete();
      await shutdown;
      final finalReads = reads;
      await activity.refresh();
      await activity.start();
      expect(reads, finalReads);
    },
  );

  test(
    'lifecycle retains unchanged statistics and reloads imported usage or a new day',
    () async {
      final repository = _CountingListeningRepository();
      var pending = <PlaybackUsageBatch>[];
      var now = DateTime(2026, 11, 2, 23, 50);
      final acknowledged = <String>[];
      final activity = ListeningActivityService(
        repository: repository,
        readUsage: () async => pending,
        acknowledgeUsage: (ids) async {
          acknowledged.addAll(ids);
          pending = [];
        },
        resolveTrack: (_) => null,
        recordInterests: ({required batchId, required contributions}) async {},
        now: () => now,
      );
      final graph = createTestRuntimeGraph(listeningActivity: activity);
      addTearDown(graph.runtime.dispose);
      await graph.runtime.initializeSecondaryData();
      final initial = await activity.states.first;
      expect(repository.dayReads, 1);
      expect(repository.historyReads, 1);

      await graph.runtime.enterBackground();
      await graph.runtime.resumeForeground();
      // Lifecycle imports are intentionally asynchronous; serialize behind them.
      await activity.refresh(forceReload: false);
      expect(await activity.states.first, same(initial));
      expect(repository.dayReads, 1);
      expect(repository.historyReads, 1);

      pending = [const PlaybackUsageBatch(id: 'background-usage', days: [])];
      await graph.runtime.resumeForeground();
      await activity.refresh(forceReload: false);
      final imported = await activity.states.first;
      expect(imported, isNot(same(initial)));
      expect(acknowledged, ['background-usage']);
      expect(repository.dayReads, 2);
      expect(repository.historyReads, 2);

      now = DateTime(2026, 11, 3);
      await graph.runtime.resumeForeground();
      await activity.refresh(forceReload: false);
      expect(await activity.states.first, isNot(same(imported)));
      expect(repository.dayReads, 3);
      expect(repository.historyReads, 3);
    },
  );

  test(
    'failed history migration still starts imports and retries on resume',
    () async {
      var migrations = 0;
      var imports = 0;
      final retried = Completer<void>();
      final activity = ListeningActivityService(
        repository: _EmptyListeningRepository(),
        readUsage: () async {
          imports++;
          return [];
        },
        acknowledgeUsage: (_) async {},
        resolveTrack: (_) => null,
        recordInterests: ({required batchId, required contributions}) async {},
      );
      final graph = createTestRuntimeGraph(
        listeningActivity: activity,
        initializeListeningHistory: () async {
          if (++migrations == 1) throw StateError('history unavailable');
          retried.complete();
        },
      );
      addTearDown(graph.runtime.dispose);
      await expectLater(
        graph.runtime.initializeSecondaryData(),
        throwsStateError,
      );
      expect(imports, 1);
      await graph.runtime.resumeForeground();
      await retried.future;
      expect(migrations, 2);
    },
  );
}

class _CountingListeningRepository extends _EmptyListeningRepository {
  int dayReads = 0;
  int historyReads = 0;

  @override
  Future<bool> importBatch(
    String batchId,
    List<ListeningDayContribution> days,
  ) async => true;

  @override
  Future<List<ListeningDay>> loadDays() {
    dayReads++;
    return super.loadDays();
  }

  @override
  Future<List<ListeningHistoryEntry>> loadHistory({
    int offset = 0,
    int limit = 40,
  }) {
    historyReads++;
    return super.loadHistory(offset: offset, limit: limit);
  }
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
