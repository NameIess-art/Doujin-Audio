import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/ui/undoable_removal_service.dart';
import '../../../core/ui/visual_settings_providers.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_entry_ink_well.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/work_listen_status_badge.dart';
import '../../asmr/presentation/asmr_download_page.dart';
import '../../settings/application/settings_state.dart';
import '../../settings/presentation/settings_providers.dart';
import '../application/lan_discovery_service.dart';
import '../domain/remote_media_source.dart';
import 'library_providers.dart';
import 'library_tab_empty_scan.dart';
import 'library_tab_tree_widgets.dart'
    show LibraryPinnedIndicator, LibrarySelectionIndicator;
import 'remote_library_work_detail.dart';

Future<void> showAddOrEditRemoteSourceDialog(
  BuildContext context, {
  RemoteMediaSource? existing,
  Future<List<LanDiscoveredServer>> Function() discoverLan =
      LanDiscoveryClient.discover,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (_) =>
        _RemoteSourceEditDialog(existing: existing, discoverLan: discoverLan),
  );
}

Future<void> showManageRemoteSourcesDialog(BuildContext context) {
  return showAppDialog<void>(
    context: context,
    builder: (_) => _ManageRemoteSourcesDialog(feedbackContext: context),
  );
}

sealed class _SourceMenuAction {
  const _SourceMenuAction();
}

final class _SelectLocalAction extends _SourceMenuAction {
  const _SelectLocalAction();
}

final class _SelectRemoteAction extends _SourceMenuAction {
  const _SelectRemoteAction(this.sourceId);
  final String sourceId;
}

final class _AddRemoteSourceAction extends _SourceMenuAction {
  const _AddRemoteSourceAction();
}

final class _EditActiveRemoteAction extends _SourceMenuAction {
  const _EditActiveRemoteAction(this.source);
  final RemoteMediaSource source;
}

final class _ManageRemoteSourcesAction extends _SourceMenuAction {
  const _ManageRemoteSourcesAction();
}

/// Circular 38x38 popup menu button placed at the top-right of [TopPageHeader]
/// Row 1 so switching between Local Library and any Remote Source (plus
/// editing/managing remote sources) works like the Add menu with zero extra bars.
class LibrarySourceMenuButton extends ConsumerWidget {
  const LibrarySourceMenuButton({super.key});

  Future<void> _selectRemoteSourceIfReachable(
    BuildContext context,
    WidgetRef ref,
    String sourceId,
  ) async {
    final controller = ref.read(remoteLibraryControllerProvider);
    final reachable = await controller.probeSourceConnection(sourceId);
    if (!reachable) {
      if (!context.mounted) return;
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        i18n.tr('remote_source_test_failed'),
        tone: AppFeedbackTone.destructive,
      );
      return;
    }
    controller.selectSource(sourceId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final controller = ref.watch(remoteLibraryControllerProvider);
    final sources = controller.sources;
    final selected = controller.selectedSource;
    final cs = Theme.of(context).colorScheme;

    final IconData buttonIcon = selected == null
        ? Icons.dns_rounded
        : (selected.isLan
              ? Icons.desktop_windows_rounded
              : Icons.cloud_done_rounded);

    Widget activeCheck() =>
        Icon(Icons.check_rounded, size: 18, color: cs.primary);

    Widget? trailingForSource(RemoteMediaSource source) {
      if (!controller.canEnterSource(source.id)) {
        return Icon(
          Icons.cloud_off_rounded,
          size: 16,
          color: cs.onSurface.withValues(alpha: 0.38),
        );
      }
      return selected?.id == source.id ? activeCheck() : null;
    }

    return UnifiedPopupMenuButton<_SourceMenuAction>(
      key: const ValueKey<String>('library_source_menu_button'),
      onOpened: () => unawaited(controller.probeAllSourcesConnection()),
      iconWidget: Icon(
        buttonIcon,
        size: 20,
        color: selected == null ? cs.onSurface : cs.primary,
      ),
      tooltip: i18n.tr('remote_source_manage'),
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 38, height: 38),
      entries: <UnifiedMenuEntry<_SourceMenuAction>>[
        UnifiedMenuEntry<_SourceMenuAction>.action(
          value: const _SelectLocalAction(),
          icon: Icons.library_music_rounded,
          label: i18n.tr('music_library'),
          trailing: selected == null ? activeCheck() : null,
        ),
        for (final source in sources)
          UnifiedMenuEntry<_SourceMenuAction>.action(
            value: _SelectRemoteAction(source.id),
            icon: source.isLan
                ? Icons.desktop_windows_rounded
                : Icons.cloud_outlined,
            label: source.name,
            enabled: controller.canEnterSource(source.id),
            trailing: trailingForSource(source),
          ),
        const UnifiedMenuEntry<_SourceMenuAction>.divider(),
        UnifiedMenuEntry<_SourceMenuAction>.action(
          value: const _AddRemoteSourceAction(),
          icon: Icons.add_rounded,
          label: i18n.tr('remote_source_add'),
        ),
        if (selected != null)
          UnifiedMenuEntry<_SourceMenuAction>.action(
            value: _EditActiveRemoteAction(selected),
            icon: Icons.edit_outlined,
            label: i18n.tr('remote_source_edit_title'),
          ),
        if (sources.isNotEmpty)
          UnifiedMenuEntry<_SourceMenuAction>.action(
            value: const _ManageRemoteSourcesAction(),
            icon: Icons.tune_rounded,
            label: i18n.tr('remote_source_manage'),
          ),
      ],
      onSelected: (action) {
        switch (action) {
          case _SelectLocalAction():
            controller.selectSource(null);
          case _SelectRemoteAction(:final sourceId):
            unawaited(_selectRemoteSourceIfReachable(context, ref, sourceId));
          case _AddRemoteSourceAction():
            unawaited(showAddOrEditRemoteSourceDialog(context));
          case _EditActiveRemoteAction(:final source):
            unawaited(
              showAddOrEditRemoteSourceDialog(context, existing: source),
            );
          case _ManageRemoteSourcesAction():
            unawaited(showManageRemoteSourcesDialog(context));
        }
      },
    );
  }
}

