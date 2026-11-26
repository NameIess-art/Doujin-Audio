import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/unified_popup_menu.dart';
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
import '../../features/library/application/audio_detail_cache_service.dart';
import '../../features/library/application/audio_detail_repository.dart';
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
  final state = ref.watch(libraryStateProvider).value ?? facade.state;
  final refreshOperation = ref.watch(
    uiOperationForScopeProvider(UiOperationScope.libraryRefresh),
  );
  return LibraryListState(
    rawTree: facade.libraryCards,
    watchedLibraries: facade.watchedLibraries,
    watchedFolderCount: state.watchedFolderCount,
    watchedLibraryCount: state.watchedLibraryCount,
    isScanning: state.isScanning && !state.isBackgroundScanning,
    isBackgroundScanning: state.isBackgroundScanning,
    structureRevision: state.treeSnapshotRevision,
    isInitialized: state.isInitialized,
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
    ref.watch(
      libraryStateProvider.select(
        (state) =>
            state.value?.treeSnapshotRevision ??
            libraryFacade.state.treeSnapshotRevision,
      ),
    );
    final nodes = libraryFacade.libraryCards;
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
        criterion == LibrarySortCriterion.userRating ||
        (workNameDisplay == WorkNameDisplay.workTitle &&
            nodes.any(
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
            LibrarySortCriterion.userRating =>
              libraryFacade.detailCacheService.userRatingRevision,
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
    if (nodes.isEmpty) {
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
          final details = <AudioDetail>[];
          if (needsDetails) {
            final targets = <String, AudioDetailTarget>{};
            final preparation = Stopwatch()..start();
            for (final node in nodes) {
              final AudioDetailTarget target;
              if (node is FolderNode) {
                if (criterion == LibrarySortCriterion.name &&
                    !node.isModuleNode) {
                  continue;
                }
                target = AudioDetailTarget.libraryRootFolder(node.path);
              } else if (node is TrackNode &&
                  criterion != LibrarySortCriterion.name) {
                target = AudioDetailTarget.singleAudioFile(node.track.path);
              } else {
                continue;
              }
              final canonical = libraryFacade.canonicalAudioDetailTarget(
                target,
              );
              targets[AudioLibraryDetailKey.forTarget(canonical)] = canonical;
              if (preparation.elapsedMicroseconds >= 1000) {
                await Future<void>.delayed(Duration.zero);
                if (!ref.mounted || request != _request) return;
                preparation.reset();
              }
            }
            final gate = _LibraryDetailReadGate(ref, requiresListener: true);
            final orderedTargets = targets.values.toList(growable: false);
            // Leave the shared read queue available to visible cards between
            // batches and stop enqueuing reads when the sort is superseded.
            for (var start = 0; start < orderedTargets.length; start += 64) {
              if (gate.waitForCommit() case final pending?) await pending;
              if (!ref.mounted || request != _request) return;
              final end = (start + 64).clamp(0, orderedTargets.length);
              final loaded = await libraryFacade.detailCacheService.loadMany(
                orderedTargets.getRange(start, end),
                isActive: () => ref.mounted && request == _request,
              );
              details.addAll(loaded.map((result) => result.detail));
            }
          }
          if (!ref.mounted || request != _request) return;
          final input = LibrarySortRequest(
            nodes: nodes,
            criterion: criterion,
            ascending: ascending,
            groupByLibrary: groupByLibrary,
            roots: [
              ...libraryFacade.watchedLibraries,
              ...libraryFacade.watchedFolders,
            ],
            details: details,
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
      return _loadColdLibraryDetail(
        ref,
        () => facade.loadAudioDetail(
          canonicalTarget,
          isActive: () => ref.mounted,
        ),
      );
    });

Future<AudioDetail> _loadColdLibraryDetail(
  Ref ref,
  Future<AudioDetailLoadResult> Function() load,
) async {
  // Newly visible cards need their first metadata while the list is moving.
  final gate = _LibraryDetailReadGate(ref, allowDuringScroll: true);
  if (gate.waitForCommit() case final pending?) await pending;
  if (!ref.mounted) throw const AudioDetailOperationCancelled();
  try {
    return (await load()).detail;
  } finally {
    if (ref.mounted) {
      if (gate.waitForCommit(structural: true) case final pending?) {
        await pending;
      }
    }
  }
}

final class _LibraryDetailReadGate {
  _LibraryDetailReadGate(
    this._ref, {
    this.requiresListener = false,
    this.allowDuringScroll = false,
  }) {
    _ref.onDispose(() {
      _coordinator.cancelCommit(_key);
      _pending?.complete();
      _pending = null;
    });
    if (requiresListener) _ref.onResume(_coordinator.scheduleCommitFrame);
  }

  final Ref _ref;
  final bool requiresListener;
  final bool allowDuringScroll;
  final _coordinator = UiInteractionCoordinator.instance;
  late final _key = 'library_detail_commit_${identityHashCode(this)}';
  Completer<void>? _pending;

  bool get _canRun => _ref.mounted && (!requiresListener || !_ref.isPaused);

  Future<void>? waitForCommit({bool structural = false}) {
    if (!_coordinator.isInteracting && _canRun) return null;
    final pending = _pending = Completer<void>();
    _coordinator.scheduleCommit(
      key: _key,
      priority: 30,
      allowDuringScroll: allowDuringScroll,
      structural: structural,
      canRun: () => _canRun,
      commit: () {
        _pending = null;
        pending.complete();
      },
    );
    return pending.future;
  }
}

final libraryCoverForTrackProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, trackPath) {
      final facade = ref.read(libraryFacadeProvider);
      final track = facade.trackByPath(trackPath);
      if (track == null || track.isVideo) return null;
      final cache = facade.coverArtworkCacheService;
      final coverKey = cache.coverSearchKeyForTrack(track) ?? track.path;
      ref.watch(
        coverGenerationProvider.select((_) => cache.revisionForScope(coverKey)),
      );
      final resolved = facade.resolvedCoverPathForTrack(track);
      if (resolved != null && resolved.isNotEmpty) return resolved;
      final controller = ref.read(libraryCoverUiControllerProvider);
      final cancelToken = Object();
      ref.onDispose(() => controller.cancelDeferredLookup(cancelToken));
      return controller.deferredTrackCover(track, cancelToken: cancelToken);
    });

final playlistResumeBatchProvider = StreamProvider<int>(
  (ref) => ref.watch(playbackFacadeProvider).resumeBatchChanges,
);

final playlistTimerRemainingUiProvider = Provider<Duration?>((ref) {
  final fallback = ref.watch(timerFacadeProvider).state.remaining;
  return ref.watch(
    timerStateProvider.select(
      (state) => state.hasValue ? state.value?.remaining : fallback,
    ),
  );
});

final playlistHeaderUiProvider = Provider<PlaylistHeaderState>((ref) {
  final playback = ref.watch(playbackFacadeProvider);
  final playbackState =
      ref.watch(playbackStateProvider).value ?? playback.aggregateState;
  final fallbackTimer = ref.watch(timerFacadeProvider).state;
  final timerMeta = ref.watch(
    timerStateProvider.select((state) {
      final value = state.value ?? fallbackTimer;
      return (
        duration: value.duration,
        active: value.active,
        autoResumeAt: value.autoResumeAt,
      );
    }),
  );
  ref.watch(playlistResumeBatchProvider);
  return PlaylistHeaderState(
    hasActivePlayback: playback.hasActivePlayback,
    canResumeLastPlayback: playback.canResumeLastPlayback,
    sessionCount: playbackState.sessionCount,
    playingCount: playbackState.playingSessionCount,
    hasPlayingAudioSession: playbackState.hasPlayingAudioSession,
    timerDuration: timerMeta.duration,
    timerRemaining: null,
    timerActive: timerMeta.active,
    autoResumeAt: timerMeta.autoResumeAt,
  );
});

final playlistStructureUiProvider = Provider<PlaylistStructureState>((ref) {
  final directory = ref.watch(
    playbackCatalogProvider.select((state) {
      final catalog = state.value;
      return catalog == null ? null : (catalog.sessions, catalog.isInitialized);
    }),
  );
  final fallback = ref.read(playbackFacadeProvider).catalogState;
  return PlaylistStructureState(
    entries: directory?.$1 ?? fallback.sessions,
    isInitialized: directory?.$2 ?? fallback.isInitialized,
  );
});

final playlistSortedEntriesUiProvider =
    NotifierProvider<
      PlaylistSortedEntriesNotifier,
      List<PlaybackDirectoryEntry>
    >(PlaylistSortedEntriesNotifier.new);

// Pinning repartitions this order without resolving sorting metadata again.
final _playlistBaseSortProvider = Provider((ref) {
  final structureState = ref.watch(playlistStructureUiProvider);
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
            !entry.isTemporary && entry.queueName?.trim().isNotEmpty != true,
      );
  if (needsLibraryTrack) {
    ref.watch(
      libraryStateProvider.select((state) => state.value?.contentRevision),
    );
  }
  final paths = ref.watch(audioPathCoordinatorProvider);

  final sortedSessions = sortPlaylistSessions(
    sessions: structureState.entries,
    criterion: criterion,
    ascending: ascending,
    groupByLibrary: groupByLibrary,
    paths: paths,
    trackForSession: (session) =>
        paths.sessionTrackForPath(session.id, session.currentTrackPath),
  );
  return (
    structure: structureState,
    entries: sortedSessions,
    options: (criterion, ascending, groupByLibrary),
  );
});

