import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../app/application/audio_path_coordinator.dart';
import '../../../app/localization/app_language_provider.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/presentation/main_tab_state_mixin.dart';
import '../../../app/presentation/screen_view_models.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/state/subtitle_settings_provider.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/sort_options_bottom_sheet.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../settings/application/settings_state.dart';
import '../application/playback_facade.dart';
import '../domain/playback_mode.dart';
import 'bedtime_canvas_page.dart';
import 'playlist/playlist_batch_controller.dart';
import 'playlist/playlist_list_view.dart';
import 'playlist/playlist_queue_widgets.dart';
import 'playlist/playlist_shared_helpers.dart';
import 'playlist/playlist_volume_timer_widgets.dart';
import 'playlist/session_detail_page.dart';
import 'playlist_sorting.dart';
import 'playlist_view_models.dart';

export 'playlist/playlist_audio_features.dart';
export 'playlist/playlist_batch_controller.dart';
export 'playlist/playlist_feature_icons.dart';
export 'playlist/playlist_list_view.dart';
export 'playlist/playlist_loop_widgets.dart';
export 'playlist/playlist_media_widgets.dart';
export 'playlist/playlist_progress_widgets.dart';
export 'playlist/playlist_queue_widgets.dart';
export 'playlist/playlist_shared_helpers.dart';
export 'playlist/playlist_speed_controls.dart';
export 'playlist/playlist_time_segments.dart';
export 'playlist/playlist_transport_controls.dart';
export 'playlist/playlist_video_widgets.dart';
export 'playlist/playlist_volume_timer_widgets.dart';
export 'playlist/session_detail_content.dart';
export 'playlist/session_detail_page.dart';

class PlaylistTab extends ConsumerStatefulWidget {
  const PlaylistTab({
    super.key,
    this.tabIndex = 2,
    this.onTimerTap,
    this.onOpenLibrary,
    this.activeTabIndexListenable,
  });

  final int tabIndex;
  final VoidCallback? onTimerTap;
  final VoidCallback? onOpenLibrary;
  final ValueListenable<int>? activeTabIndexListenable;

  @override
  ConsumerState<PlaylistTab> createState() => _PlaylistTabState();
}

