import 'package:flutter/material.dart';
import '../../core/widgets/app_feedback.dart';
import '../state/subtitle_settings_provider.dart';
import '../../features/player/application/playback_session.dart';
import '../../features/library/presentation/library_providers.dart';
import '../../features/player/presentation/playback_providers.dart';
import '../../features/settings/presentation/settings_providers.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/media/audio_detail.dart';
import '../../core/media/music_track.dart';
import '../../core/ui/ui_operation_service.dart';
import '../../features/library/application/library_state_models.dart';
import '../../features/library/presentation/library_cover_ui_controller.dart';
import '../../features/library/domain/library_node.dart';
import '../../features/library/application/library_sorting.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/logging/app_log_service.dart';
import '../../features/player/presentation/playlist_sorting.dart';
import '../../features/player/application/audio_state_services.dart';
import '../../features/settings/application/settings_state.dart';
import '../state/app_runtime_providers.dart';
import 'app_interaction_effects_controller.dart';
import 'audio_ui_controllers.dart';
import 'screen_view_models.dart';

final globalSubtitleOverlaySessionProvider =
    Provider.autoDispose<({PlaybackSession session, String trackPath})?>((ref) {
      final playback = ref.watch(playbackFacadeProvider);
      final catalog =
          ref.watch(playbackCatalogProvider).value ?? playback.catalogState;
      final settings = ref.watch(
        subtitleSettingsProvider.select(
          (state) => (state.showSubtitlesMap, state.globalSubtitlesMap),
        ),
      );
      String? selectedId;
      for (final candidate in catalog.sessions) {
        final id = candidate.id;
        if (settings.$1[id] == false || settings.$2[id] != true) continue;
        final state = ref.watch(
          playbackSessionProvider(id).select(
            (session) => (
              active:
                  session != null &&
                  (session.effectivePlaying || session.isLoading),
              trackPath: session?.currentTrackPath,
            ),
          ),
        );
        if (state.trackPath == null) continue;
        selectedId ??= id;
        if (state.active) {
          selectedId = id;
          break;
        }
      }
      final session = selectedId == null
          ? null
          : playback.sessionById(selectedId);
      return session == null
          ? null
          : (session: session, trackPath: session.currentTrackPath);
    });

final mainScreenControllerProvider = Provider<MainScreenController>((ref) {
  final controller = MainScreenController();
  ref.onDispose(controller.dispose);
  return controller;
});

