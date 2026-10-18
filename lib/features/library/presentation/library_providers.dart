import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/ui/interaction_deferred_stream.dart';
import '../application/library_facade.dart';
import '../../../core/media/audio_detail.dart';
import '../application/library_state_models.dart';
import '../application/work_text_service.dart';

final libraryFacadeProvider = Provider<LibraryFacade>((ref) {
  throw UnimplementedError(
    'libraryFacadeProvider must be overridden in ProviderScope.',
  );
});

final libraryStateProvider = StreamProvider<LibraryState>((ref) {
  return interactionDeferredValueStream(
    ref.watch(libraryFacadeProvider).states,
    isStructuralUpdate: (previous, next) =>
        previous.isInitialized != next.isInitialized ||
        previous.structureRevision != next.structureRevision ||
        previous.treeSnapshotRevision != next.treeSnapshotRevision ||
        previous.contentRevision != next.contentRevision ||
        previous.detailRevision != next.detailRevision ||
        previous.categorySnapshotRevision != next.categorySnapshotRevision,
  );
});

final libraryDetailTargetRevisionProvider = StreamProvider.autoDispose
    .family<int, AudioDetailTarget>((ref, target) {
      final cache = ref.watch(libraryFacadeProvider).detailCacheService;
      final revisions = Stream<int>.multi((events) {
        final subscription = cache.changes
            .where((change) => change.affects(target))
            .listen(
              (change) => events.addSync(change.revision),
              onError: events.addErrorSync,
              onDone: events.closeSync,
            );
        events.onCancel = subscription.cancel;
        events.addSync(cache.revision);
      }, isBroadcast: true);
      return interactionDeferredValueStream(revisions, structural: true);
    });

final workTextServiceProvider = Provider<WorkTextService>((ref) {
  final library = ref.watch(libraryFacadeProvider);
  final service = WorkTextService(
    discoverImages: (folder) =>
        library.discoverCoverImageReferencesInFolder(folder, refresh: true),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
