import '../../../app/presentation/browse_page_scroll.dart';
import '../../library/presentation/library_providers.dart';
import 'playback_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/application/audio_path_coordinator.dart';
import '../../../app/localization/app_language_provider.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/presentation/main_tab_state_mixin.dart';
import '../../../app/presentation/screen_view_models.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/ui/visual_settings_providers.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/animated_reorder.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/playlist_icon.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/scroll_to_top_list.dart';
import '../../../core/widgets/sort_options_bottom_sheet.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../settings/application/settings_state.dart';
import '../application/audio_state_services.dart';
import '../application/playback_facade.dart';
import '../domain/playback_mode.dart';
import 'bedtime_canvas_page.dart';
import 'playlist/playlist_batch_controller.dart';
import 'playlist/playlist_list_view.dart';
import 'playlist/playlist_queue_widgets.dart';
import 'playlist/playlist_shared_helpers.dart';
import 'playlist/playlist_volume_timer_widgets.dart';
import 'playlist/session_detail_page.dart';
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
    with MainTabStateMixin<PlaylistTab> {
  final ScrollController _scrollController = WindowsSmoothScrollController();
  bool _creatingQueue = false;
  final _selection = ValueNotifier<Set<String>>(const {});
  Set<String> get _selectedSessionIds => _selection.value;
  Set<String>? _knownSessionIds;
  final Set<String> _appearingQueueIds = <String>{};
  List<PlaybackDirectoryEntry>? _indexedEntries;
  List<String> _sessionOrder = const [];
  Map<String, int> _sessionIndices = const {};
  List<String>? _cachedPinnedList;
  Set<String> _cachedPinnedSet = const <String>{};

  Set<String> _resolvePinnedSet(List<String> ids) {
    if (!identical(_cachedPinnedList, ids)) {
      _cachedPinnedList = ids;
      _cachedPinnedSet = ids.isEmpty ? const <String>{} : ids.toSet();
    }
    return _cachedPinnedSet;
  }

  void _scrollToTopOnQueueAdded() {
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.jumpTo(0);
    }
  }

  void _selectOnlySession(String sessionId) {
    if (_creatingQueue) return;
    if (_selectedSessionIds.isNotEmpty) {
      _toggleSessionSelection(sessionId);
      return;
    }
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    _selection.value = {sessionId};
  }

  void _toggleSelectAll(List<PlaybackDirectoryEntry> entries) {
    if (_creatingQueue || entries.isEmpty) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    final allIds = entries.map((entry) => entry.id).toSet();
    final allSelected = allIds.every(_selectedSessionIds.contains);
    _selection.value = allSelected ? const <String>{} : allIds;
  }

  void _exitSelectionMode() {
    if (_creatingQueue) return;
    _selection.value = const {};
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted ||
        _creatingQueue ||
        _selectedSessionIds.isEmpty ||
        !_isActive ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    _exitSelectionMode();
    return true;
  }

  void _toggleSessionSelection(String sessionId) {
    if (_creatingQueue) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    final next = {..._selectedSessionIds};
    if (!next.remove(sessionId)) next.add(sessionId);
    _selection.value = next;
  }

  void _reconcileSelection(PlaylistStructureState structureState) {
    if (_selectedSessionIds.isEmpty) return;
    final availableSessionIds = structureState.entries
        .map((entry) => entry.id)
        .toSet();
    if (_selectedSessionIds.every(availableSessionIds.contains)) return;
    _selection.value = _selectedSessionIds.intersection(availableSessionIds);
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
    if (_creatingQueue) return;
    final sessionIds = PlaylistBatchActions.pinnableSessionIds(
      ref.read(playlistStructureUiProvider).entries,
      _selectedSessionIds,
    );
    if (sessionIds.isEmpty) return;
    _exitSelectionMode();
    await PlaylistBatchActions.pinSelected(
      context: context,
      ref: ref,
      selectedSessionIds: sessionIds,
    );
  }

  Future<void> _handleBatchRemove() async {
    if (_creatingQueue) return;
    final toRemove = _selectedSessionIds.toList(growable: false);
    _exitSelectionMode();
    await PlaylistBatchActions.removeSelected(
      context: context,
      ref: ref,
      selectedSessionIds: toRemove,
    );
  }

  Future<void> _handleCreatePlaybackQueue(
    PlaybackFacade playback,
    AudioPathCoordinator paths,
  ) async {
    if (_creatingQueue) return;
    final selectedIds = Set<String>.of(_selectedSessionIds);
    final visibleEntries = ref.read(playlistSortedEntriesUiProvider);
    setState(() => _creatingQueue = true);
    try {
      await PlaylistBatchActions.createPlaybackQueue(
        ref: ref,
        visibleEntries: visibleEntries,
        selectedSessionIds: selectedIds,
        playback: playback,
        paths: paths,
        onQueueAdded: _scrollToTopOnQueueAdded,
      );
      if (!mounted) return;
      setState(() => _creatingQueue = false);
      _exitSelectionMode();
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('operation_failed_retry'),
          tone: AppFeedbackTone.warning,
        );
      }
    } finally {
      if (mounted && _creatingQueue) setState(() => _creatingQueue = false);
    }
  }

  bool _hasSelectedPlaybackQueueSource(AudioPathCoordinator paths) =>
      PlaylistBatchActions.hasSelectedPlaybackQueueSource(
        playback: ref.read(playbackFacadeProvider),
        paths: paths,
        selectedSessionIds: _selectedSessionIds,
      );

  @override
  int get tabIndex => widget.tabIndex;

  @override
  ScrollController get mainScrollController => _scrollController;

  @override
  double get defaultHeaderHeight => AppPageHeaderMetrics.expandedToolbarHeight;

  double _minimumExpandedHeaderHeight(BuildContext context) {
    return AppPageHeaderMetrics.headerHeight(
      context,
      contentHeight: AppPageHeaderMetrics.expandedContentHeight,
    );
  }

  Orientation? _lastOrientation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final orientation = MediaQuery.maybeOrientationOf(context);
    if (_lastOrientation != orientation) {
      _lastOrientation = orientation;
      headerHeight = _minimumExpandedHeaderHeight(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        measureHeader();
      });
    } else {
      final minHeight = _minimumExpandedHeaderHeight(context);
      if (headerHeight < minHeight) {
        headerHeight = minHeight;
      }
    }
  }

  @override
  void measureHeader() {
    final box = headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      final h = box.size.height;
      final minHeight = _minimumExpandedHeaderHeight(context);
      final targetHeight = h < minHeight ? minHeight : h;
      if (targetHeight > 0 && (targetHeight - headerHeight).abs() > 0.5) {
        setState(() => headerHeight = targetHeight);
      }
    }
  }

  bool get _isSelected =>
      widget.activeTabIndexListenable == null ||
      widget.activeTabIndexListenable!.value == tabIndex;

  bool get _isActive {
    final route = readAppRoute(context);
    final isRouteCurrent = route == null || route.isCurrent;
    return isRouteCurrent && _isSelected;
  }

  @override
  void initState() {
    super.initState();
    final controller = ref.read(mainScreenControllerProvider);
    initTabState(controller.scrollToTopTab, controller.stopScrollTab);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
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
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(buildSessionDetailRoute(sessionId: sessionId, coverOrigin: context));
  }

  Future<void> _openQueueEditor(BuildContext context, String sessionId) {
    return showPlaybackQueueEditPanel(context, sessionId);
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
          label: i18n.tr('work_name_display_workTitle'),
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
    final saved = await saveSettingsWithFeedback(
      context,
      () => settings.setPlaylistSortOptions(
        criterion: result.criterion,
        ascending: result.ascending,
        groupByLibrary: result.groupByLibrary,
      ),
    );
    if (mounted && saved) {
      ref.read(playlistSortedEntriesUiProvider.notifier).applySort();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    disposeTabState();
    _selection.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final listBottomInset = MobileOverlayInset.of(context);
    final effectiveHeaderHeight = headerHeight > defaultHeaderHeight
        ? headerHeight
        : _minimumExpandedHeaderHeight(context);
    final topPadding =
        effectiveHeaderHeight + AppPageHeaderMetrics.firstContentSpacing;
    final bottomPadding = listBottomInset + 16.0;
    final sessionsInitialized =
        ref.watch(
          playbackCatalogProvider.select((s) => s.value?.isInitialized),
        ) ??
        ref.read(playbackFacadeProvider).catalogState.isInitialized;

    final page = ScrollActivityGate(
      onMetricsChanged: ref
          .read(libraryCoverUiControllerProvider)
          .viewportChanged,
      child: PageHeaderInset(
        topInset: topPadding,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            buildScrollToTopTransition(
              AppPageContentTransition.deferred(
                isReady: sessionsInitialized,
                placeholder: PlaylistLoadingSkeleton(
                  key: const ValueKey('playlist_initial_placeholder'),
                  topPadding: topPadding,
                  bottomPadding: bottomPadding,
                ),
                builder: (context) => Consumer(
                  builder: (context, contentRef, _) => _buildPlaylistContent(
                    context,
                    contentRef,
                    topPadding: topPadding,
                    bottomPadding: bottomPadding,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Align(
                alignment: Alignment.topCenter,
                child: Builder(
                  builder: (headerContext) {
                    final isSelectionMode =
                        PlaylistSelectionScope.maybeIsSelectionModeOf(
                          headerContext,
                        ) ??
                        false;
                    return AppHeaderTransition(
                      child: isSelectionMode
                          ? Consumer(
                              key: const ValueKey<String>(
                                'playlist_selection_header_scope',
                              ),
                              builder: (context, ref, _) {
                                final selectedIds =
                                    PlaylistSelectionScope.maybeIdsOf(
                                      context,
                                    ) ??
                                    const <String>{};
                                final pinnedPlaylistSessionIds =
                                    _resolvePinnedSet(
                                      ref.watch(
                                        settingsStateProvider.select(
                                          (state) =>
                                              state
                                                  .value
                                                  ?.pinnedPlaylistSessionIds ??
                                              const <String>[],
                                        ),
                                      ),
                                    );
                                final paths = ref.read(
                                  audioPathCoordinatorProvider,
                                );
                                final playback = ref.read(
                                  playbackFacadeProvider,
                                );
                                final count = selectedIds.length;
                                final entries = ref
                                    .watch(playlistStructureUiProvider)
                                    .entries;
                                final pinTargets =
                                    PlaylistBatchActions.pinnableSessionIds(
                                      entries,
                                      selectedIds,
                                    );
                                final isPlayEnabled =
                                    count > 0 && !_creatingQueue;
                                final isPauseEnabled =
                                    count > 0 && !_creatingQueue;
                                final isPinEnabled =
                                    pinTargets.isNotEmpty && !_creatingQueue;
                                final isAllPinned =
                                    pinTargets.isNotEmpty &&
                                    pinTargets.every(
                                      pinnedPlaylistSessionIds.contains,
                                    );
                                final isRemoveEnabled =
                                    count > 0 && !_creatingQueue;
                                final canCreateQueue =
                                    !_creatingQueue &&
                                    _hasSelectedPlaybackQueueSource(paths);
                                final allSelected =
                                    entries.isNotEmpty &&
                                    entries.every(
                                      (entry) => selectedIds.contains(entry.id),
                                    );

                                final closeButton = HeaderFloatingButton(
                                  child: IconButton(
                                    key: const ValueKey(
                                      'exit_selection_button',
                                    ),
                                    onPressed: _creatingQueue
                                        ? null
                                        : _exitSelectionMode,
                                    icon: const Icon(Icons.close_rounded),
                                    tooltip: i18n.tr('cancel'),
                                  ),
                                );

                                return TopPageHeader(
                                  key: const ValueKey(
                                    'playlist_batch_selection_header',
                                  ),
                                  iconWidget: const PlaylistIcon(),
                                  topCapsuleTitle: i18n.tr('multi_select'),
                                  topCapsuleData: i18n.tr('selected_count'),
                                  topCapsuleDataCount: count,
                                  titleWidget: const SizedBox.shrink(),
                                  leading: HeaderActionPill(
                                    shrinkSpacingToFit: true,
                                    children: [
                                      IconButton(
                                        key: const ValueKey('batch_play_button'),
                                        onPressed: isPlayEnabled
                                            ? _handleBatchPlay
                                            : null,
                                        icon: const Icon(
                                          Icons.play_arrow_rounded,
                                        ),
                                        tooltip: i18n.tr('play'),
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints:
                                            HeaderActionPill.buttonConstraints,
                                      ),
                                      IconButton(
                                        key: const ValueKey(
                                          'batch_pause_button',
                                        ),
                                        onPressed: isPauseEnabled
                                            ? _handleBatchPause
                                            : null,
                                        icon: const Icon(Icons.pause_rounded),
                                        tooltip: i18n.tr('pause'),
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints:
                                            HeaderActionPill.buttonConstraints,
                                      ),
                                      IconButton(
                                        key: const ValueKey(
                                          'batch_create_queue_button',
                                        ),
                                        onPressed: canCreateQueue
                                            ? () => _handleCreatePlaybackQueue(
                                                playback,
                                                paths,
                                              )
                                            : null,
                                        icon: const Icon(
                                          Icons.playlist_add_rounded,
                                        ),
                                        tooltip: i18n.tr('add_playback_queue'),
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints:
                                            HeaderActionPill.buttonConstraints,
                                      ),
                                      IconButton(
                                        key: const ValueKey('batch_pin_button'),
                                        onPressed: isPinEnabled
                                            ? _handleBatchPin
                                            : null,
                                        icon: isAllPinned
                                            ? const PushPinOffIcon()
                                            : const Icon(
                                                Icons.push_pin_rounded,
                                              ),
                                        tooltip: i18n.tr(
                                          isAllPinned
                                              ? 'unpin_from_top'
                                              : 'pin_to_top',
                                        ),
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints:
                                            HeaderActionPill.buttonConstraints,
                                      ),
                                      IconButton(
                                        key: const ValueKey(
                                          'batch_remove_button',
                                        ),
                                        onPressed: isRemoveEnabled
                                            ? _handleBatchRemove
                                            : null,
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                        ),
                                        style: appIconButtonStyle(
                                          IconButton.styleFrom(
                                            foregroundColor: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                        ),
                                        tooltip: i18n.tr('remove'),
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints:
                                            HeaderActionPill.buttonConstraints,
                                      ),
                                    ],
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      HeaderFloatingButton(
                                        child: IconButton(
                                          key: const ValueKey(
                                            'batch_select_all_button',
                                          ),
                                          onPressed:
                                              entries.isEmpty || _creatingQueue
                                              ? null
                                              : () => _toggleSelectAll(entries),
                                          icon: Icon(
                                            allSelected
                                                ? Icons.deselect_rounded
                                                : Icons.select_all_rounded,
                                          ),
                                          tooltip: i18n.tr(
                                            allSelected
                                                ? 'deselect_all'
                                                : 'select_all',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      closeButton,
                                    ],
                                  ),
                                );
                              },
                            )
                          : Consumer(
                              key: const ValueKey<String>(
                                'playlist_normal_header_scope',
                              ),
                              builder: (context, ref, _) {
                                final headerState = ref.watch(
                                  playlistHeaderUiProvider.select(
                                    (s) => PlaylistHeaderState(
                                      sessionCount: s.sessionCount,
                                      playingCount: s.playingCount,
                                      hasPlayingAudioSession:
                                          s.hasPlayingAudioSession,
                                      timerDuration: s.timerDuration,
                                      timerRemaining: null,
                                      timerActive: s.timerActive,
                                      autoResumeAt: s.autoResumeAt,
                                      hasActivePlayback: s.hasActivePlayback,
                                      canResumeLastPlayback:
                                          s.canResumeLastPlayback,
                                    ),
                                  ),
                                );
                                return TopPageHeader(
                                  key: headerKey,
                                  iconWidget: const PlaylistIcon(),
                                  collapseController: _scrollController,
                                  topCapsuleTitle: i18n.tr('playback_sessions'),
                                  topCapsuleData: i18n.tr(
                                    'playlist_header_stats',
                                    {
                                      'sessions':
                                          headerState.sessionCount.toString(),
                                      'playing':
                                          headerState.playingCount.toString(),
                                    },
                                  ),
                                  title: i18n.tr('playback_sessions'),
                                  titleWidget: _buildHeaderLeftActions(
                                    context,
                                    i18n,
                                    headerState,
                                  ),
                                  trailing: SizedBox(
                                    height: 38,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        _buildTimerButton(
                                          context,
                                          i18n,
                                          headerState,
                                        ),
                                        if (defaultTargetPlatform !=
                                            TargetPlatform.windows) ...[
                                          const SizedBox(width: 8),
                                          HeaderFloatingButton(
                                            child: IconButton(
                                              key: const ValueKey<String>(
                                                'playlist_sleep_canvas_button',
                                              ),
                                              onPressed: headerState
                                                      .hasPlayingAudioSession
                                                  ? () {
                                                      if (!ref
                                                          .read(
                                                            playbackFacadeProvider,
                                                          )
                                                          .hasPlayingAudioSession) {
                                                        return;
                                                      }
                                                      Navigator.of(
                                                        context,
                                                      ).push(
                                                        BedtimeCanvasPage.route(
                                                          context,
                                                        ),
                                                      );
                                                    }
                                                  : null,
                                              icon: const Icon(
                                                Icons.bedtime_outlined,
                                              ),
                                              tooltip: i18n.tr('sleep_mode'),
                                              iconSize: 20,
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                    width: 38,
                                                    height: 38,
                                                  ),
                                            ),
                                          ),
                                        ],
                                        const SizedBox(width: 8),
                                        HeaderFloatingButton(
                                          child: IconButton(
                                            key: const ValueKey<String>(
                                              'playlist_sort_button',
                                            ),
                                            onPressed: _openSortOptions,
                                            icon: const Icon(
                                              Icons.sort_rounded,
                                            ),
                                            tooltip: i18n.tr('sort_by'),
                                            iconSize: 20,
                                            padding: EdgeInsets.zero,
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 38,
                                                  height: 38,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return ValueListenableBuilder<Set<String>>(
      valueListenable: _selection,
      child: page,
      builder: (context, ids, child) => PopScope<void>(
        canPop: ids.isEmpty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _selectedSessionIds.isNotEmpty) {
            _exitSelectionMode();
          }
        },
        child: PlaylistSelectionScope(ids: ids, child: child!),
      ),
    );
  }

  Widget _buildPlaylistContent(
    BuildContext context,
    WidgetRef ref, {
    required double topPadding,
    required double bottomPadding,
  }) {
    final library = ref.read(libraryFacadeProvider);
    final paths = ref.read(audioPathCoordinatorProvider);
    final playback = ref.read(playbackFacadeProvider);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    ref.listen(playlistStructureUiProvider, (_, next) {
      if (mounted && _isActive) _reconcileSelection(next);
    });
    final structureState = ref.watch(playlistStructureUiProvider);
    final visibleEntries = ref.watch(playlistSortedEntriesUiProvider);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final orderChanged = !identical(_indexedEntries, visibleEntries);
    if (orderChanged) {
      _indexedEntries = visibleEntries;
      _sessionOrder = visibleEntries.map((entry) => entry.id).toList();
      _sessionIndices = {
        for (var i = 0; i < _sessionOrder.length; i++) _sessionOrder[i]: i,
      };
    }
    if (structureState.isInitialized &&
        (orderChanged || _knownSessionIds == null)) {
      if (_knownSessionIds case final known?) {
        for (final entry in visibleEntries) {
          if (entry.queueName != null && !known.contains(entry.id)) {
            _appearingQueueIds.add(entry.id);
          }
        }
      }
      _knownSessionIds = _sessionIndices.keys.toSet();
      _appearingQueueIds.removeWhere((id) => !_sessionIndices.containsKey(id));
    }
    if (disableAnimations) _appearingQueueIds.clear();
    final coverImageResolution = ref.watch(coverImageResolutionProvider);
    final coverCacheWidth = coverThumbnailCacheWidth(
      logicalWidth: playlistCoverSize,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: coverImageResolution,
    );
    Widget buildSessionItem(BuildContext context, int index) {
      if (index == visibleEntries.length) {
        return const SizedBox.shrink(key: ValueKey('bottom_spacing'));
      }
      final session = visibleEntries[index];
      final isQueue = session.queueName != null;
      final isTemporary = session.isTemporary;
      // Queue rows resolve their own current track and cover mosaic. Only
      // ordinary sessions need the single-track artwork prepared here.
      final track = isQueue
          ? null
          : paths.sessionTrackForPath(session.id, session.currentTrackPath);
      final card = _MemoizedPlaylistCard(
        signature: (
          session.id,
          session.currentTrackPath,
          track,
          coverCacheWidth,
          isQueue,
          isTemporary,
          library,
          playback,
          i18n.language,
        ),
        builder: (cardContext) => RepaintBoundary(
          child: isQueue
              ? PlaybackQueueCard(
                  sessionId: session.id,
                  library: library,
                  playback: playback,
                  coverCacheWidth: coverCacheWidth,
                  onLongPress: () => _selectOnlySession(session.id),
                  onToggleSelect: () => _toggleSessionSelection(session.id),
                  onTogglePin: isTemporary
                      ? null
                      : () => saveSettingsWithFeedback(
                          cardContext,
                          () => ref
                              .read(settingsRepositoryProvider)
                              .togglePlaylistSessionPinned(session.id),
                        ),
                  onOpen: (coverOrigin) =>
                      playback
                              .sessionById(session.id)
                              ?.currentTrackPath
                              .isNotEmpty !=
                          true
                      ? _openQueueEditor(cardContext, session.id)
                      : _openSessionDetail(coverOrigin, session.id),
                  onEdit: () => _openQueueEditor(cardContext, session.id),
                )
              : SessionListCard(
                  sessionId: session.id,
                  track: track,
                  coverCacheWidth: coverCacheWidth,
                  library: library,
                  playback: playback,
                  isTemporary: isTemporary,
                  onLongPress: () => _selectOnlySession(session.id),
                  onToggleSelect: () => _toggleSessionSelection(session.id),
                  onTogglePin: isTemporary
                      ? null
                      : () => saveSettingsWithFeedback(
                          cardContext,
                          () => ref
                              .read(settingsRepositoryProvider)
                              .togglePlaylistSessionPinned(session.id),
                        ),
                  onOpen: (coverOrigin) =>
                      _openSessionDetail(coverOrigin, session.id),
                ),
        ),
      );
      return AnimatedReorderItem(
        key: ValueKey(session.id),
        id: session.id,
        child: BrowseAnchor(
          id: session.id,
          child: isQueue
              ? TweenAnimationBuilder<double>(
                  key: ValueKey('playlist_queue_appearance_${session.id}'),
                  tween: Tween<double>(
                    begin: _appearingQueueIds.contains(session.id) ? 0 : 1,
                    end: 1,
                  ),
                  duration: disableAnimations
                      ? Duration.zero
                      : kAppFadeDuration,
                  curve: kAppFadeCurve,
                  onEnd: () => _appearingQueueIds.remove(session.id),
                  builder: (context, opacity, child) =>
                      Opacity(opacity: opacity, child: child),
                  child: card,
                )
              : card,
        ),
      );
    }

    final sessionIndices = _sessionIndices;

    return BrowsePageScroll(
      pageKey: 'playlist',
      controller: _scrollController,
      anchorIndices: sessionIndices,
      child: PlaceholderContentTransition(
        showPlaceholder: !structureState.isInitialized,
        placeholder: PlaylistLoadingSkeleton(
          key: const ValueKey('playlist_data_placeholder'),
          topPadding: topPadding,
          bottomPadding: bottomPadding,
        ),
        content: PlaceholderContentTransition(
          key: const ValueKey('playlist_loaded_content'),
          showPlaceholder: !structureState.hasSessions,
          placeholder: SessionsEmptyState(
            key: const ValueKey('empty_state'),
            bottomInset: bottomPadding,
            topInset: topPadding,
            onOpenLibrary: widget.onOpenLibrary,
          ),
          content: Consumer(
            builder: (context, ref, child) {
              final pinnedIds = _resolvePinnedSet(
                ref.watch(
                  settingsStateProvider.select(
                    (state) =>
                        state.value?.pinnedPlaylistSessionIds ??
                        const <String>[],
                  ),
                ),
              );
              return PlaylistPinnedScope(pinnedIds: pinnedIds, child: child!);
            },
            child: AnimatedReorder(
              order: _sessionOrder,
              child: ScrollToTopListView.builder(
                key: const PageStorageKey<String>('playlist_list'),
                controller: _scrollController,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  playlistListHorizontalPadding,
                  topPadding,
                  playlistListHorizontalPadding,
                  bottomPadding,
                ),
                // Match the library's small prefetch window. A wide viewport
                // already lays out more cards without another screen of cache.
                cacheExtent: 320,
                addRepaintBoundaries: false,
                clipBehavior: Clip.none,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: visibleEntries.length + 1,
                itemBuilder: buildSessionItem,
                findChildIndexCallback: (key) =>
                    key is ValueKey<String> ? sessionIndices[key.value] : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimerButton(
    BuildContext context,
    AppLanguageProvider i18n,
    PlaylistHeaderState state,
  ) {
    return UnifiedContextMenuRegion(
      key: ValueKey(state.hasTimer),
      shape: state.hasTimer ? const StadiumBorder() : const CircleBorder(),
      skipTraversal: true,
      openOnAndroidLongPress: true,
      openOnWindowsLongPress: true,
      buildEntries: () => _buildTimerQuickMenuEntries(i18n),
      child: state.hasTimer
          ? Consumer(
              builder: (context, ref, _) {
                final timerRemaining = ref.watch(
                  playlistTimerRemainingUiProvider,
                );
                return TimerCountdownCapsule(
                  remaining:
                      timerRemaining ?? state.timerDuration ?? Duration.zero,
                  active: state.timerActive,
                  autoResumeAt: state.autoResumeAt,
                  onTap: widget.onTimerTap,
                );
              },
            )
          : HeaderFloatingButton(
              child: TooltipTheme(
                data: TooltipTheme.of(
                  context,
                ).copyWith(triggerMode: TooltipTriggerMode.manual),
                child: IconButton(
                  onPressed: widget.onTimerTap,
                  icon: const Icon(Icons.timer_rounded),
                  tooltip: i18n.tr('timer'),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 38,
                    height: 38,
                  ),
                ),
              ),
            ),
    );
  }

  List<UnifiedMenuEntry<VoidCallback>> _buildTimerQuickMenuEntries(
    AppLanguageProvider i18n,
  ) {
    final timer = ref.read(timerFacadeProvider);
    final state = timer.state;
    return [
      if (state.duration != null &&
          (state.active || state.remaining != Duration.zero))
        UnifiedMenuEntry.action(
          value: () {
            final current = timer.state;
            if (current.duration != null &&
                (current.active || current.remaining != Duration.zero)) {
              timer.setStopAfterCurrentTrack(!current.stopAfterCurrentTrack);
            }
          },
          icon: Icons.music_note_rounded,
          label: i18n.tr('stop_after_current_track'),
          trailing: state.stopAfterCurrentTrack
              ? const Icon(Icons.check_rounded, size: 16)
              : null,
        ),
      for (final minutes in const [15, 30, 60])
        UnifiedMenuEntry.action(
          value: () {
            timer.configureTimer(TimerMode.manual, Duration(minutes: minutes));
            timer.startCountdown();
          },
          icon: Icons.timer_rounded,
          label: i18n.tr('minutes_duration', {'count': minutes}),
        ),
      UnifiedMenuEntry.action(
        value: () => widget.onTimerTap?.call(),
        enabled: widget.onTimerTap != null,
        icon: Icons.more_time_rounded,
        label: i18n.tr('set_countdown'),
      ),
      if (state.active || state.duration != null)
        UnifiedMenuEntry.action(
          value: timer.cancelTimer,
          icon: Icons.stop_circle_outlined,
          label: i18n.tr('cancel_timer'),
          destructive: true,
        ),
    ];
  }

  Widget _buildHeaderLeftActions(
    BuildContext context,
    AppLanguageProvider i18n,
    PlaylistHeaderState headerState,
  ) {
    final hasSessions = headerState.sessionCount > 0;
    final pausing = headerState.hasActivePlayback;
    return HeaderActionPill(
      children: [
        IconButton(
          key: ValueKey<String>(
            pausing
                ? 'playlist_pause_all_button'
                : 'playlist_resume_last_button',
          ),
          onPressed: pausing || headerState.canResumeLastPlayback
              ? () async {
                  final playback = ref.read(playbackFacadeProvider);
                  final success = pausing
                      ? await playback.pauseAllSessions()
                      : await playback.resumeLastPlayback();
                  if (!context.mounted || success) return;
                  showAppSnackBar(
                    context,
                    i18n.tr('operation_failed_retry'),
                    tone: AppFeedbackTone.destructive,
                    icon: Icons.error_outline_rounded,
                  );
                }
              : null,
          icon: Icon(
            pausing
                ? Icons.pause_circle_outline_rounded
                : Icons.play_circle_outline_rounded,
          ),
          tooltip: i18n.tr(
            pausing ? 'pause_all_sessions' : 'resume_last_playback',
          ),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
        IconButton(
          key: const ValueKey<String>('playlist_clear_all_button'),
          onPressed: hasSessions
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
            final queueCount = ref
                .read(playlistStructureUiProvider)
                .entries
                .where((entry) => entry.queueName != null)
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

/// Caches the built row card until its structural inputs change so pin/sort
/// reorders reuse live row elements instead of rebuilding every visible card.
class _MemoizedPlaylistCard extends StatefulWidget {
  const _MemoizedPlaylistCard({
    required this.signature,
    required this.builder,
  });

  final Object signature;
  final WidgetBuilder builder;

  @override
  State<_MemoizedPlaylistCard> createState() => _MemoizedPlaylistCardState();
}

class _MemoizedPlaylistCardState extends State<_MemoizedPlaylistCard> {
  Widget? _cachedChild;

  @override
  void didUpdateWidget(covariant _MemoizedPlaylistCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.signature != oldWidget.signature) {
      _cachedChild = null;
    }
  }

  @override
  Widget build(BuildContext context) =>
      _cachedChild ??= widget.builder(context);
}
