import 'dart:async';

import '../../core/widgets/app_buttons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_runtime_providers.dart';
import '../state/listening_activity_provider.dart';
import '../theme/app_styles.dart';
import '../theme/app_design_tokens.dart';
import '../../core/media/music_track.dart';
import '../../core/media/path_display.dart';
import '../../core/logging/app_log_service.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/ui/undoable_removal_service.dart';
import '../../core/widgets/app_edit_panel.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/async_cover_image.dart';
import '../../core/widgets/file_tree_row.dart';
import '../../core/widgets/mobile_overlay_inset.dart';
import '../../core/widgets/page_header_inset.dart';
import '../../core/widgets/scroll_activity_gate.dart';
import '../../core/widgets/shimmer_loading.dart';
import '../../core/widgets/swipe_reveal_card.dart';
import '../../core/widgets/top_page_header.dart';
import '../../core/widgets/unified_popup_menu.dart';
import '../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../features/asmr/domain/asmr_models.dart';
import '../../features/asmr/presentation/asmr_providers.dart';
import '../../features/asmr/presentation/asmr_work_detail_sheet.dart';
import '../../features/library/presentation/audio_detail_sheet.dart';
import '../../features/library/presentation/library_providers.dart';
import '../../features/settings/application/settings_state.dart';
import '../../features/settings/presentation/settings_providers.dart';
import 'app_presentation_providers.dart';
import 'element_action_menu.dart';
import 'listening_time_chart.dart';
import 'main_tab_state_mixin.dart';
import 'my_tag_management_page.dart';

class MyPage extends ConsumerStatefulWidget {
  const MyPage({
    super.key,
    required this.tabIndex,
    this.activeTabIndexListenable,
  });
  final int tabIndex;
  final ValueListenable<int>? activeTabIndexListenable;

  @override
  ConsumerState<MyPage> createState() => _MyPageState();
}