UndoableRemovalKey remoteWorkRemovalKey(RemoteLibraryWork work) =>
    UndoableRemovalKey('remote_library', work.uniqueKey);

Future<bool> stageRemoteWorkRemoval(
  BuildContext context,
  WidgetRef ref,
  RemoteLibraryWork work,
) async {
  final remoteController = ref.read(remoteLibraryControllerProvider);
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  final source = remoteController.sourceById(work.sourceId);
  if (source != null && source.isLan && !source.allowEdit) {
    showAppSnackBar(
      context,
      i18n.tr('remote_source_edit_disabled'),
      tone: AppFeedbackTone.warning,
    );
    return false;
  }
  return showUndoableRemovalFeedback(
    context,
    service: ref.read(undoableRemovalServiceProvider),
    action: UndoableRemovalAction(
      key: remoteWorkRemovalKey(work),
      commit: () => remoteController.commitRemoveWorks(work.sourceId, <String>[
        work.workId,
      ]),
      undo: () {},
    ),
    message: i18n.tr('folder_removed'),
    batchMessage: (count) => i18n.tr('items_removed_count', {'count': count}),
    undoLabel: i18n.tr('undo'),
    failureMessage: i18n.tr('removal_failed'),
  );
}

Future<void> stageRemoteBatchWorksRemoval({
  required BuildContext context,
  required WidgetRef ref,
  required List<RemoteLibraryWork> works,
  required VoidCallback exitSelectionMode,
}) async {
  if (works.isEmpty) return;
  final remoteController = ref.read(remoteLibraryControllerProvider);
  final source = remoteController.sourceById(works.first.sourceId);
  if (source != null && source.isLan && !source.allowEdit) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('remote_source_edit_disabled'),
      tone: AppFeedbackTone.warning,
    );
    return;
  }
  unawaited(
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.destructive),
  );
  exitSelectionMode();
  for (final work in works) {
    if (!context.mounted) break;
    await stageRemoteWorkRemoval(context, ref, work);
  }
}

Future<void> addRemoteBatchWorksToPlaylist({
  required BuildContext context,
  required WidgetRef ref,
  required List<RemoteLibraryWork> works,
  required VoidCallback exitSelectionMode,
}) async {
  if (works.isEmpty) return;
  unawaited(
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
  );
  final addedCount = await ref
      .read(remoteLibraryControllerProvider)
      .launchBatchWorksQueue(works);
  if (!context.mounted) return;
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  exitSelectionMode();
  showAppSnackBar(
    context,
    addedCount > 0
        ? i18n.tr('batch_added_to_playlist', {'count': addedCount.toString()})
        : i18n.tr('operation_failed_retry'),
    tone: addedCount > 0
        ? AppFeedbackTone.success
        : AppFeedbackTone.destructive,
    icon: addedCount > 0
        ? Icons.playlist_add_check_rounded
        : Icons.error_outline_rounded,
  );
}

Future<void> toggleRemoteBatchWorksPinned({
  required BuildContext context,
  required WidgetRef ref,
  required String sourceId,
  required List<String> workIds,
  required VoidCallback exitSelectionMode,
}) async {
  if (workIds.isEmpty) return;
  unawaited(
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
  );
  exitSelectionMode();
  try {
    await ref
        .read(remoteLibraryControllerProvider)
        .toggleWorksPinned(sourceId, workIds);
  } on HttpException catch (error) {
    if (!context.mounted) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final key = error.message.contains('remote_source_edit_disabled')
        ? 'remote_source_edit_disabled'
        : 'operation_failed_retry';
    showAppSnackBar(context, i18n.tr(key), tone: AppFeedbackTone.warning);
  } on Object {
    if (!context.mounted) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('operation_failed_retry'),
      tone: AppFeedbackTone.destructive,
    );
  }
}

List<RemoteLibraryWork> sortRemoteLibraryWorks(
  Iterable<RemoteLibraryWork> raw, {
  required LibrarySortCriterion criterion,
  required bool ascending,
}) {
  final sorted = List<RemoteLibraryWork>.of(raw);
  sorted.sort((a, b) {
    if (a.isPinned != b.isPinned) {
      return a.isPinned ? -1 : 1;
    }
    final int order = switch (criterion) {
      LibrarySortCriterion.voiceActor => compareNatural(
        a.voiceActors.join(','),
        b.voiceActors.join(','),
      ),
      LibrarySortCriterion.releaseDate => (a.releaseDateMs ?? 0).compareTo(
        b.releaseDateMs ?? 0,
      ),
      LibrarySortCriterion.addedAt ||
      LibrarySortCriterion.playbackTime => a.updatedAtMs.compareTo(
        b.updatedAtMs,
      ),
      LibrarySortCriterion.userRating => (a.userRating ?? a.rating ?? 0)
          .compareTo(b.userRating ?? b.rating ?? 0),
      LibrarySortCriterion.name => compareNatural(a.title, b.title),
    };
    final resolved = order != 0 ? order : compareNatural(a.title, b.title);
    return ascending ? resolved : -resolved;
  });
  return sorted;
}

