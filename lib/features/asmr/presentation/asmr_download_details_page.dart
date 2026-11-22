import 'asmr_download_format.dart';
import 'asmr_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../domain/asmr_models.dart';
import '../application/asmr_download_models.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/ui/undoable_removal_service.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_entry_ink_well.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/file_tree_expansion_motion.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';

class AsmrDownloadDetailsPage extends ConsumerStatefulWidget {
  const AsmrDownloadDetailsPage({super.key, required this.workId});

  final String workId;

  @override
  ConsumerState<AsmrDownloadDetailsPage> createState() =>
      _AsmrDownloadDetailsPageState();
}

typedef _DownloadDetailsRow = ({
  AsmrTrackFile node,
  int depth,
  bool emptyFolder,
});

class _AsmrDownloadDetailsPageState
    extends ConsumerState<AsmrDownloadDetailsPage>
    with SingleTickerProviderStateMixin {
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 0;
  bool _headerMeasurementScheduled = false;
  Object? _lastHeaderLayoutKey;
  final Set<String> _collapsedPaths = {};
  List<AsmrTrackFile>? _rowsSource;
  List<_DownloadDetailsRow> _rows = const [];
  Map<Key, int> _rowIndices = const {};
  late final FileTreeExpansionMotion<String, _DownloadDetailsRow> _motion;

  @override
  void initState() {
    super.initState();
    _motion = FileTreeExpansionMotion(this, () {
      if (mounted) setState(_motion.finish);
    });
  }

  void _toggleFolder(String path) {
    setState(() {
      final progress = _motion.progressFor(path);
      _motion.finish();
      final opening = _collapsedPaths.remove(path);
      if (!opening) _collapsedPaths.add(path);
      final outgoing = opening ? null : _rows;
      _rowsSource = null;
      if (!MediaQuery.disableAnimationsOf(context)) {
        _motion.start(path, outgoing: outgoing, from: progress);
      }
    });
  }

  Key _rowKey(_DownloadDetailsRow row) => ValueKey<String>(
    'asmr_download_${row.emptyFolder ? "empty" : "node"}_row_${row.node.relativePath}',
  );

  Map<Key, int> _indicesFor(List<_DownloadDetailsRow> rows) => {
    for (var index = 0; index < rows.length; index++)
      _rowKey(rows[index]): index,
  };

  void _ensureRows(List<AsmrTrackFile> roots) {
    if (identical(_rowsSource, roots)) return;
    if (_rowsSource != null) _motion.finish();
    final rows = <_DownloadDetailsRow>[];
    void visit(AsmrTrackFile node, int depth) {
      rows.add((node: node, depth: depth, emptyFolder: false));
      if (!node.isFolder || _collapsedPaths.contains(node.relativePath)) return;
      if (node.children.isEmpty) {
        rows.add((node: node, depth: depth, emptyFolder: true));
      } else {
        for (final child in node.children) {
          visit(child, depth + 1);
        }
      }
    }

    for (final root in japaneseAsmrContentRoots(roots)) {
      visit(root, 0);
    }
    _rowsSource = roots;
    _rows = rows;
    _rowIndices = _indicesFor(rows);
  }

  @override
  void didUpdateWidget(covariant AsmrDownloadDetailsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workId != widget.workId) {
      _motion.finish();
      _collapsedPaths.clear();
      _rowsSource = null;
      _rows = const [];
      _rowIndices = const {};
      _headerHeight = 0;
      _lastHeaderLayoutKey = null;
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  void _scheduleHeaderMeasurement(Object layoutKey) {
    if (_headerHeight > 0 && _lastHeaderLayoutKey == layoutKey) return;
    _lastHeaderLayoutKey = layoutKey;
    if (_headerMeasurementScheduled) return;
    _headerMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _headerMeasurementScheduled = false;
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      final h = box.size.height;
      if (h > 0 && (_headerHeight == 0 || (h - _headerHeight).abs() > 0.5)) {
        setState(() => _headerHeight = h);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final structure = ref.watch(
      asmrDownloadTaskProvider(widget.workId).select(
        (task) => task == null
            ? null
            : (title: task.work.title, roots: task.selectedRoots),
      ),
    );
    final downloadManager = ref.read(asmrDownloadManagerProvider);
    final coreReady = ref.watch(coreRuntimeReadyProvider);
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);

    if (structure == null) {
      _motion.finish();
      _rowsSource = null;
      _rows = const [];
      _rowIndices = const {};
      _collapsedPaths.clear();
      final contentTopInset = AppPageHeaderMetrics.contentTopInset(context);
      return Scaffold(
        backgroundColor: cs.surface,
        body: PageHeaderInset(
          topInset: contentTopInset,
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(
                    top: contentTopInset,
                    bottom:
                        MediaQuery.paddingOf(context).bottom +
                        MobileOverlayInset.of(context),
                  ),
                  child: AppPageContentTransition(
                    child: AppEmptyState(
                      icon: Icons.info_outline_rounded,
                      title: i18n.tr('asmr_download_task_not_found'),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: TopPageHeader(
                  icon: Icons.info_outline_rounded,
                  iconColor: cs.primary,
                  leading: const AppHeaderBackButton(),
                  title: i18n.tr('asmr_download_details_title'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final tracks = structure.roots;
    final mediaTopPadding = MediaQuery.paddingOf(context).top;

    _scheduleHeaderMeasurement((
      structure.title,
      MediaQuery.sizeOf(context).width,
      mediaTopPadding,
      MediaQuery.textScalerOf(context),
      i18n.language,
    ));

    final defaultHeaderHeight = mediaTopPadding + 140.0;
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : defaultHeaderHeight;
    final listTopPadding =
        effectiveHeaderHeight + AppPageHeaderMetrics.firstContentSpacing;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: PageHeaderInset(
        topInset: listTopPadding,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition.deferred(
                placeholder: FileTreeSkeleton(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    listTopPadding,
                    16,
                    MediaQuery.paddingOf(context).bottom +
                        MobileOverlayInset.of(context) +
                        16,
                  ),
                ),
                builder: (context) {
                  _ensureRows(tracks);
                  final rows = _motion.project(
                    context,
                    _rows,
                    parentIndex: (_, path) =>
                        _rowIndices[ValueKey<String>(
                          'asmr_download_node_row_$path',
                        )],
                    // An empty notice aligns with its header, but moves as a child.
                    depth: (row) => row.depth + (row.emptyFolder ? 1 : 0),
                    minRowHeight: 28,
                  );
                  final indices = identical(rows, _rows)
                      ? _rowIndices
                      : _indicesFor(rows);
                  return CustomScrollView(
                    physics: const ClampingScrollPhysics(),
                    slivers: [
                      if (tracks.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Padding(
                            padding: EdgeInsets.only(
                              top: listTopPadding,
                              bottom:
                                  MediaQuery.paddingOf(context).bottom +
                                  MobileOverlayInset.of(context),
                            ),
                            child: AppEmptyState(
                              icon: Icons.folder_open_rounded,
                              title: i18n.tr('asmr_download_no_files_selected'),
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            listTopPadding,
                            16,
                            MediaQuery.paddingOf(context).bottom +
                                MobileOverlayInset.of(context) +
                                16,
                          ),
                          sliver: SliverList.builder(
                            itemCount: rows.length,
                            findChildIndexCallback: (key) => indices[key],
                            itemBuilder: (context, index) {
                              final row = rows[index];
                              final node = row.node;
                              final Widget tile;
                              if (row.emptyFolder) {
                                tile = FileTreeRow(
                                  title: i18n.tr('asmr_download_empty_folder'),
                                  depth: row.depth,
                                  minHeight: 28,
                                  leading: const SizedBox(
                                    width: AppDesignTokens.fileEntryIconSize,
                                  ),
                                  titleColor: cs.onSurfaceVariant,
                                );
                              } else if (node.isFolder) {
                                final expanded = !_collapsedPaths.contains(
                                  node.relativePath,
                                );
                                final accent = Theme.of(
                                  context,
                                ).colorScheme.primary;
                                tile = Semantics(
                                  expanded: expanded,
                                  child: FileTreeRow(
                                    title: node.title,
                                    titleMaxLines: 2,
                                    depth: row.depth,
                                    isFolder: true,
                                    onTap: () =>
                                        _toggleFolder(node.relativePath),
                                    leading: asmrDownloadFileLeading(
                                      context,
                                      node,
                                      expanded: expanded,
                                    ),
                                    trailing: FileTreeExpansionArrow(
                                      expanded: expanded,
                                      color: expanded
                                          ? accent
                                          : cs.onSurfaceVariant,
                                    ),
                                  ),
                                );
                              } else {
                                tile = _AsmrDownloadDetailsFileTile(
                                  node: node,
                                  depth: row.depth,
                                  workId: widget.workId,
                                  i18n: i18n,
                                  onRetryFile:
                                      downloadManager == null || !coreReady
                                      ? null
                                      : (relativePath) =>
                                            downloadManager.retryFailedFile(
                                              widget.workId,
                                              relativePath,
                                            ),
                                );
                              }
                              return _motion.wrap(
                                index,
                                tile,
                                key: _rowKey(row),
                              );
                            },
                          ),
                        ),
                    ],
                  ).withWindowsSmoothScroll();
                },
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: _headerKey,
                icon: Icons.info_outline_rounded,
                iconColor: Theme.of(context).colorScheme.primary,
                leading: const AppHeaderBackButton(),
                title: i18n.tr('asmr_download_details_title'),
                trailing: downloadManager == null
                    ? null
                    : _AsmrDownloadDetailsHeaderActions(
                        workId: widget.workId,
                        i18n: i18n,
                        coreReady: coreReady,
                      ),
                additionalChild: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: HeaderFloatingSurface(
                    key: const ValueKey<String>('asmr_download_work_title'),
                    height: null,
                    radius: tokens.radiusSection,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          structure.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                              ),
                        ),
                        const SizedBox(height: 8),
                        _AsmrDownloadDetailsTotals(
                          workId: widget.workId,
                          i18n: i18n,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum AsmrDownloadTaskRemovalAction { removeEntry, deleteDownloaded }

Future<AsmrDownloadTaskRemovalAction?> showAsmrDownloadTaskRemovalMenu(
  BuildContext context, {
  required String title,
  required String removeEntryLabel,
  required String deleteDownloadedLabel,
}) {
  return AppBottomSheet.show<AsmrDownloadTaskRemovalAction>(
    context: context,
    isScrollControlled: false,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        top: false,
        child: Padding(
          padding: AppBottomSheet.contentPadding,
          child: Theme(
            data: AppEntryInkWell.entryTheme(sheetContext),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AppBottomSheetHeader(
                    icon: Icons.delete_outline_rounded,
                    title: title,
                  ),
                ),
                ListTile(
                  key: const ValueKey<String>(
                    'asmr_download_remove_entry_option',
                  ),
                  leading: const Icon(Icons.remove_circle_outline_rounded),
                  title: Text(removeEntryLabel),
                  onTap: () {
                    unawaited(
                      AppInteractionFeedback.trigger(
                        AppInteractionFeedbackType.destructive,
                      ),
                    );
                    Navigator.of(
                      sheetContext,
                    ).pop(AsmrDownloadTaskRemovalAction.removeEntry);
                  },
                ),
                ListTile(
                  key: const ValueKey<String>(
                    'asmr_download_delete_downloaded_option',
                  ),
                  leading: Icon(Icons.delete_forever_rounded, color: cs.error),
                  title: Text(
                    deleteDownloadedLabel,
                    style: TextStyle(color: cs.error),
                  ),
                  onTap: () {
                    unawaited(
                      AppInteractionFeedback.trigger(
                        AppInteractionFeedbackType.destructive,
                      ),
                    );
                    Navigator.of(
                      sheetContext,
                    ).pop(AsmrDownloadTaskRemovalAction.deleteDownloaded);
                  },
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _AsmrDownloadDetailsHeaderActions extends ConsumerWidget {
  const _AsmrDownloadDetailsHeaderActions({
    required this.workId,
    required this.i18n,
    required this.coreReady,
  });

  final String workId;
  final AppLanguageProvider i18n;
  final bool coreReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.read(asmrDownloadManagerProvider);
    final status = ref.watch(
      asmrDownloadTaskProvider(workId).select((task) => task?.status),
    );
    if (manager == null || status == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return HeaderActionPill(
      children: [
        if (status != AsmrDownloadTaskStatus.completed)
          IconButton(
            key: const ValueKey<String>('asmr_download_details_toggle_pause'),
            onPressed: !coreReady
                ? null
                : () {
                    if (status == AsmrDownloadTaskStatus.paused ||
                        status == AsmrDownloadTaskStatus.failed) {
                      unawaited(manager.resumeTask(workId));
                    } else {
                      unawaited(manager.pauseTask(workId));
                    }
                  },
            icon: Icon(
              status == AsmrDownloadTaskStatus.failed
                  ? Icons.refresh_rounded
                  : status == AsmrDownloadTaskStatus.paused
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded,
              color: status == AsmrDownloadTaskStatus.failed ? cs.error : null,
            ),
            tooltip: status == AsmrDownloadTaskStatus.failed
                ? i18n.tr('retry')
                : status == AsmrDownloadTaskStatus.paused
                ? i18n.tr('resume')
                : i18n.tr('pause'),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: HeaderActionPill.buttonConstraints,
          ),
        IconButton(
          key: const ValueKey<String>('asmr_download_details_remove_task'),
          onPressed: !coreReady
              ? null
              : () async {
                  final action = await showAsmrDownloadTaskRemovalMenu(
                    context,
                    title: i18n.tr('asmr_download_remove_task'),
                    removeEntryLabel: i18n.tr('asmr_download_remove_entry'),
                    deleteDownloadedLabel: i18n.tr(
                      'asmr_download_remove_and_delete',
                    ),
                  );
                  if (!context.mounted || action == null) return;
                  final currentTask = manager.getTask(workId);
                  if (currentTask == null) return;
                  final resumeOnUndo =
                      currentTask.isActive ||
                      currentTask.status == AsmrDownloadTaskStatus.idle;
                  final pausing = manager.pauseTask(workId);
                  pausing.ignore();
                  final removalKey = UndoableRemovalKey(
                    'asmr_download',
                    workId,
                  );
                  final undoService = ref.read(undoableRemovalServiceProvider);
                  final navigator = Navigator.of(context);
                  unawaited(
                    showUndoableRemovalFeedback(
                      context,
                      service: undoService,
                      action: UndoableRemovalAction(
                        key: removalKey,
                        commit: () async {
                          await pausing;
                          if (action ==
                              AsmrDownloadTaskRemovalAction.removeEntry) {
                            await manager.cancelTask(
                              workId,
                              deleteDownloaded: false,
                            );
                          } else {
                            await manager.deleteTask(workId);
                          }
                        },
                        undo: () async {
                          await pausing;
                          if (resumeOnUndo &&
                              manager.getTask(workId)?.status ==
                                  AsmrDownloadTaskStatus.paused) {
                            await manager.resumeTask(workId);
                          }
                        },
                      ),
                      message: i18n.tr(
                        action == AsmrDownloadTaskRemovalAction.removeEntry
                            ? 'asmr_download_task_removed'
                            : 'asmr_download_task_removed_and_deleted',
                      ),
                      batchMessage: (count) =>
                          i18n.tr('items_removed_count', {'count': count}),
                      undoLabel: i18n.tr('undo'),
                      failureMessage: i18n.tr('removal_failed'),
                      icon: action == AsmrDownloadTaskRemovalAction.removeEntry
                          ? Icons.remove_circle_outline_rounded
                          : Icons.delete_sweep_rounded,
                    ),
                  );
                  if (navigator.canPop()) {
                    unawaited(navigator.maybePop());
                  }
                },
          icon: Icon(Icons.delete_outline_rounded, color: cs.error),
          tooltip: i18n.tr('asmr_download_remove_task'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
      ],
    );
  }
}

class _AsmrDownloadDetailsTotals extends ConsumerWidget {
  const _AsmrDownloadDetailsTotals({required this.workId, required this.i18n});

  final String workId;
  final AppLanguageProvider i18n;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totals = ref.watch(
      asmrDownloadTaskProvider(workId).select(
        (task) => (
          total: task?.totalBytes ?? 0,
          downloaded: task?.downloadedBytes ?? 0,
          unknown: task?.hasUnknownFileSizes ?? false,
          estimate: task?.estimatedTotalBytes,
        ),
      ),
    );
    final downloaded =
        !totals.unknown && totals.total > 0 && totals.downloaded > totals.total
        ? totals.total
        : totals.downloaded;
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.sd_storage_rounded, size: 15, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${formatMediaFileSize(downloaded)} / ${formatAsmrDownloadTotalSize(total: totals.total, unknown: totals.unknown, unknownLabel: i18n.tr('asmr_download_size_unknown'), estimate: totals.estimate)}',
            key: const ValueKey<String>('asmr_download_total_bytes'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _AsmrDownloadDetailsFileTile extends ConsumerWidget {
  const _AsmrDownloadDetailsFileTile({
    required this.node,
    required this.depth,
    required this.workId,
    required this.i18n,
    required this.onRetryFile,
  });

  static final RegExp _pathSeparatorPattern = RegExp(r'[\\/]');

  final AsmrTrackFile node;
  final int depth;
  final String workId;
  final AppLanguageProvider i18n;
  final Future<bool> Function(String relativePath)? onRetryFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(
      asmrDownloadTaskProvider(workId).select((task) {
        final total = task?.fileTotalBytes[node.relativePath] ?? node.size;
        final downloaded = task?.fileDownloadedBytes[node.relativePath] ?? 0;
        final completed =
            task?.status == AsmrDownloadTaskStatus.completed ||
            (task?.completedFilePaths.contains(node.relativePath) ?? false) ||
            (total > 0 && downloaded >= total);
        return (
          outputName:
              task?.actualOutputPaths[node.relativePath]
                  ?.split(_pathSeparatorPattern)
                  .last ??
              node.title,
          total: total,
          estimate: total <= 0
              ? task?.estimateFileTotalBytes(node.relativePath)
              : null,
          downloaded: downloaded,
          fraction: completed
              ? 1.0
              : task?.fileProgressFractions[node.relativePath],
          retryAttempt: task?.isActive == true && !completed
              ? task?.fileRetryAttempts[node.relativePath]
              : null,
          retryMaximum: task?.automaticFileRetryCount ?? 0,
          failed: task?.failedFilePaths.contains(node.relativePath) ?? false,
          retrying:
              task?.manuallyRetryingFilePaths.contains(node.relativePath) ??
              false,
          paused: task?.status == AsmrDownloadTaskStatus.paused,
          canRetry:
              task?.status == AsmrDownloadTaskStatus.downloading ||
              task?.status == AsmrDownloadTaskStatus.failed,
        );
      }),
    );
    final total = state.total;
    final downloaded = state.downloaded;
    final retryAttempt = state.retryAttempt;
    final isFileFailed = state.failed;
    final isManualRetrying = state.retrying;
    final canRetryFile = onRetryFile != null && state.canRetry;
    final cs = Theme.of(context).colorScheme;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final progressColor = isFileFailed && !isManualRetrying
        ? cs.error
        : primaryColor;
    final progress =
        state.fraction ??
        (total > 0 ? (downloaded / total).clamp(0.0, 1.0) : 0.0);

    return FileTreeRow(
      title: state.outputName,
      titleColor: isFileFailed && !isManualRetrying ? cs.error : null,
      minHeight: 52,
      depth: depth,
      leading: asmrDownloadFileLeading(context, node),
      subtitleWidget: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                color: progressColor,
                backgroundColor: progressColor.withValues(alpha: 0.2),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 2,
            child: Text(
              retryAttempt == null
                  ? '${formatMediaFileSize(downloaded)} / ${formatAsmrDownloadTotalSize(total: total, unknown: total <= 0, unknownLabel: i18n.tr('asmr_download_size_unknown'), estimate: state.estimate)}'
                  : i18n.tr('asmr_download_status_retrying', {
                      'attempt': retryAttempt,
                      'max': state.retryMaximum,
                    }),
              key: retryAttempt == null
                  ? null
                  : ValueKey<String>(
                      'asmr_download_retry_${node.relativePath}',
                    ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: isFileFailed && retryAttempt == null && !isManualRetrying
                    ? cs.error
                    : cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
      trailing: isManualRetrying
          ? SizedBox.square(
              key: ValueKey<String>(
                'asmr_download_manual_retrying_${node.relativePath}',
              ),
              dimension: 44,
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: primaryColor,
                  ),
                ),
              ),
            )
          : isFileFailed
          ? SizedBox.square(
              dimension: 44,
              child: IconButton(
                key: ValueKey<String>(
                  'asmr_download_manual_retry_${node.relativePath}',
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.refresh_rounded),
                iconSize: 22,
                color: state.paused ? cs.onSurfaceVariant : cs.error,
                tooltip: state.paused
                    ? i18n.tr('asmr_download_paused_retry_hint')
                    : i18n.tr('retry'),
                onPressed: canRetryFile
                    ? () => unawaited(onRetryFile!(node.relativePath))
                    : null,
              ),
            )
          : null,
    );
  }
}