final playlistUiControllerProvider = Provider<PlaylistUiController>((ref) {
  final controller = PlaylistUiController(
    ref.watch(playbackFacadeProvider).sessionActivations,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final libraryCoverUiControllerProvider = Provider<LibraryCoverUiController>((
  ref,
) {
  final controller = LibraryCoverUiController(
    library: ref.watch(libraryFacadeProvider),
  );
  ref.onDispose(() => unawaited(controller.dispose()));
  return controller;
});

final appInteractionEffectsControllerProvider =
    Provider<AppInteractionEffectsController>((ref) {
      final controller = AppInteractionEffectsController(
        library: ref.watch(libraryFacadeProvider),
        libraryCovers: ref.watch(libraryCoverUiControllerProvider),
        notifications: ref.watch(notificationFacadeProvider),
        warmup: ref.watch(audioUiWarmupCoordinatorProvider),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

final libraryHeaderUiProvider = Provider<LibraryHeaderState>((ref) {
  final serviceState = ref.watch(libraryFacadeProvider).state;
  final state = ref.watch(libraryStateProvider).value ?? serviceState;
  final refreshOperation = ref.watch(
    uiOperationForScopeProvider(UiOperationScope.libraryRefresh),
  );
  final libraryState = LibraryState(
    libraryTrackCount: state.libraryTrackCount,
    watchedFolderCount: state.watchedFolderCount,
    watchedLibraryCount: state.watchedLibraryCount,
    isInitialized: state.isInitialized,
  );
  return libraryHeaderStateFromSlice(
    libraryState,
    isRefreshing: refreshOperation.isBusy || state.isScanning,
    operationProgress: refreshOperation.progress,
    operationError: refreshOperation.error,
  );
});

final libraryListUiProvider = Provider<LibraryListState>((ref) {
  final facade = ref.watch(libraryFacadeProvider);
  final serviceState = facade.state;
  final state = ref.watch(libraryStateProvider).value ?? serviceState;
  final refreshOperation = ref.watch(
    uiOperationForScopeProvider(UiOperationScope.libraryRefresh),
  );
  final showForegroundScan = state.isScanning && !state.isBackgroundScanning;
  final libraryState = LibraryState(
    watchedFolderCount: state.watchedFolderCount,
    watchedLibraryCount: state.watchedLibraryCount,
    isScanning: showForegroundScan,
    isBackgroundScanning: state.isBackgroundScanning,
    scanCurrentFolder: showForegroundScan ? state.scanCurrentFolder : '',
    scanFoundCount: showForegroundScan ? state.scanFoundCount : 0,
    scanDuplicateCount: showForegroundScan ? state.scanDuplicateCount : 0,
    scanFailureCount: showForegroundScan ? state.scanFailureCount : 0,
    structureRevision: state.treeSnapshotRevision,
    contentRevision: state.contentRevision,
    isInitialized: state.isInitialized,
  );
  return LibraryListState(
    rawTree: facade.libraryCards,
    watchedFolders: facade.watchedFolders,
    watchedLibraries: facade.watchedLibraries,
    watchedFolderCount: libraryState.watchedFolderCount,
    watchedLibraryCount: libraryState.watchedLibraryCount,
    isScanning: libraryState.isScanning,
    isBackgroundScanning: libraryState.isBackgroundScanning,
    structureRevision: libraryState.structureRevision,
    isInitialized: libraryState.isInitialized,
    isRefreshing: refreshOperation.isBusy || state.isScanning,
    operationProgress: refreshOperation.progress,
    operationError: refreshOperation.error,
  );
});

final librarySortedTreeUiProvider = Provider<List<LibraryNode>>((ref) {
  return ref.watch(librarySortedSnapshotUiProvider).nodes;
});

final librarySortedSnapshotUiProvider =
    NotifierProvider<LibrarySortedSnapshotNotifier, LibrarySortedSnapshotState>(
      LibrarySortedSnapshotNotifier.new,
    );

typedef LibrarySortedSnapshotState = ({List<LibraryNode> nodes, Object? error});

class LibrarySortedSnapshotNotifier
    extends Notifier<LibrarySortedSnapshotState> {
  LibrarySortedSnapshotState _retained = (
    nodes: const <LibraryNode>[],
    error: null,
  );
  int _request = 0;
  String get _commitKey => 'library_sorted_snapshot_${identityHashCode(this)}';

  @override
  LibrarySortedSnapshotState build() {
    final libraryFacade = ref.watch(libraryFacadeProvider);
    final sortedInput = ref.watch(
      libraryListUiProvider.select(
        (state) => (nodes: state.rawTree, revision: state.structureRevision),
      ),
    );
    final criterion = ref.watch(
      settingsStateProvider.select(
        (state) =>
            state.value?.librarySortCriterion ?? LibrarySortCriterion.name,
      ),
    );
    final workNameDisplay = criterion == LibrarySortCriterion.name
        ? ref.watch(
            settingsStateProvider.select(
              (state) =>
                  state.value?.workNameDisplay ?? WorkNameDisplay.workTitle,
            ),
          )
        : WorkNameDisplay.folderName;
    final ascending = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.librarySortAscending ?? true,
      ),
    );
    final groupByLibrary = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.libraryGroupByLibrary ?? false,
      ),
    );
    final pinnedPaths = ref
        .watch(
          settingsStateProvider.select(
            (state) => state.value?.pinnedLibraryPaths ?? const <String>[],
          ),
        )
        .toSet();
    final needsDetails =
        criterion == LibrarySortCriterion.voiceActor ||
        criterion == LibrarySortCriterion.releaseDate ||
        (workNameDisplay == WorkNameDisplay.workTitle &&
            sortedInput.nodes.any(
              (node) => node is FolderNode && node.isModuleNode,
            ));
    if (needsDetails) {
      ref.watch(
        libraryStateProvider.select(
          (state) => switch (criterion) {
            LibrarySortCriterion.voiceActor =>
              libraryFacade.detailCacheService.voiceActorRevision,
            LibrarySortCriterion.releaseDate =>
              libraryFacade.detailCacheService.releaseDateRevision,
            _ => libraryFacade.detailCacheService.workTitleRevision,
          },
        ),
      );
    }
    if (criterion != LibrarySortCriterion.name) {
      ref.watch(
        libraryStateProvider.select((state) => state.value?.contentRevision),
      );
    }

    final request = ++_request;
    ref.onDispose(() {
      _request++;
      UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    });
    ref.onResume(UiInteractionCoordinator.instance.scheduleCommitFrame);
    if (sortedInput.nodes.isEmpty) {
      return _retained = (nodes: const <LibraryNode>[], error: null);
    }
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _commitKey,
      priority: 25,
      structural: true,
      canRun: () => ref.mounted && !ref.isPaused,
      commit: () async {
        if (!ref.mounted || request != _request) return;
        try {
          final categorySnapshot = needsDetails
              ? await libraryFacade.audioLibraryCategorySnapshot()
              : null;
          if (!ref.mounted || request != _request) return;
          final input = LibrarySortRequest(
            nodes: sortedInput.nodes,
            criterion: criterion,
            ascending: ascending,
            groupByLibrary: groupByLibrary,
            roots: [
              ...libraryFacade.watchedLibraries,
              ...libraryFacade.watchedFolders,
            ],
            details: libraryFacade.detailCacheService.resolvedDetails,
            categorySnapshot: categorySnapshot,
            workNameDisplay: workNameDisplay,
            pinnedPaths: pinnedPaths,
          );
          final sorted = await libraryFacade.snapshotCacheService.sortedCards(
            input,
          );
          if (!ref.mounted || request != _request) return;
          UiInteractionCoordinator.instance.scheduleCommit(
            key: _commitKey,
            priority: 25,
            structural: true,
            canRun: () => ref.mounted && !ref.isPaused,
            commit: () {
              if (ref.mounted && request == _request) {
                state = _retained = (nodes: sorted, error: null);
              }
            },
          );
        } catch (error, stackTrace) {
          if (!ref.mounted || request != _request) return;
          AppLogService.error(
            'library_sorting_failed',
            error: error,
            stackTrace: stackTrace,
          );
          UiInteractionCoordinator.instance.scheduleCommit(
            key: _commitKey,
            priority: 25,
            structural: true,
            canRun: () => ref.mounted && !ref.isPaused,
            commit: () {
              if (ref.mounted && request == _request) {
                state = _retained = (nodes: _retained.nodes, error: error);
              }
            },
          );
        }
      },
    );
    return _retained;
  }
}

final libraryScanUiProvider = Provider<LibraryScanUiState>((ref) {
  final serviceState = ref.watch(libraryFacadeProvider).state;
  final state = ref.watch(libraryStateProvider).value ?? serviceState;
  return LibraryScanUiState(
    isScanning: state.isScanning,
    isBackgroundScanning: state.isBackgroundScanning,
    source: state.scanCurrentFolder,
    stage: state.scanStage,
    processed: state.scanProcessed,
    total: state.scanTotal,
    foundCount: state.scanFoundCount,
    duplicateCount: state.scanDuplicateCount,
    failureCount: state.scanFailureCount,
  );
});

final libraryDetailRevisionProvider = Provider<int>((ref) {
  final serviceState = ref.watch(libraryFacadeProvider).state;
  return ref.watch(libraryStateProvider).value?.detailRevision ??
      serviceState.detailRevision;
});

final libraryDetailForTargetProvider = FutureProvider.autoDispose
    .family<AudioDetail, AudioDetailTarget>((ref, target) {
      final facade = ref.read(libraryFacadeProvider);
      final canonicalTarget = facade.canonicalAudioDetailTarget(target);
      ref.watch(
        libraryDetailTargetRevisionProvider(
          canonicalTarget,
        ).select((state) => state.value ?? facade.detailCacheService.revision),
      );
      final snapshot = facade.categorySnapshot;
      final detail =
          facade.resolvedAudioDetail(canonicalTarget) ??
          snapshot?.detailFor(canonicalTarget);
      if (detail != null) return detail;
      return facade
          .loadAudioDetail(canonicalTarget)
          .then((result) => result.detail);
    });

final libraryCoverForTrackProvider = FutureProvider.autoDispose
    .family<String?, ({String trackPath, BuildContext context})>((
      ref,
      request,
    ) async {
      final facade = ref.read(libraryFacadeProvider);
      final track = facade.trackByPath(request.trackPath);
      if (track == null || track.isVideo) return null;
      final cache = facade.coverArtworkCacheService;
      final coverKey = cache.coverSearchKeyForTrack(track) ?? track.path;
      ref.watch(
        coverGenerationProvider.select((_) => cache.revisionForScope(coverKey)),
      );
      final resolved = facade.resolvedCoverPathForTrack(track);
      if (resolved != null && resolved.isNotEmpty) return resolved;
      return ref
          .read(libraryCoverUiControllerProvider)
          .deferredTrackCover(track, context: request.context);
    });

final playlistHeaderUiProvider = Provider<PlaylistHeaderState>((ref) {
  final playback = ref.watch(playbackFacadeProvider);
  final playbackState =
      ref.watch(playbackStateProvider).value ?? playback.aggregateState;
  final timerState =
      ref.watch(timerStateProvider).value ??
      ref.watch(timerFacadeProvider).state;
  return PlaylistHeaderState(
    sessionCount: playbackState.sessionCount,
    playingCount: playbackState.playingSessionCount,
    hasPlayingAudioSession: playbackState.hasPlayingAudioSession,
    timerDuration: timerState.duration,
    timerRemaining: timerState.remaining,
    timerActive: timerState.active,
    autoResumeAt: timerState.autoResumeAt,
  );
});

final playlistStructureUiProvider = Provider<PlaylistStructureState>((ref) {
  final catalog =
      ref.watch(playbackCatalogProvider).value ??
      ref.read(playbackFacadeProvider).catalogState;
  return playlistStructureStateFromPlaybackState(
    PlaybackStateSliceData(
      activeSessions: catalog.sessions,
      coverGeneration: ref.watch(coverGenerationProvider),
      isInitialized: catalog.isInitialized,
    ),
  );
});

final playlistSortedEntriesUiProvider = Provider<List<PlaylistStructureEntry>>((
  ref,
) {
  // Artwork changes refresh cards without invalidating their sort order.
  final structureState = ref.watch(
    playlistStructureUiProvider.select(
      (state) => PlaylistStructureState(
        entries: state.entries,
        coverGeneration: 0,
        isInitialized: state.isInitialized,
      ),
    ),
  );
  final criterion = ref.watch(
    settingsStateProvider.select(
      (state) =>
          state.value?.playlistSortCriterion ?? PlaylistSortCriterion.name,
    ),
  );
  final ascending = ref.watch(
    settingsStateProvider.select(
      (state) => state.value?.playlistSortAscending ?? true,
    ),
  );
  final groupByLibrary = ref.watch(
    settingsStateProvider.select(
      (state) => state.value?.playlistGroupByLibrary ?? false,
    ),
  );
  final pinnedSessionIds = ref
      .watch(
        settingsStateProvider.select(
          (state) => state.value?.pinnedPlaylistSessionIds ?? const <String>[],
        ),
      )
      .toSet();
  if (criterion == PlaylistSortCriterion.voiceActor ||
      criterion == PlaylistSortCriterion.releaseDate) {
    ref.watch(libraryDetailRevisionProvider);
  }
  final needsLibraryTrack =
      groupByLibrary ||
      criterion == PlaylistSortCriterion.voiceActor ||
      criterion == PlaylistSortCriterion.releaseDate ||
      structureState.entries.any(
        (entry) =>
            !entry.session.isTemporary &&
            entry.session.playbackQueue?.name.trim().isNotEmpty != true,
      );
  if (needsLibraryTrack) {
    ref.watch(
      libraryStateProvider.select((state) => state.value?.contentRevision),
    );
  }
  final library = ref.watch(libraryFacadeProvider);
  final paths = ref.watch(audioPathCoordinatorProvider);

  final sortedSessions = sortPlaylistSessions(
    sessions: structureState.entries
        .map((entry) => entry.session)
        .toList(growable: false),
    criterion: criterion,
    ascending: ascending,
    groupByLibrary: groupByLibrary,
    library: library,
    trackForSession: (session) =>
        paths.sessionTrackForPath(session.id, session.currentTrackPath),
    pinnedSessionIds: pinnedSessionIds,
  );
  final entriesBySessionId = <String, PlaylistStructureEntry>{
    for (final entry in structureState.entries) entry.sessionId: entry,
  };
  return sortedSessions
      .map((session) => entriesBySessionId[session.id])
      .whereType<PlaylistStructureEntry>()
      .toList(growable: false);
});

final playlistSessionCardStateProvider = Provider.autoDispose
    .family<PlaylistSessionCardState?, String>((ref, sessionId) {
      final session = ref.watch(playbackSessionProvider(sessionId));
      return session == null
          ? null
          : playlistSessionCardStateFromSession(session);
    });

final _coverGenerationChangesProvider = StreamProvider<int>((ref) {
  return ref
      .watch(libraryFacadeProvider)
      .coverArtworkCacheService
      .generationChanges;
});

final coverGenerationProvider = Provider<int>((ref) {
  return ref.watch(_coverGenerationChangesProvider).value ??
      ref.read(libraryFacadeProvider).coverGeneration;
});

final libraryTrackProvider = Provider.autoDispose.family<MusicTrack?, String>((
  ref,
  trackPath,
) {
  ref.watch(
    libraryStateProvider.select((state) => state.value?.contentRevision ?? 0),
  );
  return ref.read(libraryFacadeProvider).trackByPath(trackPath);
});

final activeTrackPathsProvider = Provider<ActiveTrackPaths>((ref) {
  final catalog =
      ref.watch(playbackCatalogProvider).value ??
      ref.read(playbackFacadeProvider).catalogState;
  return ActiveTrackPaths(
    catalog.sessions
        .map((session) => session.currentTrackPath)
        .where((path) => path.isNotEmpty)
        .toSet(),
  );
});

final isTrackActiveProvider = Provider.autoDispose.family<bool, String>((
  ref,
  trackPath,
) {
  return ref.watch(activeTrackPathsProvider).contains(trackPath);
});

final coreRuntimeReadyProvider = Provider<bool>((ref) {
  final library = ref.watch(libraryFacadeProvider);
  final playback = ref.watch(playbackFacadeProvider);
  final timer = ref.watch(timerFacadeProvider);
  final settings = ref.watch(settingsRepositoryProvider);
  final libraryReady = ref.watch(
    libraryStateProvider.select(
      (state) => state.value?.isInitialized ?? library.state.isInitialized,
    ),
  );
  final playbackReady = ref.watch(
    playbackStateProvider.select(
      (state) =>
          state.value?.isInitialized ?? playback.aggregateState.isInitialized,
    ),
  );
  final timerReady = ref.watch(
    timerStateProvider.select(
      (state) => state.value?.isInitialized ?? timer.state.isInitialized,
    ),
  );
  final settingsReady = ref.watch(
    settingsStateProvider.select(
      (state) =>
          state.value?.isInitialized ?? settings.slice.state.isInitialized,
    ),
  );
  return libraryReady && playbackReady && timerReady && settingsReady;
});

final mainOverlayUiProvider = Provider<MainOverlayUiState>((ref) {
  final playback = ref.watch(playbackFacadeProvider);
  final playbackState =
      ref.watch(playbackStateProvider).value ?? playback.aggregateState;
  final fallbackSettings = ref.watch(settingsRepositoryProvider).slice.state;
  final startupReady = ref.watch(
    settingsStateProvider.select(
      (s) => s.value?.isInitialized ?? fallbackSettings.isInitialized,
    ),
  );
  final catalog =
      ref.watch(playbackCatalogProvider).value ?? playback.catalogState;
  final overlaySessions = PlaybackSessionOverlayList(
    catalog.nowPlayingSessions,
  );
  return MainOverlayUiState(
    overlaySessions: overlaySessions,
    playingSessionCount: playbackState.playingSessionCount,
    hasPlayingAudioSession: playback.hasPlayingAudioSession,
    activeSessionCount: playbackState.sessionCount,
    isInitialized: playbackState.isInitialized,
    startupReady: startupReady,
  );
});

final sessionDetailUiProvider = Provider.autoDispose
    .family<SessionDetailUiState, String>((ref, sessionId) {
      final catalog =
          ref.watch(playbackCatalogProvider).value ??
          ref.read(playbackFacadeProvider).catalogState;
      return SessionDetailUiState(
        sessionOrder: SessionOrderState(
          sessionIds: catalog.sessions
              .map((session) => session.id)
              .toList(growable: false),
        ),
        detail: ref.watch(sessionDetailTransportProvider(sessionId)),
        coverGeneration: ref.watch(coverGenerationProvider),
      );
    });

final sessionDetailTransportProvider = Provider.autoDispose
    .family<SessionDetailViewState?, String>((ref, sessionId) {
      final session = ref.watch(playbackSessionProvider(sessionId));
      return session == null
          ? null
          : sessionDetailViewStateFromSession(session);
    });

Future<void> clearSearchHistoryWithFeedback(
  BuildContext context, {
  required bool online,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final settings = container.read(settingsRepositoryProvider);
  final i18n = container.read(appLanguageProviderInstanceProvider);
  // The undo prompt can outlive the search route that requested it.
  final feedbackContext = Navigator.of(context).context;
  var removed = const <String>[];
  final saved = await saveSettingsWithFeedback(context, () async {
    removed = await settings.clearSearchHistory(online: online);
  });
  if (!saved || removed.isEmpty || !context.mounted) return;
  showAppSnackBar(
    context,
    i18n.tr('search_history_cleared'),
    icon: Icons.delete_outline_rounded,
    isUndoAction: true,
    actionLabel: i18n.tr('undo'),
    onAction: () => unawaited(
      saveSettingsWithFeedback(
        feedbackContext,
        () => settings.restoreSearchHistory(removed, online: online),
      ),
    ),
  );
}

int _settingsSaveSequence = 0;

Future<bool> saveSettingsWithFeedback(
  BuildContext context,
  Future<void> Function() save,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final i18n = container.read(appLanguageProviderInstanceProvider);
  final saved = await container
      .read(uiOperationServiceProvider)
      .runWithFeedback<bool>(
        context: context,
        scope: UiOperationScope('settings:save:${++_settingsSaveSequence}'),
        labelKey: 'loading_dot',
        task: (_) async {
          await save();
          return true;
        },
        failureMessage: i18n.tr('operation_failed_retry'),
        operationFailedTitle: i18n.tr('operation_failed'),
      );
  return saved ?? false;
}
