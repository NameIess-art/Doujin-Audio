import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/ui/interaction_deferred_stream.dart';
import '../application/library_facade.dart';
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
  );
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
