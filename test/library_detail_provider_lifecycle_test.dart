import 'dart:async';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/test_persistence_repository.dart';

final class _QueuedDetailRepository extends AudioDetailRepository {
  _QueuedDetailRepository()
    : super(databaseRepository: TestPersistenceRepository());

  final started = Completer<void>();
  final release = Completer<void>();
  final batches = <List<AudioDetailTarget>>[];

  @override
  Future<List<AudioDetailLoadResult>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final batch = targets.toList();
    batches.add(batch);
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return [
      for (final target in batch)
        AudioDetailLoadResult(detail: AudioDetail.empty(target)),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'disposed card metadata skips queued I/O and reloads on return',
    () async {
      final repository = _QueuedDetailRepository();
      final graph = createTestRuntimeGraph(audioDetailRepository: repository);
      final container = ProviderContainer(
        overrides: [libraryFacadeProvider.overrideWithValue(graph.library)],
      );
      addTearDown(graph.runtime.dispose);
      addTearDown(container.dispose);
      addTearDown(() {
        if (!repository.release.isCompleted) repository.release.complete();
      });
      final blocker = graph.library.canonicalAudioDetailTarget(
        AudioDetailTarget.libraryRootFolder('/library/blocker'),
      );
      final target = graph.library.canonicalAudioDetailTarget(
        AudioDetailTarget.libraryRootFolder('/library/card'),
      );
      final blocking = graph.library.loadAudioDetail(blocker);
      await repository.started.future;

      final provider = libraryDetailForTargetProvider(target);
      final card = container.listen(provider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      card.close();
      // A standalone container disposes on an event-loop timer, without widget
      // vsync. Wait for its own scheduler before releasing the queued DB batch.
      await container.pump();
      expect(container.exists(provider), isFalse);
      repository.release.complete();
      await blocking;
      await graph.library.detailCacheService.waitForPendingOperations();
      expect(repository.batches, [
        [blocker],
      ]);
      expect(graph.library.resolvedAudioDetail(target), isNull);

      final returningCard = container.listen(provider, (_, _) {});
      addTearDown(returningCard.close);
      expect((await container.read(provider.future)).target, target);
      expect(repository.batches, [
        [blocker],
        [target],
      ]);
    },
  );
}
