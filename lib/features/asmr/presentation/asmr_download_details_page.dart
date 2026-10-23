import 'asmr_download_format.dart';
import 'asmr_providers.dart';
import 'asmr_theme.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../domain/asmr_models.dart';
import '../application/asmr_download_models.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';

class AsmrDownloadDetailsPage extends ConsumerStatefulWidget {
  const AsmrDownloadDetailsPage({super.key, required this.workId});

  final String workId;

  @override
  ConsumerState<AsmrDownloadDetailsPage> createState() =>
      _AsmrDownloadDetailsPageState();
}

class _AsmrDownloadDetailsPageState
    extends ConsumerState<AsmrDownloadDetailsPage> {
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 0;
  final Set<String> _collapsedPaths = {};
  List<AsmrTrackFile>? _rowsSource;
  List<({AsmrTrackFile node, int depth, bool emptyFolder})> _rows = const [];

  void _toggleFolder(String path, bool expanded) {
    setState(() {
      if (expanded) {
        _collapsedPaths.remove(path);
      } else {
        _collapsedPaths.add(path);
      }
      _rowsSource = null;
    });
  }

  void _ensureRows(List<AsmrTrackFile> roots) {
    if (identical(_rowsSource, roots)) return;
    final rows = <({AsmrTrackFile node, int depth, bool emptyFolder})>[];
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

    for (final root in roots) {
      visit(root, 0);
    }
    _rowsSource = roots;
    _rows = rows;
  }

  @override
  void didUpdateWidget(covariant AsmrDownloadDetailsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workId != widget.workId) {
      _collapsedPaths.clear();
      _rowsSource = null;
      _rows = const [];
      _headerHeight = 0;
    }
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

    if (structure == null) {
      _rowsSource = null;
      _rows = const [];
      _collapsedPaths.clear();
      return Scaffold(
        body: Stack(
          children: [
            AppPageContentTransition(
              child: Center(
                child: Text(i18n.tr('asmr_download_task_not_found')),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Theme(
                data: asmrThemeData(context),
                child: TopPageHeader(
                  icon: Icons.info_outline_rounded,
                  iconColor: AppDesignTokens.of(context).asmrAccent,
                  leading: const BackButton(),
                  title: i18n.tr('asmr_download_details_title'),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final tracks = structure.roots;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final h = box.size.height;
        if (h > 0 && (_headerHeight == 0 || (h - _headerHeight).abs() > 0.5)) {
          setState(() => _headerHeight = h);
        }
      }
    });

    final defaultHeaderHeight = MediaQuery.paddingOf(context).top + 140.0;
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : defaultHeaderHeight;
    final listTopPadding = effectiveHeaderHeight + 8;

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
                    MediaQuery.paddingOf(context).bottom + 16,
                  ),
                ),
                builder: (context) {
                  _ensureRows(tracks);
                  return CustomScrollView(
                    physics: const ClampingScrollPhysics(),
                    slivers: [
                      if (tracks.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text(
                              i18n.tr('asmr_download_no_files_selected'),
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            listTopPadding,
                            16,
                            MediaQuery.paddingOf(context).bottom + 16,
                          ),
                          sliver: SliverList.builder(
                            itemCount: _rows.length,
                            itemBuilder: (context, index) {
                              final row = _rows[index];
                              final node = row.node;
                              final rowKey = ValueKey<String>(
                                'asmr_download_${row.emptyFolder ? "empty" : "node"}_row_${node.relativePath}',
                              );
                              if (row.emptyFolder) {
                                return FileTreeRow(
                                  key: rowKey,
                                  title: i18n.tr('asmr_download_empty_folder'),
                                  depth: row.depth,
                                  minHeight: 28,
                                  leading: const SizedBox(
                                    width: AppDesignTokens.fileEntryIconSize,
                                  ),
                                  titleColor: cs.onSurfaceVariant,
                                );
                              }
                              if (node.isFolder) {
                                final expanded = !_collapsedPaths.contains(
                                  node.relativePath,
                                );
                                final accent = AppDesignTokens.of(
                                  context,
                                ).asmrAccent;
                                return Semantics(
                                  key: rowKey,
                                  expanded: expanded,
                                  child: FileTreeRow(
                                    title: node.title,
                                    titleMaxLines: 2,
                                    depth: row.depth,
                                    isFolder: true,
                                    onTap: () => _toggleFolder(
                                      node.relativePath,
                                      !expanded,
                                    ),
                                    leading: Icon(
                                      expanded
                                          ? AppDesignTokens.openFolderIcon
                                          : AppDesignTokens.folderIcon,
                                      color: AppDesignTokens.folderIconColor,
                                      size: AppDesignTokens.fileEntryIconSize,
                                    ),
                                    trailing: FileTreeExpansionArrow(
                                      expanded: expanded,
                                      color: expanded
                                          ? accent
                                          : cs.onSurfaceVariant,
                                    ),
                                  ),
                                );
                              }
                              return _AsmrDownloadDetailsFileTile(
                                key: rowKey,
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
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Theme(
                data: asmrThemeData(context),
                child: TopPageHeader(
                  key: _headerKey,
                  icon: Icons.info_outline_rounded,
                  iconColor: AppDesignTokens.of(context).asmrAccent,
                  leading: const BackButton(),
                  title: i18n.tr('asmr_download_details_title'),
                  additionalChild: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: HeaderFloatingSurface(
                      key: const ValueKey<String>('asmr_download_work_title'),
                      height: null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
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
            ),
          ],
        ),
      ),
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
            '${formatAsmrDownloadSize(downloaded)} / ${totals.unknown ? i18n.tr('asmr_download_size_unknown') : formatAsmrDownloadSize(totals.total)}',
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
    super.key,
    required this.node,
    required this.depth,
    required this.workId,
    required this.i18n,
    required this.onRetryFile,
  });

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
                  ?.split(RegExp(r'[\\/]'))
                  .last ??
              node.title,
          total: total,
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
    final canRetryFile =
        onRetryFile != null && state.canRetry && !isManualRetrying;
    final cs = Theme.of(context).colorScheme;
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final progress =
        state.fraction ??
        (total > 0 ? (downloaded / total).clamp(0.0, 1.0) : 0.0);

    return FileTreeRow(
      title: state.outputName,
      minHeight: 52,
      depth: depth,
      leading: Icon(
        asmrDownloadFileIcon(node),
        size: AppDesignTokens.fileEntryIconSize,
        color: asmrDownloadFileColor(
          node,
          audioColor: asmrBlue,
          fallbackColor: cs.onSurfaceVariant,
        ),
      ),
      subtitleWidget: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                color: asmrBlue,
                backgroundColor: asmrBlue.withValues(alpha: 0.2),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 2,
            child: Text(
              retryAttempt == null
                  ? '${formatAsmrDownloadSize(downloaded)} / ${total <= 0 ? i18n.tr('asmr_download_size_unknown') : formatAsmrDownloadSize(total)}'
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
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
      trailing: isFileFailed || isManualRetrying
          ? SizedBox.square(
              dimension: 44,
              child: IconButton(
                key: ValueKey<String>(
                  'asmr_download_manual_retry_${node.relativePath}',
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.refresh_rounded),
                iconSize: 22,
                color: asmrBlue,
                tooltip: i18n.tr('retry'),
                onPressed: canRetryFile
                    ? () => unawaited(onRetryFile!(node.relativePath))
                    : null,
              ),
            )
          : null,
    );
  }
}