List<RemoteLibraryWork> filterRemoteLibraryWorks(
  Iterable<RemoteLibraryWork> works, {
  required SearchElements elements,
  required SearchFilters filters,
}) {
  final allLower = <String>[for (final t in elements.all) t.toLowerCase()];
  final anyLower = <String>[for (final t in elements.any) t.toLowerCase()];

  bool matchesTerm(RemoteLibraryWork w, String term) {
    return w.title.toLowerCase().contains(term) ||
        w.folderName.toLowerCase().contains(term) ||
        w.rjCode.toLowerCase().contains(term) ||
        w.circleName.toLowerCase().contains(term) ||
        w.voiceActors.any((v) => v.toLowerCase().contains(term)) ||
        w.tags.any((t) => t.toLowerCase().contains(term));
  }

  return works.where((w) {
    if (allLower.any((t) => !matchesTerm(w, t))) return false;
    if (anyLower.isNotEmpty && !anyLower.any((t) => matchesTerm(w, t))) {
      return false;
    }
    if (filters.hasSubtitle != null && w.hasSubtitle != filters.hasSubtitle) {
      return false;
    }
    return matchesSearchMetadata(
      filters,
      rating: w.rating,
      userRating: w.userRating,
      listenStatus: WorkListenStatus.tryFromWireValue(w.listenStatus),
      duration: w.durationMs > 0 ? Duration(milliseconds: w.durationMs) : null,
      releaseDate: w.releaseDateMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(w.releaseDateMs!),
    );
  }).toList(growable: false);
}

Future<void> refreshRemoteSourceWithFeedback(
  BuildContext context,
  WidgetRef ref,
  String sourceId, {
  required bool syncProgress,
  bool showSuccessFeedback = true,
  bool showLoadingSnackbar = false,
}) async {
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  final primaryColor = Theme.of(context).colorScheme.primary;
  final controller = ref.read(remoteLibraryControllerProvider);
  final beforeWorks = List<RemoteLibraryWork>.of(controller.worksFor(sourceId));
  if (showLoadingSnackbar && context.mounted) {
    showAppSnackBar(
      context,
      i18n.tr('loading_dot'),
      icon: Icons.sync_rounded,
      iconColor: primaryColor,
    );
  }
  var syncChanged = false;
  try {
    final List<RemoteLibraryWork> afterWorks;
    if (syncProgress) {
      afterWorks = await controller.pullRefreshAndSync(
        sourceId,
        onSyncSummary: (summary) {
          if (summary.hasChanges) syncChanged = true;
        },
      );
    } else {
      afterWorks = await controller.refreshSource(sourceId);
    }
    if (!showSuccessFeedback || !context.mounted) return;
    final beforeById = <String, RemoteLibraryWork>{
      for (final work in beforeWorks) work.workId: work,
    };
    final afterIds = <String>{for (final work in afterWorks) work.workId};
    var addedCount = 0;
    var modified = false;
    for (final work in afterWorks) {
      final previous = beforeById[work.workId];
      if (previous == null) {
        addedCount++;
      } else if (!work.hasSameContent(previous)) {
        modified = true;
      }
    }
    final removedCount = beforeById.keys
        .where((id) => !afterIds.contains(id))
        .length;
    if (addedCount > 0) {
      showAppSnackBar(
        context,
        i18n.tr('remote_source_refresh_added', {'count': addedCount}),
        tone: AppFeedbackTone.success,
        icon: Icons.check_circle_outline_rounded,
      );
    } else if (removedCount > 0 || modified || syncChanged) {
      showAppSnackBar(
        context,
        i18n.tr('remote_source_refresh_updated'),
        tone: AppFeedbackTone.success,
        icon: Icons.sync_rounded,
      );
    } else {
      showAppSnackBar(
        context,
        i18n.tr('remote_source_refresh_no_changes'),
        icon: Icons.check_circle_outline_rounded,
        iconColor: primaryColor,
      );
    }
  } on Object catch (error) {
    if (!context.mounted) return;
    final isAuth =
        error is HttpException &&
        error.message.contains('remote_source_unauthorized');
    showAppSnackBar(
      context,
      i18n.tr(
        isAuth ? 'remote_source_auth_failed' : 'remote_source_load_failed',
      ),
      tone: AppFeedbackTone.destructive,
    );
  }
}

class RemoteLibraryBrowseView extends ConsumerStatefulWidget {
  const RemoteLibraryBrowseView({
    super.key,
    required this.source,
    required this.scrollController,
    required this.topPadding,
    required this.bottomPadding,
    this.isSelectionMode = false,
    this.selectedWorkIds = const <String>{},
    this.onEnterSelectionMode,
    this.onToggleSelection,
  });