class PlaylistSortedEntriesNotifier
    extends Notifier<List<PlaybackDirectoryEntry>> {
  Set<String>? _knownSessionIds;
  List<PlaybackDirectoryEntry>? _lastStructureEntries;
  bool _lastStructureInitialized = false;
  final List<String> _newQueueIds = [];
  (PlaylistSortCriterion, bool, bool)? _sortOptions;
  List<String> _pinnedSessionIds = const [];

  void applySort() {
    _newQueueIds.clear();
    ref.invalidate(_playlistBaseSortProvider);
    ref.invalidateSelf();
  }

  @override
  List<PlaybackDirectoryEntry> build() {
    final base = ref.watch(_playlistBaseSortProvider);
    final structureState = base.structure;
    final pinnedSessionIds = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.pinnedPlaylistSessionIds ?? const <String>[],
      ),
    );
    final sortOptions = base.options;
    if (_sortOptions != sortOptions ||
        !listEquals(_pinnedSessionIds, pinnedSessionIds)) {
      _newQueueIds.clear();
    }
    _sortOptions = sortOptions;
    _pinnedSessionIds = pinnedSessionIds;
    final structureChanged =
        !identical(_lastStructureEntries, structureState.entries) ||
        _lastStructureInitialized != structureState.isInitialized;
    _lastStructureEntries = structureState.entries;
    _lastStructureInitialized = structureState.isInitialized;
    if (structureState.isInitialized &&
        (structureChanged || _knownSessionIds == null)) {
      if (_knownSessionIds case final known?) {
        // Keep newly created queues visible until the user applies a sort or pin.
        _newQueueIds.insertAll(0, [
          for (final entry in structureState.entries)
            if (entry.queueName != null &&
                !entry.isTemporary &&
                !known.contains(entry.id))
              entry.id,
        ]);
      }
      _knownSessionIds = {for (final entry in structureState.entries) entry.id};
    }
    if (_newQueueIds.isEmpty && pinnedSessionIds.isEmpty) return base.entries;
    Map<String, PlaybackDirectoryEntry>? entriesBySessionId;
    if (_newQueueIds.isNotEmpty) {
      entriesBySessionId = <String, PlaybackDirectoryEntry>{
        for (final entry in structureState.entries) entry.id: entry,
      };
      _newQueueIds.retainWhere(entriesBySessionId.containsKey);
      if (_newQueueIds.isEmpty && pinnedSessionIds.isEmpty) {
        return base.entries;
      }
    }
    final newQueueIds = _newQueueIds.toSet();
    final pinned = pinnedSessionIds.toSet();
    final temporaryEntries = <PlaybackDirectoryEntry>[];
    final pinnedEntries = <PlaybackDirectoryEntry>[];
    final ordinaryEntries = <PlaybackDirectoryEntry>[];
    for (final entry in base.entries) {
      if (entry.isTemporary) {
        temporaryEntries.add(entry);
      } else if (!newQueueIds.contains(entry.id)) {
        (pinned.contains(entry.id) ? pinnedEntries : ordinaryEntries).add(
          entry,
        );
      }
    }
    return List<PlaybackDirectoryEntry>.unmodifiable([
      ...temporaryEntries,
      for (final id in _newQueueIds) entriesBySessionId![id]!,
      ...pinnedEntries,
      ...ordinaryEntries,
    ]);
  }
}

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
  final sessions =
      ref.watch(
        playbackCatalogProvider.select((state) => state.value?.sessions),
      ) ??
      ref.read(playbackFacadeProvider).catalogState.sessions;
  return ActiveTrackPaths(
    sessions
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
  final sessions =
      ref.watch(
        playbackCatalogProvider.select(
          (state) => state.value?.nowPlayingSessions,
        ),
      ) ??
      playback.catalogState.nowPlayingSessions;
  final overlaySessions = PlaybackSessionOverlayList(sessions);
  return MainOverlayUiState(
    overlaySessions: overlaySessions,
    playingSessionCount: playbackState.playingSessionCount,
    hasPlayingAudioSession: playback.hasPlayingAudioSession,
    activeSessionCount: playbackState.sessionCount,
    isInitialized: playbackState.isInitialized,
    startupReady: startupReady,
  );
});

