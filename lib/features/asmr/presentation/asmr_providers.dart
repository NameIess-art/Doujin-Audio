import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_design_tokens.dart';
import '../../../core/ui/interaction_deferred_stream.dart';
import '../application/asmr_download_manager.dart';
import '../application/asmr_library_controller.dart';
import '../application/asmr_playback_coordinator.dart';
import '../domain/asmr_models.dart';

final asmrDownloadManagerProvider = Provider<AsmrDownloadManager?>((ref) {
  return null;
});

final asmrLibraryControllerProvider = Provider<AsmrLibraryController?>((ref) {
  return null;
});

final asmrLibraryGlobalStateProvider =
    StreamProvider<AsmrLibraryGlobalViewState?>((ref) {
      final controller = ref.watch(asmrLibraryControllerProvider);
      if (controller == null) return Stream.value(null);
      return interactionDeferredListenableStream(
        source: controller,
        read: () => controller.globalViewState,
      );
    });

typedef AsmrCategoryStateRequest = ({
  AsmrCategoryType category,
  String searchQuery,
});

final asmrCategoryStateProvider = StreamProvider.autoDispose
    .family<AsmrCategoryViewState?, AsmrCategoryStateRequest>((ref, request) {
      final controller = ref.watch(asmrLibraryControllerProvider);
      if (controller == null) return Stream.value(null);
      return interactionDeferredListenableStream(
        source: controller,
        read: () => controller.categoryViewState(
          request.category,
          searchQuery: request.searchQuery,
        ),
      );
    });

final asmrAuthStateProvider = StreamProvider<AsmrAuthViewState?>((ref) {
  final controller = ref.watch(asmrLibraryControllerProvider);
  if (controller == null) return Stream.value(null);
  return interactionDeferredListenableStream(
    source: controller,
    read: () => controller.authViewState,
  );
});

final asmrTrackTreeStateProvider = StreamProvider.autoDispose
    .family<AsmrTrackTreeViewState?, int>((ref, workId) {
      final controller = ref.watch(asmrLibraryControllerProvider);
      if (controller == null) return Stream.value(null);
      return interactionDeferredListenableStream(
        source: controller,
        read: () => controller.trackTreeViewState(workId),
      );
    });

final asmrSyncStateProvider = StreamProvider<AsmrSyncViewState?>((ref) {
  final controller = ref.watch(asmrLibraryControllerProvider);
  if (controller == null) return Stream.value(null);
  return interactionDeferredListenableStream(
    source: controller,
    read: () => controller.syncViewState,
  );
});

final asmrPlaybackCoordinatorProvider = Provider<AsmrPlaybackCoordinator?>(
  (ref) => null,
);

final asmrDownloadTaskIdsProvider = StreamProvider<List<int>>((ref) {
  final manager = ref.watch(asmrDownloadManagerProvider);
  return manager?.taskIdsStream ?? Stream.value(const <int>[]);
});

final asmrDownloadButtonViewStateProvider =
    StreamProvider<AsmrDownloadButtonViewState>((ref) {
      final manager = ref.watch(asmrDownloadManagerProvider);
      return manager?.buttonViewStateStream ??
          Stream.value(
            const AsmrDownloadButtonViewState(visible: false, progress: null),
          );
    });

final _asmrDownloadTaskSnapshotProvider = StreamProvider.autoDispose
    .family<AsmrDownloadTaskSnapshot?, int>((ref, workId) {
      final manager = ref.watch(asmrDownloadManagerProvider);
      return manager?.taskStream(workId) ?? Stream.value(null);
    });

final asmrDownloadTaskProvider = Provider.autoDispose
    .family<AsmrDownloadTaskSnapshot?, int>((ref, workId) {
      final manager = ref.watch(asmrDownloadManagerProvider);
      return ref.watch(_asmrDownloadTaskSnapshotProvider(workId)).value ??
          manager?.getTask(workId);
    });

ThemeData asmrThemeData(BuildContext context) {
  final base = Theme.of(context);
  final tokens = AppDesignTokens.of(context);
  final accent = tokens.asmrAccent;
  final scheme = base.colorScheme.copyWith(
    primary: accent,
    onPrimary: tokens.onAsmrAccent,
    primaryContainer: tokens.asmrContainer,
    onPrimaryContainer: tokens.onAsmrContainer,
    secondary: accent,
    onSecondary: tokens.onAsmrAccent,
    secondaryContainer: tokens.asmrContainer,
    onSecondaryContainer: tokens.onAsmrContainer,
  );
  return base.copyWith(
    colorScheme: scheme,
  );
}