  final RemoteMediaSource source;
  final ScrollController scrollController;
  final double topPadding;
  final double bottomPadding;
  final bool isSelectionMode;
  final Set<String> selectedWorkIds;
  final ValueChanged<RemoteLibraryWork>? onEnterSelectionMode;
  final ValueChanged<RemoteLibraryWork>? onToggleSelection;

  @override
  ConsumerState<RemoteLibraryBrowseView> createState() =>
      _RemoteLibraryBrowseViewState();
}

class _RemoteLibraryBrowseViewState
    extends ConsumerState<RemoteLibraryBrowseView> {
  final GlobalKey<GlassRefreshIndicatorState> _refreshKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeLoadInitialCatalog();
    });
  }

  @override
  void didUpdateWidget(covariant RemoteLibraryBrowseView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.id != widget.source.id) {
      _maybeLoadInitialCatalog();
    }
  }

  void _maybeLoadInitialCatalog() {
    final ctrl = ref.read(remoteLibraryControllerProvider);
    if (!ctrl.hasLoadedCatalog(widget.source.id) &&
        !ctrl.isLoading(widget.source.id) &&
        ctrl.errorFor(widget.source.id) == null) {
      unawaited(_loadCatalog(syncProgress: false, showSuccessFeedback: false));
    }
  }

  Future<void> _refresh() => _loadCatalog(syncProgress: true);

  Future<void> _loadCatalog({
    required bool syncProgress,
    bool showSuccessFeedback = true,
  }) => refreshRemoteSourceWithFeedback(
    context,
    ref,
    widget.source.id,
    syncProgress: syncProgress,
    showSuccessFeedback: showSuccessFeedback,
  );

  Widget _buildCard(RemoteLibraryWork work) {
    return RemoteWorkCardTile(
      work: work,
      isSelectionMode: widget.isSelectionMode,
      isSelected: widget.selectedWorkIds.contains(work.workId),
      onLongPress: widget.onEnterSelectionMode == null
          ? null
          : () => widget.onEnterSelectionMode!(work),
      onToggleSelect: widget.onToggleSelection == null
          ? null
          : () => widget.onToggleSelection!(work),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final sourceId = widget.source.id;
    final activeSource = ref.watch(
      remoteLibraryControllerProvider.select(
        (c) => c.sourceById(sourceId) ?? widget.source,
      ),
    );
    final sourceWorks = ref.watch(
      remoteLibraryControllerProvider.select((c) => c.worksFor(sourceId)),
    );
    final hasLoadedCatalog = ref.watch(
      remoteLibraryControllerProvider.select(
        (c) => c.hasLoadedCatalog(sourceId),
      ),
    );
    final error = ref.watch(
      remoteLibraryControllerProvider.select((c) => c.errorFor(sourceId)),
    );
    final removals = ref.watch(undoableRemovalStateProvider);
    final settings = ref.watch(settingsStateProvider).value;
    final rawWorks = sourceWorks.where(
      (w) => !removals.isHidden(remoteWorkRemovalKey(w)),
    );
    final works = sortRemoteLibraryWorks(
      rawWorks,
      criterion: settings?.librarySortCriterion ?? LibrarySortCriterion.name,
      ascending: settings?.librarySortAscending ?? true,
    );
    final cs = Theme.of(context).colorScheme;
    final initialLoading = !hasLoadedCatalog && error == null;

    final errorLabelKey =
        error is HttpException &&
            error.message.contains('remote_source_unauthorized')
        ? 'remote_source_auth_failed'
        : 'remote_source_load_failed';

    return AppPageContentTransition.deferred(
      prepared: !initialLoading,
      isReady: !initialLoading,
      holdPlaceholder: initialLoading,
      animatePlaceholder: true,
      placeholder: LibraryLoadingSkeleton(
        bottomInset: widget.bottomPadding,
        topInset: widget.topPadding,
      ),
      builder: (_) => GlassRefreshIndicator(
        key: _refreshKey,
        lockChildWhileRefreshing: true,
        color: cs.primary,
        backgroundColor: cs.surfaceContainerHighest,
        edgeOffset: widget.topPadding,
        displacement: 32,
        triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
        onRefresh: _refresh,
        child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = responsiveLibraryCardColumnCount(
                  constraints.maxWidth -
                      LibraryLikeCardMetrics.listHorizontalPadding * 2,
                );
                final rowCount = columns <= 1
                    ? works.length
                    : (works.length + columns - 1) ~/ columns;
                final physics = AlwaysScrollableScrollPhysics(
                  parent: GlassRefreshIndicatorScrollPhysics(
                    isIndicatorVisible: () =>
                        _refreshKey.currentState?.isIndicatorVisible ?? false,
                  ),
                );

                if (works.isEmpty) {
                  final availableHeight =
                      constraints.maxHeight -
                      widget.topPadding -
                      widget.bottomPadding;
                  return ListView(
                    controller: widget.scrollController,
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.xl,
                      widget.topPadding,
                      AppSpacing.xl,
                      widget.bottomPadding,
                    ),
                    physics: physics,
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: availableHeight > 0 ? availableHeight : 0,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 520),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.xl,
                                vertical: 40,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: AppRadius.borderDialog,
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    cs.surfaceContainerHigh.withValues(
                                      alpha: 0.6,
                                    ),
                                    cs.surfaceContainerLow.withValues(
                                      alpha: 0.4,
                                    ),
                                  ],
                                ),
                                border: Border.all(
                                  color: cs.outlineVariant.withValues(
                                    alpha: 0.1,
                                  ),
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    error != null
                                        ? Icons.cloud_off_rounded
                                        : (activeSource.isLan
                                              ? Icons.desktop_windows_rounded
                                              : Icons.cloud_outlined),
                                    size: 40,
                                    color: error != null
                                        ? cs.error
                                        : cs.primary,
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  Text(
                                    i18n.tr(
                                      error != null
                                          ? errorLabelKey
                                          : 'remote_source_empty',
                                    ),
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    alignment: WrapAlignment.center,
                                    children: [
                                      AppPillButton(
                                        style: FilledButton.styleFrom(
                                          minimumSize: const Size(96, 42),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 20,
                                          ),
                                        ),
                                        onPressed: _refresh,
                                        child: Text(i18n.tr('retry')),
                                      ),
                                      AppPillButton(
                                        style: FilledButton.styleFrom(
                                          minimumSize: const Size(96, 42),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 20,
                                          ),
                                        ),
                                        onPressed: () =>
                                            showAddOrEditRemoteSourceDialog(
                                              context,
                                              existing: activeSource,
                                            ),
                                        child: Text(i18n.tr('edit')),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }

                return CustomScrollView(
                  controller: widget.scrollController,
                  cacheExtent: 320,
                  physics: physics,
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        LibraryLikeCardMetrics.listHorizontalPadding,
                        widget.topPadding,
                        LibraryLikeCardMetrics.listHorizontalPadding,
                        widget.bottomPadding,
                      ),
                      sliver: SliverFixedExtentList.builder(
                        itemExtent: LibraryLikeCardMetrics.rootTileHeight,
                        itemCount: rowCount,
                        itemBuilder: (context, rowIndex) {
                          if (columns <= 1) {
                            return _buildCard(works[rowIndex]);
                          }
                          final start = rowIndex * columns;
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var col = 0; col < columns; col++) ...[
                                if (col > 0)
                                  const SizedBox(
                                    width: kResponsiveLibraryCardSpacing,
                                  ),
                                Expanded(
                                  child: start + col < works.length
                                      ? _buildCard(works[start + col])
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
      ),
    );
  }
}

/// Renders a [RemoteLibraryWork] with the exact same surface, padding,
/// [CoverArtworkFrame] + [DurationOverlay] + [WorkListenStatusBadge], metadata
/// lines, and [LibraryLikeCardActions] as local [RootFolderCardContent].
class RemoteWorkCardTile extends ConsumerWidget {
  const RemoteWorkCardTile({
    super.key,
    required this.work,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onToggleSelect,
  });

  final RemoteLibraryWork work;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  Future<void> _downloadWork(BuildContext context, WidgetRef ref) async {
    final ctrl = ref.read(remoteLibraryControllerProvider);
    final synthetic = RemoteLibraryWorkDetail.buildDownloadableWork(work);
    await Navigator.of(context).push<AsmrDownloadPageResult>(
      buildAppPageRoute<AsmrDownloadPageResult>(
        context: context,
        child: AsmrDownloadPage(
          work: synthetic,
          customTreeLoader: () => ctrl.ensureWorkTree(work),
        ),
      ),
    );
  }

  Future<void> _togglePin(BuildContext context, WidgetRef ref) async {
    try {
      await ref
          .read(remoteLibraryControllerProvider)
          .toggleWorksPinned(work.sourceId, <String>[work.workId]);
    } on HttpException catch (error) {
      if (!context.mounted) return;
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      final key = error.message.contains('remote_source_edit_disabled')
          ? 'remote_source_edit_disabled'
          : 'operation_failed_retry';
      showAppSnackBar(context, i18n.tr(key), tone: AppFeedbackTone.warning);
    } on Object {
      if (!context.mounted) return;
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        i18n.tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
      );
    }
  }

  Future<void> _openDetailIfReachable(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final ctrl = ref.read(remoteLibraryControllerProvider);
    final reachable = await ctrl.probeSourceConnection(work.sourceId);
    if (!context.mounted) return;
    if (!reachable) {
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        i18n.tr('remote_source_test_failed'),
        tone: AppFeedbackTone.destructive,
      );
      return;
    }
    await openRemoteLibraryWorkDetail(context, work);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHidden = ref.watch(
      isUndoableRemovalHiddenProvider(remoteWorkRemovalKey(work)),
    );
    final isOffline = ref.watch(
      remoteLibraryControllerProvider.select(
        (c) => c.isSourceOffline(work.sourceId),
      ),
    );
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    final remoteController = ref.read(remoteLibraryControllerProvider);
    final displayMode = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.workNameDisplay ?? WorkNameDisplay.workTitle,
      ),
    );
    final resolution = ref.watch(coverImageResolutionProvider);
    final cs = Theme.of(context).colorScheme;
    final coverUrl = work.coverUrl;
    final status = WorkListenStatus.tryFromWireValue(work.listenStatus);
    final duration = Duration(milliseconds: work.durationMs);

    final displayTitle =
        displayMode == WorkNameDisplay.folderName &&
            work.folderName.trim().isNotEmpty
        ? work.folderName.trim()
        : work.title;

    Widget buildCover(double coverWidth) {
      final coverCacheWidth = coverThumbnailCacheWidth(
        logicalWidth: coverWidth,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        resolution: resolution,
      );
      final Widget rawCover;
      if (coverUrl == null || coverUrl.isEmpty) {
        rawCover = const CoverFallbackArtwork();
      } else {
        final (coverRevision, resolvedPath) = ref.watch(
          coverGenerationProvider.select(
            (_) => (
              libraryFacade.coverArtworkCacheService.revisionForScope(coverUrl),
              libraryFacade.resolvedCoverPathForRemoteCover(coverUrl),
            ),
          ),
        );
        final coverFuture = resolvedPath != null
            ? Future<String?>.value(resolvedPath)
            : libraryFacade.coverPathFutureForRemoteCover(coverUrl);
        rawCover = AsyncRemoteCoverImage(
          key: ValueKey<String>('remote_card_cover_${coverUrl}_$coverRevision'),
          url: coverUrl,
          initialPath: resolvedPath,
          future: coverFuture,
          retryFutureBuilder: () =>
              libraryFacade.coverPathFutureForRemoteCover(coverUrl),
          onImageError:
              libraryFacade.coverArtworkCacheService.reportArtworkReadFailure,
          fallbackBuilder: (_) => const CoverFallbackArtwork(),
          cacheWidth: coverCacheWidth,
          useDefaultCacheWidth: false,
          deferLoadDuringInteraction: true,
          browseThumbnail: true,
          fit: BoxFit.cover,
        );
      }

      return SizedBox(
        width: coverWidth,
        height: LibraryLikeCardMetrics.coverHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SizedBox(
              width: coverWidth,
              height: LibraryLikeCardMetrics.coverHeight,
              child: CoverArtworkFrame(
                clipBehavior: Clip.hardEdge,
                showShadow: false,
                showBorder: true,
                borderRadius: BorderRadius.circular(
                  LibraryLikeCardMetrics.coverRadius,
                ),
                child: rawCover,
              ),
            ),
            if (status != null)
              Positioned(
                left: 4,
                top: 4,
                child: WorkListenStatusBadge(
                  status: status,
                  label: i18n.tr(workListenStatusTranslationKey(status)),
                ),
              ),
            if (duration > Duration.zero)
              Positioned(
                left: 4,
                bottom: 4,
                child: DurationOverlay(duration: duration),
              ),
            Positioned(
              right: -2,
              bottom: -2,
              child: LibrarySelectionIndicator(
                path: work.uniqueKey,
                isSelected: isSelected,
              ),
            ),
            Positioned(
              right: -2,
              top: -2,
              child: LibraryPinnedIndicator(
                isPinned: work.isPinned,
                path: work.uniqueKey,
              ),
            ),
          ],
        ),
      );
    }

    final actions = LibraryLikeCardActions(
      addLabel: i18n.tr('add'),
      playLabel: i18n.tr('play'),
      onAdd: isSelectionMode || isOffline
          ? null
          : () => unawaited(remoteController.launchWorkQueue(work)),
      onPlay: isSelectionMode || isOffline
          ? null
          : () => unawaited(remoteController.playWork(work)),
    );

    final tileContent = Material(
      color: Colors.transparent,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      child: AppEntryInkWell(
        customBorder: LibraryLikeCardMetrics.cardShape,
        canRequestFocus: isSelectionMode && !isOffline,
        onLongPress: isOffline ? null : onLongPress,
        onTap: isOffline
            ? null
            : (isSelectionMode
                  ? onToggleSelect
                  : () => unawaited(_openDetailIfReachable(context, ref))),
        child: ListTile(
          contentPadding: LibraryLikeCardMetrics.rootTilePadding,
          minTileHeight: LibraryLikeCardMetrics.rootTileHeight,
          shape: LibraryLikeCardMetrics.cardShape,
          title: LibraryLikeMetadataWorkCardContent(
            title: displayTitle,
            metadata: LibraryLikeInfoMetadata(
              voiceActors: work.voiceActors,
              circleName: work.circleName,
              workCode: work.rjCode,
              tags: work.tags,
              releaseDate: work.releaseDateMs == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(work.releaseDateMs!),
              rating: work.rating,
              userRating: work.userRating,
              hasReviewNote: work.hasReviewNote,
            ),
            voiceActorLabel: i18n.tr('card_info_voice_actors'),
            circleLabel: i18n.tr('library_category_circles'),
            tagsLabel: i18n.tr('library_category_tags'),
            releaseDateLabel: i18n.tr('card_info_release_date'),
            ratingLabel: i18n.tr('card_info_rating'),
            userRatingLabel: i18n.tr('work_user_rating'),
            reviewNoteLabel: i18n.tr('work_review_note'),
            coverBuilder: buildCover,
            trailingActions: actions,
          ),
        ),
      ),
    );
    final tile = isOffline
        ? Opacity(opacity: 0.45, child: tileContent)
        : tileContent;

    final card = SwipeRevealCard(
      key: ValueKey('remote_work_${work.uniqueKey}'),
      onSelectMultiple: isOffline ? null : onLongPress,
      selectMultipleLabel: i18n.tr('select_multiple'),
      shape: LibraryLikeCardMetrics.cardShape,
      swipeEnabled: false,
      enabled: !isSelectionMode && !isOffline,
      closedColor: cs.surface,
      onLeadingAction: () => unawaited(_togglePin(context, ref)),
      leadingActionLabel: i18n.tr(
        work.isPinned ? 'unpin_from_top' : 'pin_to_top',
      ),
      leadingActionTooltip: i18n.tr(
        work.isPinned ? 'unpin_from_top' : 'pin_to_top',
      ),
      leadingActionIcon: Icons.push_pin_rounded,
      leadingActionIconWidget: work.isPinned ? const PushPinOffIcon() : null,
      onSecondaryLeadingAction: () =>
          unawaited(openRemoteWorkReviewEditor(context, ref, work)),
      secondaryLeadingActionLabel: i18n.tr('work_review_action'),
      secondaryLeadingActionTooltip: i18n.tr('work_review_action'),
      secondaryLeadingActionIcon: Icons.rate_review_rounded,
      onSecondaryAction: () => unawaited(_downloadWork(context, ref)),
      secondaryActionLabel: i18n.tr('download'),
      secondaryActionIcon: Icons.download_rounded,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio_folder'),
      onRemove: () => stageRemoteWorkRemoval(context, ref, work),
      child: tile,
    );

    return UndoableRemovalTransition(hidden: isHidden, child: card);
  }
}

