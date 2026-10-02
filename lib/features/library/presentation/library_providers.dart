import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/ui/interaction_deferred_stream.dart';
import '../application/library_facade.dart';
import '../application/library_state_models.dart';
import '../application/work_text_service.dart';
import '../domain/local_directory_cache_repository.dart';

final libraryFacadeProvider = Provider<LibraryFacade>((ref) {
  throw UnimplementedError(
    'libraryFacadeProvider must be overridden in ProviderScope.',
  );
});

final libraryStateProvider = StreamProvider<LibraryState>((ref) {
  return interactionDeferredValueStream(
    ref.watch(libraryFacadeProvider).states,
  );
});

final workTextServiceProvider = Provider<WorkTextService>((ref) {
  final library = ref.watch(libraryFacadeProvider);
  final service = WorkTextService(
    directoryCache: library.databaseRepository is LocalDirectoryCacheRepository
        ? library.databaseRepository as LocalDirectoryCacheRepository
        : null,
    discoverImages: (folder) =>
        library.discoverCoverImageReferencesInFolder(folder, refresh: true),
    directoryRevision: () => (library.structureRevision, library.scanRevision),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
