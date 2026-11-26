import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import '../../../core/ui/interaction_deferred_stream.dart';
import '../../data_support/application/cross_platform_sync_service.dart';
import '../application/audio_detail_cache_service.dart'
    show AudioLibraryDetailKey;
import '../application/lan_media_server_service.dart';
import '../application/library_facade.dart';
import '../application/library_scan_coordinator.dart';
import '../application/remote_library_controller.dart';
import '../../../core/media/audio_detail.dart';
import '../application/library_state_models.dart';
import '../application/work_text_service.dart';
import '../../player/application/playback_session_launcher.dart';
import '../../player/presentation/playback_providers.dart'
    show playbackFacadeProvider;

final crossPlatformSyncServiceProvider =
    ChangeNotifierProvider<CrossPlatformSyncService>((ref) {
      return CrossPlatformSyncService();
    });

final lanMediaServerServiceProvider =
    ChangeNotifierProvider<LanMediaServerService>((ref) {
      return LanMediaServerService(
        library: ref.watch(libraryFacadeProvider),
        syncService: ref.watch(crossPlatformSyncServiceProvider),
      );
    });

final remoteLibraryControllerProvider =
    ChangeNotifierProvider<RemoteLibraryController>((ref) {
      return RemoteLibraryController(
        syncService: ref.watch(crossPlatformSyncServiceProvider),
        playbackLauncher: PlaybackFacadeSessionLauncher(
          ref.watch(playbackFacadeProvider),
        ),
      );
    });

final libraryFacadeProvider = Provider<LibraryFacade>((ref) {
  throw UnimplementedError(
    'libraryFacadeProvider must be overridden in ProviderScope.',
  );
});

final libraryScanCoordinatorProvider = Provider<LibraryScanCoordinator>((ref) {
  final coordinator = LibraryScanCoordinator();
  ref.onDispose(coordinator.dispose);
  return coordinator;
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
      final targetKey = AudioLibraryDetailKey.forTarget(target);
      final revisions = Stream<int>.multi((events) {
        final subscription = cache.changes
            .where((change) => change.affectsKey(targetKey))
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
    discoverImagesWithRefresh: (folder, {required refresh}) =>
        library.discoverCoverImageReferencesInFolder(folder, refresh: refresh),
    combineWindowsLocalDiscovery: true,
    onCombinedImagesRefreshed: (folder) =>
        library.coverArtworkCacheService.invalidateFolder(folder),
  );
  var lastStructureRevision = library.structureRevision;
  final subscription = library.states.listen((state) {
    if (state.structureRevision != lastStructureRevision) {
      lastStructureRevision = state.structureRevision;
      unawaited(service.clearDirectoryCache());
    }
  });
  ref.onDispose(() {
    unawaited(subscription.cancel());
    unawaited(service.dispose());
  });
  return service;
});