class _RemoteSourceEditDialog extends ConsumerStatefulWidget {
  const _RemoteSourceEditDialog({this.existing, required this.discoverLan});

  final RemoteMediaSource? existing;
  final Future<List<LanDiscoveredServer>> Function() discoverLan;

  @override
  ConsumerState<_RemoteSourceEditDialog> createState() =>
      _RemoteSourceEditDialogState();
}

class _RemoteSourceEditDialogState
    extends ConsumerState<_RemoteSourceEditDialog> {
  late RemoteMediaSourceType _type;
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  final TextEditingController _secretController = TextEditingController();

  bool _discovering = false;
  bool _testing = false;
  bool _saving = false;
  bool _obscureSecret = true;
  List<LanDiscoveredServer> _discovered = const <LanDiscoveredServer>[];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _type = existing?.type ?? RemoteMediaSourceType.windowsLan;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _urlController = TextEditingController(text: existing?.baseUrl ?? '');
    _usernameController = TextEditingController(text: existing?.username ?? '');
    if (existing == null && _type == RemoteMediaSourceType.windowsLan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_discoverLan());
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _discoverLan() async {
    if (_discovering) return;
    setState(() => _discovering = true);
    try {
      final list = await widget.discoverLan();
      if (mounted) setState(() => _discovered = list);
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  void _applyDiscovered(LanDiscoveredServer server) {
    setState(() {
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = server.name;
      }
      _urlController.text = server.baseUrl;
    });
  }

  Future<void> _testConnection() async {
    if (_testing || _saving) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isEmpty) return;
    setState(() => _testing = true);
    try {
      await ref
          .read(remoteLibraryControllerProvider)
          .testConnection(
            type: _type,
            baseUrl: rawUrl,
            username: _usernameController.text.trim(),
            secret: _secretController.text.isEmpty
                ? null
                : _secretController.text,
            existingSourceId: widget.existing?.id,
          );
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('remote_source_test_success'),
        tone: AppFeedbackTone.success,
      );
    } on Object catch (error) {
      if (!mounted) return;
      final isAuth =
          error is HttpException &&
          error.message.contains('remote_source_unauthorized');
      showAppSnackBar(
        context,
        i18n.tr(
          isAuth ? 'remote_source_auth_failed' : 'remote_source_test_failed',
        ),
        tone: AppFeedbackTone.destructive,
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _testing) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isEmpty) return;
    setState(() => _saving = true);
    try {
      final ctrl = ref.read(remoteLibraryControllerProvider);
      final saved = await ctrl.addOrUpdateSource(
        id: widget.existing?.id,
        type: _type,
        name: _nameController.text.trim(),
        baseUrl: rawUrl,
        username: _usernameController.text.trim(),
        secret: _secretController.text.isEmpty ? null : _secretController.text,
      );
      final reachable = await ctrl.probeSourceConnection(saved.id);
      if (reachable) {
        ctrl.selectSource(saved.id);
      } else if (mounted) {
        showAppSnackBar(
          context,
          i18n.tr('remote_source_test_failed'),
          tone: AppFeedbackTone.destructive,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } on Object {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('network_invalid_value'),
        tone: AppFeedbackTone.destructive,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final isEditing = widget.existing != null;
    final tokens = AppDesignTokens.of(context);

    return AppDialog(
      title: i18n.tr(
        isEditing ? 'remote_source_edit_title' : 'remote_source_add_title',
      ),
      icon: Icons.lan_rounded,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!isEditing)
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      showCheckmark: false,
                      label: Text(i18n.tr('remote_source_type_lan')),
                      selected: _type == RemoteMediaSourceType.windowsLan,
                      onSelected: (_) {
                        setState(
                          () => _type = RemoteMediaSourceType.windowsLan,
                        );
                        if (_discovered.isEmpty) unawaited(_discoverLan());
                      },
                    ),
                    ChoiceChip(
                      showCheckmark: false,
                      label: const Text('WebDAV'),
                      selected: _type == RemoteMediaSourceType.webDav,
                      onSelected: (_) =>
                          setState(() => _type = RemoteMediaSourceType.webDav),
                    ),
                  ],
                ),
              if (_type == RemoteMediaSourceType.windowsLan) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: AppSpacing.xs,
                  children: [
                    TextButton.icon(
                      onPressed: _discovering ? null : _discoverLan,
                      icon: _discovering
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.radar_rounded, size: 16),
                      label: Text(i18n.tr('remote_source_discover')),
                    ),
                    if (_discovered.isNotEmpty)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: AppSpacing.xxs,
                          children: [
                            for (final server in _discovered)
                              ActionChip(
                                avatar: Icon(
                                  Icons.desktop_windows_rounded,
                                  size: 15,
                                  color: tokens.success,
                                ),
                                label: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      server.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (server.host != server.name)
                                      Text(
                                        server.host,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                                tooltip: '${server.name} (${server.baseUrl})',
                                onPressed: () => _applyDiscovered(server),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                contextMenuBuilder: buildAppEditableTextMenu,
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: i18n.tr('remote_source_name'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                contextMenuBuilder: buildAppEditableTextMenu,
                controller: _urlController,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: i18n.tr(
                    _type == RemoteMediaSourceType.windowsLan
                        ? 'remote_source_lan_address'
                        : 'remote_source_webdav_url',
                  ),
                  hintText: _type == RemoteMediaSourceType.windowsLan
                      ? 'http://192.168.1.10:42871'
                      : 'http://192.168.1.20:5244/dav/Audio',
                ),
              ),
              if (_type == RemoteMediaSourceType.webDav) ...[
                const SizedBox(height: 12),
                TextField(
                  contextMenuBuilder: buildAppEditableTextMenu,
                  controller: _usernameController,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: i18n.tr('network_proxy_username'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                contextMenuBuilder: buildAppEditableTextMenu,
                controller: _secretController,
                obscureText: _obscureSecret,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: i18n.tr(
                    _type == RemoteMediaSourceType.windowsLan
                        ? 'remote_source_access_code'
                        : 'network_proxy_password',
                  ),
                  hintText: widget.existing?.secretConfigured == true
                      ? i18n.tr('network_password_keep')
                      : null,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureSecret
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _obscureSecret = !_obscureSecret),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: AppDialogActions(
        leading: AppConnectionTestButton(
          tooltip: i18n.tr('network_test'),
          onPressed: _saving ? null : _testConnection,
          isTesting: _testing,
        ),
        children: [
          AppSecondaryButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            label: i18n.tr('cancel'),
          ),
          AppPrimaryButton(
            onPressed: _saving ? null : _save,
            label: i18n.tr('confirm'),
          ),
        ],
      ),
    );
  }
}

class _ManageRemoteSourcesDialog extends ConsumerWidget {
  const _ManageRemoteSourcesDialog({required this.feedbackContext});

  final BuildContext feedbackContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final controller = ref.watch(remoteLibraryControllerProvider);
    final sources = controller.sources;
    final cs = Theme.of(context).colorScheme;

    return AppDialog(
      title: i18n.tr('remote_source_manage'),
      icon: Icons.lan_rounded,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 360),
        child: sources.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(i18n.tr('remote_source_empty')),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: sources.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final source = sources[index];

                  void editSource() {
                    Navigator.of(context).pop();
                    unawaited(
                      showAddOrEditRemoteSourceDialog(context, existing: source),
                    );
                  }

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    shape: const RoundedRectangleBorder(
                      borderRadius: AppRadius.borderMedium,
                    ),
                    onTap: editSource,
                    leading: Icon(
                      source.isLan
                          ? Icons.desktop_windows_rounded
                          : Icons.cloud_outlined,
                      color: cs.primary,
                    ),
                    title: Text(source.name),
                    subtitle: Text(
                      source.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: i18n.tr('edit'),
                          icon: const Icon(Icons.edit_outlined, size: 19),
                          onPressed: editSource,
                        ),
                        IconButton(
                          tooltip: i18n.tr('delete'),
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 19,
                            color: cs.error,
                          ),
                          onPressed: () => showUndoableRemovalFeedback(
                            feedbackContext.mounted ? feedbackContext : context,
                            overlay: Overlay.of(context, rootOverlay: true),
                            service: ref.read(undoableRemovalServiceProvider),
                            action: UndoableRemovalAction(
                              key: UndoableRemovalKey(
                                'remote_source',
                                source.id,
                              ),
                              prepare: () =>
                                  controller.stageSourceRemoval(source.id),
                              commit: () => controller.removeSource(source.id),
                              undo: () =>
                                  controller.cancelSourceRemoval(source.id),
                            ),
                            message: i18n.tr('removed_prefix', {
                              'name': source.name,
                            }),
                            batchMessage: (count) =>
                                i18n.tr('items_removed_count', {'count': count}),
                            undoLabel: i18n.tr('undo'),
                            failureMessage: i18n.tr('removal_failed'),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: AppDialogActions(
        children: [
          AppSecondaryButton(
            onPressed: () => Navigator.of(context).pop(),
            label: i18n.tr('close'),
          ),
          AppPrimaryButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(showAddOrEditRemoteSourceDialog(context));
            },
            label: i18n.tr('add'),
          ),
        ],
      ),
    );
  }
}