final _playbackSessionOrderProvider = Provider<SessionOrderState>((ref) {
  final sessions =
      ref.watch(
        playbackCatalogProvider.select((state) => state.value?.sessions),
      ) ??
      ref.read(playbackFacadeProvider).catalogState.sessions;
  return SessionOrderState(
    sessionIds: List<String>.unmodifiable(
      sessions.map((session) => session.id),
    ),
  );
});

final sessionDetailUiProvider = Provider.autoDispose
    .family<SessionDetailUiState, String>((ref, sessionId) {
      return SessionDetailUiState(
        sessionOrder: ref.watch(_playbackSessionOrderProvider),
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

List<UnifiedMenuEntry<VoidCallback>> buildSearchHistoryMenu(
  BuildContext context,
  String query, {
  required bool online,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final i18n = container.read(appLanguageProviderInstanceProvider);

  Future<void> copy() async {
    await Clipboard.setData(ClipboardData(text: query));
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      i18n.tr('copied_to_clipboard', {'value': query}),
      icon: Icons.content_copy_rounded,
    );
  }

  Future<void> remove() async {
    final settings = container.read(settingsRepositoryProvider);
    var removed = false;
    final saved = await saveSettingsWithFeedback(context, () async {
      removed = await settings.removeSearchHistoryEntry(query, online: online);
    });
    if (!saved || !removed || !context.mounted) return;
    showAppSnackBar(
      context,
      i18n.tr('removed_prefix', {'name': query}),
      icon: Icons.delete_outline_rounded,
      tone: AppFeedbackTone.destructive,
    );
  }

  return [
    UnifiedMenuEntry.action(
      value: () => unawaited(copy()),
      label: i18n.tr('search_history_copy_keyword'),
      icon: Icons.content_copy_rounded,
    ),
    UnifiedMenuEntry.action(
      value: () => unawaited(remove()),
      label: i18n.tr('search_history_remove_entry'),
      icon: Icons.delete_outline_rounded,
      destructive: true,
    ),
  ];
}

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
