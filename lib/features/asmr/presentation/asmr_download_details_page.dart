import 'asmr_download_format.dart';
import 'asmr_providers.dart';
import 'asmr_theme.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../domain/asmr_models.dart';
import '../application/asmr_download_models.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';

class AsmrDownloadDetailsPage extends ConsumerStatefulWidget {
  const AsmrDownloadDetailsPage({super.key, required this.workId});

  final int workId;

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
    _ensureRows(tracks);

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
              child: AppPageContentTransition(
                child: CustomScrollView(
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
                              return Padding(
                                key: rowKey,
                                padding: EdgeInsetsDirectional.only(
                                  start: row.depth * 12 + 16,
                                  end: 8,
                                  bottom: 8,
                                ),
                                child: Text(
                                  i18n.tr('asmr_download_empty_folder'),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: cs.onSurfaceVariant.withValues(
                                          alpha: 0.7,
                                        ),
                                      ),
                                ),
                              );
                            }
                            if (node.isFolder) {
                              final expanded = !_collapsedPaths.contains(
                                node.relativePath,
                              );
                              final accent = AppDesignTokens.of(
                                context,
                              ).asmrAccent;
                              final shape = RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppDesignTokens.of(context).radiusSmall,
                                ),
                              );
                              return Theme(
                                key: rowKey,
                                data: Theme.of(
                                  context,
                                ).copyWith(dividerColor: Colors.transparent),
                                // Descendants belong to the lazy sliver, not
                                // this header's eager expansion body.
                                child: ExpansionTile(
                                  expansionAnimationStyle:
                                      appExpansionAnimationStyle(context),
                                  initiallyExpanded: expanded,
                                  onExpansionChanged: (value) =>
                                      _toggleFolder(node.relativePath, value),
                                  shape: shape,
                                  collapsedShape: shape,
                                  tilePadding: EdgeInsetsDirectional.only(
                                    start: row.depth * 12 + 16,
                                    end: 16,
                                  ),
                                  minTileHeight: 44,
                                  iconColor: accent,
                                  collapsedIconColor: cs.onSurfaceVariant,
                                  title: Text(
                                    node.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: expanded ? accent : null,
                                        ),
                                  ),
                                  leading: Icon(
                                    expanded
                                        ? Icons.folder_open_rounded
                                        : Icons.folder_rounded,
                                    color: expanded
                                        ? accent
                                        : cs.onSurfaceVariant,
                                    size: 22,
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
                              onRetryFile: downloadManager == null
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
                ),
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
                          _AsmrDownloadDetailsTotals(workId: widget.workId),
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
  const _AsmrDownloadDetailsTotals({required this.workId});

  final int workId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totals = ref.watch(
      asmrDownloadTaskProvider(workId).select(
        (task) => (
          total: task?.totalBytes ?? 0,
          downloaded: task?.downloadedBytes ?? 0,
        ),
      ),
    );
    final downloaded = totals.total > 0 && totals.downloaded > totals.total
        ? totals.total
        : totals.downloaded;
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.sd_storage_rounded, size: 15, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          '${formatAsmrDownloadSize(downloaded)} / ${formatAsmrDownloadSize(totals.total)}',
          key: const ValueKey<String>('asmr_download_total_bytes'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
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
  final int workId;
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
          total: total,
          downloaded: downloaded,
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
    final canRetryFile = onRetryFile != null && state.canRetry;
    final cs = Theme.of(context).colorScheme;
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    double progress = 0.0;
    if (total > 0) {
      progress = (downloaded / total).clamp(0.0, 1.0);
    }

    final contentStart = depth == 0 ? 16.0 : depth * 12.0 + 8;
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: contentStart,
        end: 16,
        top: 4,
        bottom: 4,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(
              asmrDownloadFileIcon(node),
              size: 20,
              color: cs.onSurfaceVariant.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
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
                      const SizedBox(width: 12),
                      Text(
                        retryAttempt == null
                            ? '${formatAsmrDownloadSize(downloaded)} / ${formatAsmrDownloadSize(total)}'
                            : i18n.tr('asmr_download_status_retrying', {
                                'attempt': retryAttempt,
                                'max': state.retryMaximum,
                              }),
                        key: retryAttempt == null
                            ? null
                            : ValueKey<String>(
                                'asmr_download_retry_${node.relativePath}',
                              ),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (isFileFailed || isManualRetrying) ...[
              const SizedBox(width: 4),
              SizedBox.square(
                dimension: 44,
                child: isManualRetrying
                    ? Center(
                        child: SizedBox.square(
                          key: ValueKey<String>(
                            'asmr_download_manual_retry_progress_'
                            '${node.relativePath}',
                          ),
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: asmrBlue,
                          ),
                        ),
                      )
                    : IconButton(
                        key: ValueKey<String>(
                          'asmr_download_manual_retry_'
                          '${node.relativePath}',
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
              ),
            ],
          ],
        ),
      ),
    );
  }
}