class _MyPageState extends ConsumerState<MyPage>
    with MainTabStateMixin<MyPage> {
  final _scroll = WindowsSmoothScrollController();
  MyInterestType _interestType = MyInterestType.tags;
  bool _isActive = true;
  AsyncValue<ListeningActivityView>? _cachedActivity;
  late final _refreshCommitKey =
      'my_activity_refresh_${identityHashCode(this)}';
  bool get _isTabActive =>
      widget.activeTabIndexListenable == null ||
      widget.activeTabIndexListenable!.value == widget.tabIndex;
  @override
  int get tabIndex => widget.tabIndex;
  @override
  bool get handlesScrollToTop =>
      _isActive && TickerMode.getValuesNotifier(context).value.enabled;
  @override
  ScrollController get mainScrollController => _scroll;

  @override
  void initState() {
    super.initState();
    _isActive = _isTabActive;
    widget.activeTabIndexListenable?.addListener(_handleActiveTabChanged);
    final controller = ref.read(mainScreenControllerProvider);
    initTabState(controller.scrollToTopTab, controller.stopScrollTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scheduleActivityRefresh();
    });
  }

  @override
  void didUpdateWidget(covariant MyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTabIndexListenable != widget.activeTabIndexListenable) {
      oldWidget.activeTabIndexListenable?.removeListener(
        _handleActiveTabChanged,
      );
      widget.activeTabIndexListenable?.addListener(_handleActiveTabChanged);
    }
    if (oldWidget.activeTabIndexListenable != widget.activeTabIndexListenable ||
        oldWidget.tabIndex != widget.tabIndex) {
      _applyActiveState(_isTabActive);
    }
  }

  void _scheduleActivityRefresh() {
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _refreshCommitKey,
      canRun: () =>
          mounted &&
          _isActive &&
          TickerMode.getValuesNotifier(context).value.enabled,
      commit: () => unawaited(_refreshActivity()),
    );
  }

  bool _applyActiveState(bool nextActive) {
    if (nextActive == _isActive) return false;
    if (!nextActive) {
      _cachedActivity = ref.read(listeningActivityProvider);
    }
    _isActive = nextActive;
    if (nextActive) {
      _scheduleActivityRefresh();
    }
    return true;
  }

  void _handleActiveTabChanged() {
    if (_applyActiveState(_isTabActive)) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.activeTabIndexListenable?.removeListener(_handleActiveTabChanged);
    disposeTabState();
    UiInteractionCoordinator.instance.cancelCommit(_refreshCommitKey);
    _scroll.dispose();
    super.dispose();
  }

  void _openTags(bool excluded) => Navigator.of(context).push<void>(
    buildAppPageRoute<void>(
      context: context,
      child: MyTagManagementPage(excluded: excluded, type: _interestType),
    ),
  );

  Future<void> _setChartStyle(ListeningChartStyle style) async {
    try {
      await ref.read(settingsRepositoryProvider).setListeningChartStyle(style);
    } catch (error, stack) {
      AppLogService.error(
        'my_chart_style_save_failed',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('operation_failed_retry'),
        );
      }
    }
  }

  Future<void> _refreshActivity() async {
    try {
      await ref.read(listeningActivityServiceProvider)?.refresh();
    } catch (error, stack) {
      AppLogService.error(
        'my_activity_refresh_failed',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('operation_failed_retry'),
        );
      }
    }
  }

  Future<void> _openHistory(MusicTrack track) async {
    final library = ref.read(libraryFacadeProvider);
    final targetKey = listeningWorkKey(track);
    final local = library.library
        .where(
          (candidate) =>
              !candidate.isRemoteAsmr &&
              listeningWorkKey(candidate) == targetKey,
        )
        .firstOrNull;
    if (local != null && !local.isRemoteAsmr) {
      await showAudioDetailSheet(
        context,
        library.audioDetailTargetForTrack(local),
      );
    } else if (track.remoteMetadata != null) {
      await showAsmrWorkDetailSheet(
        context,
        AsmrWork.fromJson(track.remoteMetadata!),
      );
    } else {
      showAppSnackBar(
        context,
        ref.read(appLanguageProviderInstanceProvider).tr('my_work_unavailable'),
      );
    }
  }

  Future<void> _removeHistory(String workKey) async {
    final activity = ref.read(listeningActivityServiceProvider);
    if (activity == null) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    late final ListeningHistoryEntry removed;
    await showUndoableRemovalFeedback(
      context,
      service: ref.read(undoableRemovalServiceProvider),
      action: UndoableRemovalAction(
        key: UndoableRemovalKey('listening-history', workKey),
        prepare: () async {
          try {
            final entry = await activity.removeHistoryEntry(workKey);
            if (entry == null) return false;
            removed = entry;
            return true;
          } catch (error, stack) {
            AppLogService.error(
              'my_history_delete_failed',
              error: error,
              stackTrace: stack,
            );
            return false;
          }
        },
        // The deletion is durable already. Keep the original entry for Undo.
        commit: () {},
        undo: () async {
          try {
            await activity.restoreHistoryEntry(removed);
          } catch (error, stack) {
            AppLogService.error(
              'my_history_restore_failed',
              error: error,
              stackTrace: stack,
            );
            if (mounted) {
              showAppSnackBar(context, i18n.tr('operation_failed_retry'));
            }
            rethrow;
          }
        },
      ),
      message: i18n.tr('my_history_deleted'),
      batchMessage: (count) => i18n.tr('items_removed_count', {'count': count}),
      undoLabel: i18n.tr('undo'),
      failureMessage: i18n.tr('removal_failed'),
    );
  }

  Future<void> _copyInterest(String name) async {
    await Clipboard.setData(ClipboardData(text: name));
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    if (!mounted) return;
    showAppSnackBar(
      context,
      ref.read(appLanguageProviderInstanceProvider).tr('copied_to_clipboard', {
        'value': name,
      }),
      icon: Icons.content_copy_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final activityReady = _isActive
        ? ref.watch(
            listeningActivityProvider.select(
              (state) => state.hasValue || state.hasError,
            ),
          )
        : (_cachedActivity?.hasValue == true ||
              _cachedActivity?.hasError == true);
    final controller = ref.watch(asmrLibraryControllerProvider);
    final top = AppPageHeaderMetrics.contentTopInset(context);
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium;
    Widget section(
      String title,
      Widget child, {
      Widget? trailing,
      Widget? titleWidget,
      bool skeleton = false,
      double headerSpacing = 4,
    }) {
      final titleLabel = titleWidget ?? Text(title, style: titleStyle);
      return Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                key: ValueKey('my-section-header-$title'),
                constraints: const BoxConstraints(minHeight: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: skeleton
                          ? Stack(
                              children: [
                                Opacity(opacity: 0, child: titleLabel),
                                const Positioned.fill(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: ShimmerContainer(
                                      width: 80,
                                      height: 18,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : titleLabel,
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      Flexible(child: trailing),
                    ],
                  ],
                ),
              ),
              SizedBox(height: headerSpacing),
              child,
            ],
          ),
        ),
      );
    }

    Widget sectionError({
      Key? key,
      required VoidCallback onRetry,
    }) {
      final cs = theme.colorScheme;
      return Row(
        key: key,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              i18n.tr('my_load_failed'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: Text(i18n.tr('my_retry')),
          ),
        ],
      );
    }

    Widget interestTab(MyInterestType type) {
      final selected = _interestType == type;
      final colors = theme.colorScheme;
      return Semantics(
        selected: selected,
        child: TextButton(
          key: ValueKey(
            'my-interest-tab-${type == MyInterestType.voiceActors ? 'voices' : type.name}',
          ),
          style: appTextButtonStyle(
            style:
                TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: selected
                      ? titleStyle?.color ?? colors.onSurface
                      : colors.onSurfaceVariant.withValues(alpha: 0.8),
                  backgroundColor: Colors.transparent,
                  overlayColor: Colors.transparent,
                ).copyWith(
                  textStyle: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.focused)
                        ? titleStyle?.copyWith(
                            decoration: TextDecoration.underline,
                          )
                        : titleStyle,
                  ),
                ),
          ),
          onPressed: () {
            if (selected) return;
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            setState(() => _interestType = type);
          },
          child: Text(i18n.tr(type.titleKey)),
        ),
      );
    }

    Widget interestTabs() => Wrap(
      spacing: AppSpacing.md,
      children: [for (final type in MyInterestType.values) interestTab(type)],
    );
    final interestType = _interestType;
    final interestKeyPrefix = switch (interestType) {
      MyInterestType.tags => '',
      MyInterestType.voiceActors => 'voice-',
      MyInterestType.circles => 'circle-',
    };
    final interestActionStyle = OutlinedButton.styleFrom(
      padding: const EdgeInsets.all(8),
    );
    const interestLoadingPlaceholder = ShimmerContainer(
      width: 120,
      height: 32,
      borderRadius: 8,
    );
    Widget interestSection() => section(
      i18n.tr('my_interests'),
      AnimatedSwitcher(
        key: const ValueKey('my-interest-transition'),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : kAppFadeDuration,
        switchInCurve: kAppFadeCurve,
        switchOutCurve: kAppFadeCurve,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [
            for (final child in previous)
              ExcludeFocus(
                child: ExcludeSemantics(child: IgnorePointer(child: child)),
              ),
            ?current,
          ],
        ),
        child: KeyedSubtree(
          key: ValueKey(interestType),
          child: controller == null
              ? Text(i18n.tr(interestType.emptyKey))
              : Consumer(
                  builder: (context, ref, _) {
                    if (interestType != MyInterestType.tags) {
                      ref.listen(asmrTagInterestsProvider, (_, _) {});
                    }
                    if (interestType != MyInterestType.voiceActors) {
                      ref.listen(asmrVoiceActorInterestsProvider, (_, _) {});
                    }
                    if (interestType != MyInterestType.circles) {
                      ref.listen(asmrCircleInterestsProvider, (_, _) {});
                    }
                    final provider = switch (interestType) {
                      MyInterestType.tags => asmrTagInterestsProvider,
                      MyInterestType.voiceActors =>
                        asmrVoiceActorInterestsProvider,
                      MyInterestType.circles => asmrCircleInterestsProvider,
                    };
                    final state = ref.watch(provider);
                    final Widget interestContent;
                    if (!state.hasValue) {
                      if (state.hasError) {
                        interestContent = sectionError(
                          key: const ValueKey('interest-error'),
                          onRetry: () => ref.invalidate(provider),
                        );
                      } else {
                        interestContent = const ShimmerLoader(
                          key: ValueKey('interest-loading'),
                          child: interestLoadingPlaceholder,
                        );
                      }
                    } else {
                      final interests = state.requireValue;
                      interestContent = Column(
                        key: const ValueKey('interest-loaded'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (interests.isEmpty)
                            Text(i18n.tr(interestType.emptyKey)),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final interest in interests.take(20))
                                ElementActionMenu(
                                  value: interest.tag.name,
                                  onCopy: () => _copyInterest(interest.tag.name),
                                  child: appNoPointerInkTheme(
                                    context: context,
                                    androidPressHighlight: true,
                                    child: InputChip(
                                      mouseCursor: WidgetStateMouseCursor.clickable,
                                      key: ValueKey(
                                        'my-${interestKeyPrefix}interest-${interest.tag.key}',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 8,
                                      ),
                                      labelPadding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      showCheckmark: false,
                                      side: BorderSide(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.outlineVariant,
                                      ),
                                      label: Text(
                                        interest.tag.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      onPressed: () =>
                                          _copyInterest(interest.tag.name),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            spacing: 8,
                            children: [
                              Flexible(
                                child: AppLabelledButton(
                                  OutlinedButton.icon,
                                  opensPage: true,
                                  style: interestActionStyle,
                                  onPressed: () => _openTags(false),
                                  icon: const Icon(Icons.add_rounded),
                                  label: Text(i18n.tr('my_add_interest_action')),
                                ),
                              ),
                              Flexible(
                                child: AppLabelledButton(
                                  OutlinedButton.icon,
                                  opensPage: true,
                                  style: interestActionStyle,
                                  onPressed: () => _openTags(true),
                                  icon: const Icon(Icons.block_rounded),
                                  label: Text(i18n.tr('my_add_exclusion_action')),
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    }
                    return AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : kPlaceholderContentTransitionDuration,
                      switchInCurve: kAppFadeCurve,
                      switchOutCurve: kAppFadeCurve,
                      child: interestContent,
                    );
                  },
                ),
        ),
      ),
      titleWidget: interestTabs(),
      headerSpacing: 12,
    );

    Widget pageList(
      List<Widget> children, {
      ScrollController? controller,
      bool scrollable = true,
    }) => ListView(
      controller: controller,
      primary: false,
      physics: scrollable ? null : const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        16,
        top,
        16,
        MobileOverlayInset.of(context) + 16,
      ),
      // There are only three bounded sections. Recreating an offscreen section
      // would rescan chart history and restart artwork, titles and taste reads
      // as it re-enters the viewport during a drag.
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: AppDesignTokens.of(context).readableContentMaxWidth,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final child in children) _RetainedMySection(child: child),
              ],
            ),
          ),
        ),
      ],
    );
    Widget listeningChart({bool skeleton = false}) => Consumer(
      builder: (context, ref, _) {
        final chartState = skeleton
            ? null
            : (_isActive
                  ? ref.watch(
                      listeningActivityProvider.select(_selectListeningChart),
                    )
                  : _selectListeningChart(
                      _cachedActivity ?? ref.read(listeningActivityProvider),
                    ));
        final style =
            ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.listeningChartStyle,
              ),
            ) ??
            ref
                .read(settingsRepositoryProvider)
                .slice
                .state
                .listeningChartStyle;
        Widget buildSection(Widget duration, Widget chart) => section(
          i18n.tr('my_listening_time'),
          chart,
          trailing: duration,
          skeleton: skeleton,
        );
        if (skeleton) {
          return ListeningTimeChart.skeleton(
            i18n: i18n,
            style: style,
            builder: buildSection,
          );
        }
        if (chartState!.hasError) {
          return section(
            i18n.tr('my_listening_time'),
            sectionError(onRetry: _refreshActivity),
          );
        }
        if (!chartState.hasValue) return const SizedBox.shrink();
        return ListeningTimeChart(
          days: chartState.days!,
          i18n: i18n,
          style: style,
          onStyleChanged: _setChartStyle,
          builder: buildSection,
        );
      },
    );
    Widget interestSkeleton() => section(
      i18n.tr('my_interests'),
      interestLoadingPlaceholder,
      skeleton: true,
      titleWidget: interestTabs(),
      headerSpacing: 12,
    );

    final historyRowHeight = _HistoryWorkRow.layoutHeight(context);
    final skeleton = Builder(
      builder: (context) => IgnorePointer(
        child: ExcludeSemantics(
          child: ShimmerLoader(
            key: const ValueKey('my-page-skeleton'),
            child: pageList([
              listeningChart(skeleton: true),
              interestSkeleton(),
              section(
                i18n.tr('my_history'),
                FileTreeSkeleton(
                  key: const ValueKey('my-skeleton-history'),
                  rowHeight: historyRowHeight,
                  viewportHeight: historyRowHeight * 3,
                  rowPadding: EdgeInsets.symmetric(
                    horizontal: _HistoryWorkRow.coverInset(historyRowHeight),
                  ),
                  leadingSize: _HistoryWorkRow.coverHeight,
                  leadingGap: 10,
                  shimmerEnabled: false,
                ),
                skeleton: true,
              ),
            ], scrollable: false),
          ),
        ),
      ),
    );
    return ScrollActivityGate(
      child: PageHeaderInset(
        topInset: top,
        child: Stack(
          children: [
            Positioned.fill(
              child: buildScrollToTopTransition(
                AppPageContentTransition.deferred(
                  isReady: activityReady,
                  placeholder: skeleton,
                  builder: (_) => pageList([
                    listeningChart(),
                    interestSection(),
                    section(
                      i18n.tr('my_history'),
                      Consumer(
                        builder: (context, ref, _) {
                          final historyState = _isActive
                              ? ref.watch(
                                  listeningActivityProvider.select(
                                    _selectListeningHistory,
                                  ),
                                )
                              : _selectListeningHistory(
                                  _cachedActivity ??
                                      ref.read(listeningActivityProvider),
                                );
                          if (historyState.hasValue) {
                            final history = historyState.history!;
                            return history.isEmpty
                                ? Text(
                                    i18n.tr('my_no_history'),
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  )
                                : _HistoryList(
                                    history: history,
                                    hasMoreHistory: historyState.hasMoreHistory,
                                    onOpen: _openHistory,
                                    onRemove: _removeHistory,
                                  );
                          }
                          if (historyState.hasError) {
                            return sectionError(onRetry: _refreshActivity);
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ], controller: _scroll),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                icon: Icons.person_rounded,
                topCapsuleTitle: i18n.tr('nav_my'),
                collapseController: _scroll,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RetainedMySection extends StatefulWidget {
  const _RetainedMySection({required this.child});
  final Widget child;

  @override
  State<_RetainedMySection> createState() => _RetainedMySectionState();
}

class _RetainedMySectionState extends State<_RetainedMySection>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

typedef _ListeningChartSlice = ({
  List<ListeningDay>? days,
  bool hasValue,
  bool hasError,
});

typedef _ListeningHistorySlice = ({
  List<ListeningHistoryEntry>? history,
  bool hasMoreHistory,
  bool hasValue,
  bool hasError,
});

_ListeningChartSlice _selectListeningChart(
  AsyncValue<ListeningActivityView> state,
) => (
  days: state.value?.days,
  hasValue: state.hasValue,
  hasError: state.hasError,
);

_ListeningHistorySlice _selectListeningHistory(
  AsyncValue<ListeningActivityView> state,
) => (
  history: state.value?.history,
  hasMoreHistory: state.value?.hasMoreHistory ?? false,
  hasValue: state.hasValue,
  hasError: state.hasError,
);

class _HistoryList extends ConsumerStatefulWidget {
  const _HistoryList({
    required this.history,
    required this.hasMoreHistory,
    required this.onOpen,
    required this.onRemove,
  });

  final List<ListeningHistoryEntry> history;
  final bool hasMoreHistory;
  final Future<void> Function(MusicTrack track) onOpen;
  final Future<void> Function(String workKey) onRemove;

  @override
  ConsumerState<_HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends ConsumerState<_HistoryList> {
  static const _pageSize = 10;
  final _rowsKey = GlobalKey();
  int _page = 0;
  int? _pendingPage;
  bool _choosingPage = false;

  int get _lastLoadedPage => (widget.history.length - 1) ~/ _pageSize;

  @override
  void didUpdateWidget(covariant _HistoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _page = _page.clamp(0, _lastLoadedPage);
    final pending = _pendingPage;
    if (pending != null &&
        (pending <= _lastLoadedPage || !widget.hasMoreHistory)) {
      _page = pending.clamp(0, _lastLoadedPage);
      _pendingPage = null;
      _revealFirstRow();
    }
  }

  void _revealFirstRow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rows = _rowsKey.currentContext;
      if (rows == null) return;
      unawaited(
        Scrollable.ensureVisible(
          rows,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ),
      );
    });
  }

  Future<void> _goToPage(int page) async {
    if (page <= _lastLoadedPage) {
      setState(() => _page = page);
      _revealFirstRow();
      return;
    }
    final service = ref.read(listeningActivityServiceProvider);
    if (service == null) return;
    // The activity stream publishes the new rows after active scrolling settles.
    setState(() => _pendingPage = page);
    try {
      await service.loadMoreHistory(minimumEntries: (page + 1) * _pageSize);
    } catch (error, stack) {
      _showPageLoadError(error, stack);
      if (mounted) setState(() => _pendingPage = null);
    }
  }

  void _showPageLoadError(Object error, StackTrace stack) {
    AppLogService.error(
      'my_history_load_failed',
      error: error,
      stackTrace: stack,
    );
    if (mounted) {
      showAppSnackBar(
        context,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr('operation_failed_retry'),
      );
    }
  }

  Future<void> _choosePage() async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final service = ref.read(listeningActivityServiceProvider);
    setState(() => _choosingPage = true);
    try {
      final count = widget.hasMoreHistory
          ? await service?.countHistory()
          : widget.history.length;
      if (!mounted || count == null || count <= _pageSize) return;
      final lastPage = (count - 1) ~/ _pageSize + 1;
      final form = GlobalKey<FormState>();
      int? pageNumber;
      final header = AppEditPanelHeader(
        title: i18n.tr('my_history_jump_to_page'),
        icon: Icons.find_in_page_outlined,
      );
      final selected = await showAppInputPanel<int>(
        context: context,
        header: header,
        preferredHeight: null,
        builder: (dialogContext, _) {
          void submit() {
            final state = form.currentState;
            if (state == null || !state.validate()) return;
            state.save();
            Navigator.of(dialogContext).pop(pageNumber);
          }

          return AppEditPanelForm(
            header: header,
            fields: Form(
              key: form,
              child: TextFormField(
                autofocus: true,
                contextMenuBuilder: buildAppEditableTextMenu,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.go,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: i18n.tr('my_history_page_number', {
                    'max': lastPage,
                  }),
                ),
                validator: (input) {
                  final page = int.tryParse(input ?? '');
                  return page != null && page >= 1 && page <= lastPage
                      ? null
                      : i18n.tr('my_history_invalid_page');
                },
                onSaved: (input) => pageNumber = int.tryParse(input ?? ''),
                onFieldSubmitted: (_) => submit(),
              ),
            ),
            cancelLabel: i18n.tr('cancel'),
            submitLabel: i18n.tr('confirm'),
            onCancel: () => Navigator.of(dialogContext).pop(),
            onSubmit: submit,
          );
        },
      );
      if (mounted && selected != null && selected != _page + 1) {
        await _goToPage(selected - 1);
      }
    } catch (error, stack) {
      _showPageLoadError(error, stack);
    } finally {
      if (mounted) setState(() => _choosingPage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    final localizations = MaterialLocalizations.of(context);
    final loading = _pendingPage != null;
    final canChangePage = !loading && !_choosingPage;
    final hasNext = _page < _lastLoadedPage || widget.hasMoreHistory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Column(
          key: _rowsKey,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry
                in widget.history.skip(_page * _pageSize).take(_pageSize))
              _HistoryWorkRow(
                key: ValueKey(entry.workKey),
                entry: entry,
                onOpen: widget.onOpen,
                onRemove: widget.onRemove,
              ),
          ],
        ),
        if (_page > 0 || hasNext)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: localizations.previousPageTooltip,
                style: appIconButtonStyle(),
                onPressed: _page > 0 && canChangePage
                    ? () => _goToPage(_page - 1)
                    : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Semantics(
                liveRegion: true,
                child: Tooltip(
                  message: i18n.tr('my_history_jump_to_page'),
                  child: TextButton(
                    style: appTextButtonStyle(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                    onPressed: canChangePage ? _choosePage : null,
                    child: Text(localizations.formatDecimal(_page + 1)),
                  ),
                ),
              ),
              IconButton(
                tooltip: localizations.nextPageTooltip,
                style: appIconButtonStyle(),
                onPressed: hasNext && canChangePage
                    ? () => _goToPage(_page + 1)
                    : null,
                icon: loading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
      ],
    );
  }
}

final _historyWorkTitleProvider = FutureProvider.autoDispose
    .family<String?, MusicTrack>((ref, track) async {
      final metadataTitle = track.remoteMetadata?['title']?.toString().trim();
      if (track.isRemoteAsmr) {
        return metadataTitle?.isNotEmpty == true
            ? metadataTitle
            : (track.groupTitle.trim().isEmpty ? null : track.groupTitle);
      }
      final displayMode = ref.watch(
        settingsStateProvider.select(
          (state) => state.value?.workNameDisplay ?? WorkNameDisplay.workTitle,
        ),
      );
      final library = ref.read(libraryFacadeProvider);
      final target = library.audioDetailTargetForTrack(track);
      final folderName = PathDisplay.folderName(target.targetPath);
      if (displayMode == WorkNameDisplay.folderName) return folderName;
      final detail = await ref.watch(
        libraryDetailForTargetProvider(target).future,
      );
      final title = detail.workTitle.trim();
      return title.isNotEmpty ? title : folderName;
    });

class _HistoryWorkRow extends ConsumerStatefulWidget {
  const _HistoryWorkRow({
    super.key,
    required this.entry,
    required this.onOpen,
    required this.onRemove,
  });

  static const double _minHeight = 52;
  static const double _coverWidth = 48;
  static const double coverHeight = 36;

  static double layoutHeight(BuildContext context) => FileTreeRow.layoutHeight(
    context,
    minHeight: _minHeight,
    titleMaxLines: 2,
  );
  static double coverInset(double rowHeight) => (rowHeight - coverHeight) / 2;

  final ListeningHistoryEntry entry;
  final Future<void> Function(MusicTrack track) onOpen;
  final Future<void> Function(String workKey) onRemove;

  @override
  ConsumerState<_HistoryWorkRow> createState() => _HistoryWorkRowState();
}

class _HistoryWorkRowState extends ConsumerState<_HistoryWorkRow> {
  Future<String?>? _coverFuture;
  Object? _coverFutureKey;

  Future<String?> _resolveCoverFuture(
    BuildContext context,
    String? initialPath,
  ) {
    final track = widget.entry.track;
    final key = (
      widget.entry.workKey,
      track.path,
      track.manualCoverPath,
      track.coverCachePath,
      track.remoteCoverUrl,
      initialPath,
    );
    final cached = _coverFuture;
    if (cached != null && _coverFutureKey == key) {
      return cached;
    }
    _coverFutureKey = key;
    return _coverFuture = ref
        .read(libraryCoverUiControllerProvider)
        .deferredPlaybackCover(track, context: context);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final library = ref.read(libraryFacadeProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final title =
        ref.watch(_historyWorkTitleProvider(entry.track)).value ??
        i18n.tr('my_untitled_work');
    final initialCoverPath = library.resolvedPlaybackCoverPathForTrack(
      entry.track,
    );
    final coverFuture = _resolveCoverFuture(context, initialCoverPath);
    final lastPlayedAt = entry.lastPlayedAt;
    final theme = Theme.of(context);
    final row = FileTreeRow(
      key: ValueKey('my-history-card-${entry.workKey}'),
      title: title,
      minHeight: _HistoryWorkRow._minHeight,
      titleMaxLines: 2,
      horizontalPadding: _HistoryWorkRow.coverInset(
        _HistoryWorkRow.layoutHeight(context),
      ),
      onTap: () => widget.onOpen(entry.track),
      trailing: lastPlayedAt == null
          ? null
          : Text(
              _formatHistoryTimestamp(lastPlayedAt),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      leading: SizedBox(
        width: _HistoryWorkRow._coverWidth,
        height: _HistoryWorkRow.coverHeight,
        child: CoverArtworkFrame(
          showShadow: false,
          child: AsyncLocalCoverImage(
            requestKey: entry.workKey,
            future: coverFuture,
            initialPath: initialCoverPath,
            fit: BoxFit.cover,
            deferLoadDuringInteraction: true,
            cacheWidth:
                (_HistoryWorkRow._coverWidth *
                        MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
          ),
        ),
      ),
    );
    if (ref.watch(listeningActivityServiceProvider) == null) return row;
    const shape = RoundedRectangleBorder(borderRadius: FileTreeRow.borderRadius);
    final label = i18n.tr('my_history_delete');
    void remove() => unawaited(widget.onRemove(entry.workKey));

    if (theme.platform == TargetPlatform.android) {
      return SwipeRevealCard(
        shape: shape,
        closedColor:
            theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
        onRemove: remove,
        actionLabel: label,
        removeTooltip: label,
        child: row,
      );
    }
    return UnifiedContextMenuRegion(
      shape: shape,
      skipTraversal: true,
      openOnWindowsLongPress: true,
      buildEntries: () => [
        UnifiedMenuEntry.action(
          value: remove,
          label: label,
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
      child: row,
    );
  }
}

String _formatHistoryTimestamp(DateTime timestamp) {
  final local = timestamp.toLocal();
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return time;
  }
  if (local.year == now.year) {
    return '${local.month}/${local.day} $time';
  }
  return '${local.year}/${local.month}/${local.day}';
}