class _PlaylistTabState extends ConsumerState<PlaylistTab>
    with AutomaticKeepAliveClientMixin, MainTabStateMixin<PlaylistTab> {
  final ScrollController _scrollController = ScrollController();
  bool _initialPlaceholderDismissed = false;
  bool _initialPlaceholderDismissScheduled = false;
  bool _isSelectionMode = false;
  final Set<String> _selectedSessionIds = <String>{};

  void _scrollToTopOnQueueAdded() {
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.jumpTo(0);
    }
  }

  void _enterSelectionMode(String initialSessionId) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedSessionIds.clear();
      _selectedSessionIds.add(initialSessionId);
    });
  }

  void _exitSelectionMode() {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
    setState(() {
      _isSelectionMode = false;
      _selectedSessionIds.clear();
    });
  }

  void _toggleSessionSelection(String sessionId) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      if (_selectedSessionIds.contains(sessionId)) {
        _selectedSessionIds.remove(sessionId);
        if (_selectedSessionIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedSessionIds.add(sessionId);
      }
    });
  }

  void _reconcileSelection(PlaylistStructureState structureState) {
    if (!_isSelectionMode) return;
    final availableSessionIds = structureState.entries
        .map((entry) => entry.sessionId)
        .toSet();
    if (_selectedSessionIds.every(availableSessionIds.contains)) return;
    setState(() {
      _selectedSessionIds.retainAll(availableSessionIds);
      if (_selectedSessionIds.isEmpty) {
        _isSelectionMode = false;
      }
    });
  }

  Future<void> _handleBatchPlay() => PlaylistBatchActions.playSelected(
        ref: ref,
        selectedSessionIds: _selectedSessionIds,
      );

  Future<void> _handleBatchPause() => PlaylistBatchActions.pauseSelected(
        ref: ref,
        selectedSessionIds: _selectedSessionIds,
      );

  Future<void> _handleBatchPin() async {
    final sessionIds = _selectedSessionIds.toList(growable: false);
    _exitSelectionMode();
    await PlaylistBatchActions.pinSelected(
      ref: ref,
      selectedSessionIds: sessionIds,
    );
  }

  Future<void> _handleBatchRemove() async {
    final toRemove = _selectedSessionIds.toList(growable: false);
    _exitSelectionMode();
    await PlaylistBatchActions.removeSelected(
      context: context,
      ref: ref,
      selectedSessionIds: toRemove,
    );
  }

  Future<void> _handleCreatePlaybackQueue(
    List<PlaylistStructureEntry> visibleEntries,
    PlaybackFacade playback,
    AudioPathCoordinator paths,
  ) async {
    await PlaylistBatchActions.createPlaybackQueue(
      ref: ref,
      visibleEntries: visibleEntries,
      selectedSessionIds: _selectedSessionIds,
      playback: playback,
      paths: paths,
      onQueueAdded: _scrollToTopOnQueueAdded,
    );
    if (mounted) _exitSelectionMode();
  }

  bool _hasSelectedPlaybackQueueSource(
    List<PlaylistStructureEntry> visibleEntries,
    AudioPathCoordinator paths,
  ) =>
      PlaylistBatchActions.hasSelectedPlaybackQueueSource(
        visibleEntries: visibleEntries,
        paths: paths,
        selectedSessionIds: _selectedSessionIds,
      );


  @override
  int get tabIndex => widget.tabIndex;

  @override
  ScrollController get mainScrollController => _scrollController;

  @override
  double get defaultHeaderHeight => AppPageHeaderMetrics.expandedToolbarHeight;

  @override
  bool get wantKeepAlive => true;

  bool get _isActive =>
      widget.activeTabIndexListenable == null ||
      widget.activeTabIndexListenable!.value == tabIndex;

  T _readOrWatch<T>(ProviderListenable<T> provider) {
    return _isActive ? ref.watch(provider) : ref.read(provider);
  }

  void _handleActiveTabChanged() {
    if (mounted) setState(() {});
  }

  void _scheduleInitialPlaceholderDismissal({required bool isInitialized}) {
    if (_initialPlaceholderDismissed ||
        _initialPlaceholderDismissScheduled ||
        !_isActive ||
        !isInitialized) {
      return;
    }
    _initialPlaceholderDismissScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialPlaceholderDismissScheduled = false;
      if (!mounted || _initialPlaceholderDismissed || !_isActive) return;
      setState(() => _initialPlaceholderDismissed = true);
    });
  }

  @override
  void initState() {
    super.initState();
    widget.activeTabIndexListenable?.addListener(_handleActiveTabChanged);
    final controller = ref.read(mainScreenControllerProvider);
    initTabState(controller.scrollToTopTab, controller.stopScrollTab);
  }

  Future<void> _clearAllWithUndo(
    BuildContext context,
    PlaybackFacade playbackFacade,
  ) async {
    await stagePlaybackSessionRemovals(
      context,
      ref,
      playbackFacade.sessions.keys.toList(growable: false),
      icon: Icons.delete_sweep_rounded,
    );
  }

  void _openSessionDetail(BuildContext context, String sessionId) {
    AppInteractionFeedback.trigger(
      AppInteractionFeedbackType.tap,
      context: context,
    );
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: sessionId));
  }

  void _openQueueEditor(BuildContext context, String sessionId) {
    AppInteractionFeedback.trigger(
      AppInteractionFeedbackType.tap,
      context: context,
    );
    showPlaybackQueueEditPanel(context, sessionId);
  }

  Future<void> _openSortOptions() async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final settingsState = ref.read(settingsStateProvider).value;
    final result = await showSortOptionsBottomSheet<PlaylistSortCriterion>(
      context: context,
      options: [
        SortOption(
          value: PlaylistSortCriterion.name,
          label: i18n.tr('sort_name'),
        ),
        SortOption(
          value: PlaylistSortCriterion.voiceActor,
          label: i18n.tr('sort_voice_actor'),
        ),
        SortOption(
          value: PlaylistSortCriterion.releaseDate,
          label: i18n.tr('sort_release_date'),
        ),
        SortOption(
          value: PlaylistSortCriterion.addedAt,
          label: i18n.tr('sort_added_date'),
        ),
        SortOption(
          value: PlaylistSortCriterion.playbackTime,
          label: i18n.tr('sort_playback_time'),
        ),
      ],
      selectedCriterion:
          settingsState?.playlistSortCriterion ?? PlaylistSortCriterion.name,
      ascending: settingsState?.playlistSortAscending ?? true,
      groupByLibrary: settingsState?.playlistGroupByLibrary ?? false,
      title: i18n.tr('sort_by_title'),
      descriptionLabel: i18n.tr('sort_description'),
      ascendingLabel: i18n.tr('sort_ascending'),
      descendingLabel: i18n.tr('sort_descending'),
      groupByLibraryLabel: i18n.tr('sort_group_by_library'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('confirm'),
    );
    if (!mounted || result == null) return;
    final settings = ref.read(settingsRepositoryProvider);
    await settings.setPlaylistSortOptions(
      criterion: result.criterion,
      ascending: result.ascending,
      groupByLibrary: result.groupByLibrary,
    );
  }

  @override
  void dispose() {
    widget.activeTabIndexListenable?.removeListener(_handleActiveTabChanged);
    disposeTabState();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final library = ref.read(libraryFacadeProvider);
    final paths = ref.read(audioPathCoordinatorProvider);
    final playback = ref.read(playbackFacadeProvider);
    ref.listen(playlistStructureUiProvider, (_, next) {
      if (mounted) _reconcileSelection(next);
    });
    final structureState = _isActive
        ? ref.watch(playlistStructureUiProvider)
        : ref.read(playlistStructureUiProvider);
    _readOrWatch(libraryDetailRevisionProvider);
    final playlistSortCriterion = _readOrWatch(
      settingsStateProvider.select(
        (state) =>
            state.value?.playlistSortCriterion ?? PlaylistSortCriterion.name,
      ),
    );
    final playlistSortAscending = _readOrWatch(
      settingsStateProvider.select(
        (state) => state.value?.playlistSortAscending ?? true,
      ),
    );
    final playlistGroupByLibrary = _readOrWatch(
      settingsStateProvider.select(
        (state) => state.value?.playlistGroupByLibrary ?? false,
      ),
    );
    final pinnedPlaylistSessionIds = _readOrWatch(
      settingsStateProvider.select(
        (state) =>
            state.value?.pinnedPlaylistSessionIds.toSet() ??
            const <String>{},
      ),
    );
    final coverImageResolution = _readOrWatch(
      settingsStateProvider.select(
        (state) =>
            state.value?.coverImageResolution ?? CoverImageResolution.balanced,
      ),
    );
    final subtitleSettings = _isActive
        ? ref.watch(subtitleSettingsProvider)
        : ref.read(subtitleSettingsProvider);
    _scheduleInitialPlaceholderDismissal(
      isInitialized: structureState.isInitialized,
    );
    final coverCacheWidth = coverCacheWidthForResolution(coverImageResolution);
    final listBottomInset = MobileOverlayInset.of(context);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final listCacheExtent = playlistListCacheExtent(
      headerHeight: headerHeight,
      viewportWidth: MediaQuery.sizeOf(context).width,
      isLandscape: isLandscape,
    );
    final topPadding = headerHeight + 4.0;
    final bottomPadding = listBottomInset + 16.0;
    final sortedSessions = sortPlaylistSessions(
      sessions: structureState.entries
          .map((entry) => entry.session)
          .toList(growable: false),
      criterion: playlistSortCriterion,
      ascending: playlistSortAscending,
      groupByLibrary: playlistGroupByLibrary,
      library: library,
      trackForSession: (session) =>
          paths.sessionTrackForPath(session.id, session.currentTrackPath),
      pinnedSessionIds: pinnedPlaylistSessionIds,
    );
    final entriesBySessionId = <String, PlaylistStructureEntry>{
      for (final entry in structureState.entries) entry.sessionId: entry,
    };
    final visibleEntries = sortedSessions
        .map((session) => entriesBySessionId[session.id])
        .whereType<PlaylistStructureEntry>()
        .toList(growable: false);

    Widget buildSessionItem(BuildContext context, int index) {
      if (index == visibleEntries.length) {
        return const SizedBox.shrink(key: ValueKey('bottom_spacing'));
      }
      final structure = visibleEntries[index];
      final session = structure.session;
      final isPinned = pinnedPlaylistSessionIds.contains(session.id);
      final track = paths.sessionTrackForPath(session.id, structure.trackPath);
      final coverPath = library.resolvedPlaybackCoverPathForTrack(track);
      final child = RepaintBoundary(
        child: structure.isPlaybackQueue
            ? PlaybackQueueCard(
                session: session,
                library: library,
                playback: playback,
                coverCacheWidth: coverCacheWidth,
                isSelectionMode: _isSelectionMode,
                isSelected: _selectedSessionIds.contains(session.id),
                isPinned: isPinned,
                onLongPress: () => _enterSelectionMode(session.id),
                onToggleSelect: () => _toggleSessionSelection(session.id),
                onTogglePin: () => ref
                    .read(settingsRepositoryProvider)
                    .togglePlaylistSessionPinned(session.id),
                onOpen: () => session.currentTrackPath.isEmpty
                    ? showAppSnackBar(
                        context,
                        i18n.tr('queue_add_audio_first'),
                        tone: AppFeedbackTone.warning,
                        icon: Icons.queue_music_rounded,
                      )
                    : _openSessionDetail(context, session.id),
                onEdit: () => _openQueueEditor(context, session.id),
              )
            : SessionListCard(
                sessionId: session.id,
                track: track,
                coverPath: coverPath,
                coverGeneration: structureState.coverGeneration,
                coverCacheWidth: coverCacheWidth,
                showSubtitles: subtitleSettings.isGlobalEnabled(session.id),
                library: library,
                playback: playback,
                isSelectionMode: _isSelectionMode,
                isSelected: _selectedSessionIds.contains(session.id),
                isPinned: isPinned,
                onLongPress: () => _enterSelectionMode(session.id),
                onToggleSelect: () => _toggleSessionSelection(session.id),
                onTogglePin: () => ref
                    .read(settingsRepositoryProvider)
                    .togglePlaylistSessionPinned(session.id),
                onOpen: () => _openSessionDetail(context, session.id),
              ),
      );
      return KeyedSubtree(key: ValueKey(session.id), child: child);
    }

    return ScrollActivityGate(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: EdgeInsets.only(
                top: headerHeight + 4,
                bottom: listBottomInset,
                right: 4,
              ),
            ),
            child: PlaceholderContentTransition(
              showPlaceholder:
                  !_initialPlaceholderDismissed ||
                  !structureState.isInitialized,
              placeholder: PlaylistLoadingSkeleton(
                key: const ValueKey('playlist_initial_placeholder'),
                topPadding: topPadding,
                bottomPadding: bottomPadding,
              ),
              content: Stack(
                key: const ValueKey('playlist_loaded_content'),
                clipBehavior: Clip.none,
                children: [
                  if (!structureState.hasSessions)
                    SessionsEmptyState(
                      key: const ValueKey('empty_state'),
                      bottomInset: bottomPadding,
                      topInset: topPadding,
                      onOpenLibrary: widget.onOpenLibrary,
                    ),
                  if (structureState.hasSessions)
                    ListView.builder(
                      key: const PageStorageKey<String>('playlist_list'),
                      controller: _scrollController,
                      physics: const ClampingScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        playlistListHorizontalPadding,
                        topPadding,
                        playlistListHorizontalPadding,
                        bottomPadding,
                      ),
                      cacheExtent: listCacheExtent,
                      clipBehavior: Clip.none,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: visibleEntries.length + 1,
                      itemBuilder: buildSessionItem,
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Consumer(
              builder: (context, ref, child) {
                final headerState = _isActive
                    ? ref.watch(playlistHeaderUiProvider)
                    : ref.read(playlistHeaderUiProvider);
                final multiThreadEnabled = _readOrWatch(
                  settingsStateProvider.select(
                    (state) => state.value?.multiThreadPlaybackEnabled ?? false,
                  ),
                );

                if (_isSelectionMode) {
                  final count = _selectedSessionIds.length;
                  final isPlayEnabled =
                      count > 0 && (multiThreadEnabled || count <= 1);
                  final isPauseEnabled = count > 0;
                  final isPinEnabled = count > 0;
                  final isAllPinned = count > 0 &&
                      _selectedSessionIds
                          .every(pinnedPlaylistSessionIds.contains);
                  final isRemoveEnabled = count > 0;
                  final canCreateQueue = _hasSelectedPlaybackQueueSource(
                    visibleEntries,
                    paths,
                  );

                  return TopPageHeader(
                    key: const ValueKey('playlist_batch_selection_header'),
                    icon: Icons.graphic_eq_rounded,
                    topCapsuleTitle: i18n.tr('multi_select'),
                    topCapsuleData: i18n.tr('selected_count', {
                      'count': count.toString(),
                    }),
                    titleWidget: const SizedBox.shrink(),
                    leading: HeaderActionPill(
                      children: [
                        AppHeaderActionTransition(
                          child: IconButton(
                            key: const ValueKey('batch_play_button'),
                            onPressed: isPlayEnabled ? _handleBatchPlay : null,
                            icon: const Icon(Icons.play_arrow_rounded),
                            tooltip: i18n.tr('play'),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: HeaderActionPill.buttonConstraints,
                          ),
                        ),
                        AppHeaderActionTransition(
                          delayIndex: 1,
                          child: IconButton(
                            key: const ValueKey('batch_pause_button'),
                            onPressed: isPauseEnabled
                                ? _handleBatchPause
                                : null,
                            icon: const Icon(Icons.pause_rounded),
                            tooltip: i18n.tr('pause'),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: HeaderActionPill.buttonConstraints,
                          ),
                        ),
                        AppHeaderActionTransition(
                          delayIndex: 2,
                          child: IconButton(
                            key: const ValueKey('batch_create_queue_button'),
                            onPressed: canCreateQueue
                                ? () => _handleCreatePlaybackQueue(
                                    visibleEntries,
                                    playback,
                                    paths,
                                  )
                                : null,
                            icon: const Icon(Icons.playlist_add_rounded),
                            tooltip: i18n.tr('add_playback_queue'),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: HeaderActionPill.buttonConstraints,
                          ),
                        ),
                        AppHeaderActionTransition(
                          delayIndex: 3,
                          child: IconButton(
                            key: const ValueKey('batch_pin_button'),
                            onPressed: isPinEnabled ? _handleBatchPin : null,
                            icon: isAllPinned
                                ? const PushPinOffIcon()
                                : const Icon(Icons.push_pin_rounded),
                            tooltip: i18n.tr(
                              isAllPinned ? 'unpin_from_top' : 'pin_to_top',
                            ),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: HeaderActionPill.buttonConstraints,
                          ),
                        ),
                        AppHeaderActionTransition(
                          delayIndex: 4,
                          child: IconButton(
                            key: const ValueKey('batch_remove_button'),
                            onPressed: isRemoveEnabled
                                ? _handleBatchRemove
                                : null,
                            icon: const Icon(Icons.delete_outline_rounded),
                            tooltip: i18n.tr('remove'),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: HeaderActionPill.buttonConstraints,
                          ),
                        ),
                      ],
                    ),
                    trailing: AppHeaderLeadingTransition(
                      child: HeaderFloatingButton(
                        child: IconButton(
                          key: const ValueKey('exit_selection_button'),
                          onPressed: _exitSelectionMode,
                          icon: const Icon(Icons.close_rounded),
                          tooltip: i18n.tr('cancel'),
                        ),
                      ),
                    ),
                  ).withAppHeaderTransition();
                }

                return TopPageHeader(
                  key: headerKey,
                  icon: Icons.graphic_eq_rounded,
                  collapseController: _scrollController,
                  topCapsuleTitle: i18n.tr('playback_sessions'),
                  topCapsuleData: i18n.tr('playlist_header_stats', {
                    'sessions': headerState.sessionCount.toString(),
                    'playing': headerState.playingCount.toString(),
                  }),
                  title: i18n.tr('playback_sessions'),
                  titleWidget: _buildHeaderLeftActions(
                    context,
                    i18n,
                    structureState,
                  ),
                  trailing: SizedBox(
                    height: 38,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        AppHeaderActionTransition(
                          child: headerState.hasTimer
                              ? TimerCountdownCapsule(
                                  remaining:
                                      headerState.timerRemaining ??
                                      headerState.timerDuration ??
                                      Duration.zero,
                                  active: headerState.timerActive,
                                  autoResumeAt: headerState.autoResumeAt,
                                  onTap: widget.onTimerTap,
                                  onLongPress: () =>
                                      _openTimerQuickMenu(context),
                                )
                              : HeaderFloatingButton(
                                  child: GestureDetector(
                                    onLongPress: () {
                                      AppInteractionFeedback.trigger(
                                        AppInteractionFeedbackType.selection,
                                      );
                                      _openTimerQuickMenu(context);
                                    },
                                    child: IconButton(
                                      onPressed: widget.onTimerTap,
                                      icon: const Icon(Icons.alarm_rounded),
                                      tooltip: i18n.tr('timer'),
                                      iconSize: 20,
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                        width: 38,
                                        height: 38,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 8),
                        AppHeaderActionTransition(
                          delayIndex: 1,
                          child: HeaderFloatingButton(
                            child: IconButton(
                              key: const ValueKey<String>(
                                'playlist_sleep_canvas_button',
                              ),
                              onPressed: () {
                                Navigator.of(context).push(BedtimeCanvasPage.route());
                              },
                              icon: const Icon(Icons.bedtime_outlined),
                              tooltip: i18n.tr('sleep_mode'),
                              iconSize: 20,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 38,
                                height: 38,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AppHeaderActionTransition(
                          delayIndex: 2,
                          child: HeaderFloatingButton(
                            child: IconButton(
                              key: const ValueKey<String>(
                                'playlist_sort_button',
                              ),
                              onPressed: _openSortOptions,
                              icon: const Icon(Icons.sort_rounded),
                              tooltip: i18n.tr('sort_by'),
                              iconSize: 20,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 38,
                                height: 38,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ).withAppHeaderTransition();
              },
            ),
          ),
        ],
      ),
    );
  }

  void _openTimerQuickMenu(BuildContext context) {
    final timer = ref.read(timerFacadeProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;

    unawaited(
      AppBottomSheet.show<void>(
        context: context,
        builder: (sheetContext) => Consumer(
          builder: (context, ref, _) {
            final timerState =
                ref.watch(timerStateProvider).value ?? timer.state;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.timer_outlined, color: cs.primary, size: 22),
                        const SizedBox(width: 10),
                        Text(
                          i18n.tr('timer_title'),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SwitchListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      tileColor: cs.surfaceContainerLow,
                      secondary: Icon(
                        Icons.music_note_rounded,
                        color: timerState.stopAfterCurrentTrack
                            ? cs.primary
                            : null,
                      ),
                      title: Text(
                        i18n.tr('stop_after_current_track'),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        i18n.tr('stop_after_current_track_subtitle'),
                        style: const TextStyle(fontSize: 11),
                      ),
                      value: timerState.stopAfterCurrentTrack,
                      onChanged: (enabled) {
                        AppInteractionFeedback.trigger(
                          AppInteractionFeedbackType.selection,
                        );
                        timer.setStopAfterCurrentTrack(enabled);
                      },
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ActionChip(
                          avatar: const Icon(Icons.timer_10_rounded, size: 16),
                          label: const Text('15 min'),
                          onPressed: () {
                            timer.configureTimer(
                              TimerMode.manual,
                              const Duration(minutes: 15),
                            );
                            timer.startCountdown();
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.timer_rounded, size: 16),
                          label: const Text('30 min'),
                          onPressed: () {
                            timer.configureTimer(
                              TimerMode.manual,
                              const Duration(minutes: 30),
                            );
                            timer.startCountdown();
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.timer_rounded, size: 16),
                          label: const Text('60 min'),
                          onPressed: () {
                            timer.configureTimer(
                              TimerMode.manual,
                              const Duration(minutes: 60),
                            );
                            timer.startCountdown();
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.tune_rounded, size: 16),
                          label: Text(i18n.tr('set_countdown')),
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            widget.onTimerTap?.call();
                          },
                        ),
                      ],
                    ),
                    if (timerState.active || timerState.duration != null) ...[
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: () {
                          AppInteractionFeedback.trigger(
                            AppInteractionFeedbackType.destructive,
                          );
                          timer.cancelTimer();
                          Navigator.of(sheetContext).pop();
                        },
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: Text(i18n.tr('cancel_timer')),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: cs.error,
                          side: BorderSide(color: cs.error),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeaderLeftActions(
    BuildContext context,
    AppLanguageProvider i18n,
    PlaylistStructureState structureState,
  ) {
    return HeaderActionPill(
      children: [
        IconButton(
          key: const ValueKey<String>('playlist_pause_all_button'),
          onPressed: structureState.hasSessions
              ? () async {
                  final paused = await ref
                      .read(playbackFacadeProvider)
                      .pauseAllSessions();
                  if (!context.mounted) return;
                  showAppSnackBar(
                    context,
                    i18n.tr(paused ? 'all_paused' : 'operation_failed_retry'),
                    tone: paused
                        ? AppFeedbackTone.warning
                        : AppFeedbackTone.destructive,
                    icon: paused
                        ? Icons.pause_circle_outline_rounded
                        : Icons.error_outline_rounded,
                  );
                }
              : null,
          icon: const Icon(Icons.pause_circle_outline_rounded),
          tooltip: i18n.tr('pause_all_sessions'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
        IconButton(
          key: const ValueKey<String>('playlist_clear_all_button'),
          onPressed: structureState.hasSessions
              ? () =>
                    _clearAllWithUndo(context, ref.read(playbackFacadeProvider))
              : null,
          icon: const Icon(Icons.delete_sweep_rounded),
          tooltip: i18n.tr('clear_all_sessions'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
        IconButton(
          key: const ValueKey<String>('playlist_add_queue_button'),
          onPressed: () {
            final queueCount = structureState.entries
                .where((entry) => entry.isPlaybackQueue)
                .length;
            ref
                .read(playbackFacadeProvider)
                .createPlaybackQueue(
                  i18n.tr('default_playback_queue_name', {
                    'number': queueCount + 1,
                  }),
                );
            _scrollToTopOnQueueAdded();
          },
          icon: const Icon(Icons.playlist_add_rounded),
          tooltip: i18n.tr('add_playback_queue'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
      ],
    );
  }
}
