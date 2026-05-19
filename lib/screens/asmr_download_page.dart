import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../models/asmr_models.dart';
import '../services/asmr_download_manager.dart';
import '../services/asmr_download_selection.dart';
import '../services/asmr_library_controller.dart';
import '../widgets/app_feedback.dart';

class AsmrDownloadPage extends StatefulWidget {
  const AsmrDownloadPage({super.key, required this.work});

  final AsmrWork work;

  @override
  State<AsmrDownloadPage> createState() => _AsmrDownloadPageState();
}

class _AsmrDownloadPageState extends State<AsmrDownloadPage> {
  AsmrDownloadSelectionModel? _selection;
  String? _destinationRoot;
  bool _loading = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrap());
    });
  }

  Future<void> _bootstrap() async {
    final libraryController = context.read<AsmrLibraryController>();
    final downloadManager = context.read<AsmrDownloadManager>();
    final tree = await libraryController.ensureTrackTree(widget.work);
    await downloadManager.initialize();
    if (!mounted) return;
    setState(() {
      _selection = AsmrDownloadSelectionModel(tree);
      _destinationRoot = downloadManager.defaultDestinationRoot;
      _loading = false;
    });
  }

  Future<void> _chooseDestination() async {
    final downloadManager = context.read<AsmrDownloadManager>();
    final i18n = context.read<AppLanguageProvider>();
    final folder = await downloadManager.pickDestinationFolder(
      dialogTitle: i18n.tr('asmr_download_choose_path'),
    );
    if (!mounted || folder == null || folder.trim().isEmpty) {
      return;
    }
    await downloadManager.saveDefaultDestination(folder);
    if (!mounted) return;
    setState(() {
      _destinationRoot = folder.trim();
    });
  }

  void _refreshSelection() {
    if (!mounted) return;
    setState(() {});
  }

  Future<AsmrDownloadConflictPolicy?> _chooseConflictPolicy() {
    return showDialog<AsmrDownloadConflictPolicy?>(
      context: context,
      builder: (dialogContext) {
        final i18n = dialogContext.read<AppLanguageProvider>();
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;
        final asmrBlue = isDark
            ? const Color(0xFF60A5FA)
            : const Color(0xFF1D4ED8);
        final onAsmrBlue = isDark
            ? const Color(0xFF0F172A)
            : const Color(0xFFFFFFFF);
        return AlertDialog(
          title: Text(i18n.tr('asmr_download_conflict_title')),
          content: Text(i18n.tr('asmr_download_conflict_message')),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: asmrBlue),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(i18n.tr('cancel')),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: asmrBlue),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(AsmrDownloadConflictPolicy.skip),
              child: Text(i18n.tr('asmr_download_conflict_skip')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: asmrBlue,
                foregroundColor: onAsmrBlue,
              ),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(AsmrDownloadConflictPolicy.overwrite),
              child: Text(i18n.tr('asmr_download_conflict_overwrite')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _startDownload() async {
    final selection = _selection;
    if (selection == null) return;
    if (_starting) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final downloadManager = context.read<AsmrDownloadManager>();
    final i18n = context.read<AppLanguageProvider>();
    if (downloadManager.hasLiveTask) {
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_task_running'),
        icon: Icons.downloading_rounded,
        iconColor: asmrBlue,
      );
      return;
    }

    final selectedRoots = selection.selectedDownloadRoots();
    if (selectedRoots.isEmpty) {
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_select_required'),
        tone: AppFeedbackTone.warning,
        icon: Icons.check_box_outline_blank_rounded,
        iconColor: asmrBlue,
      );
      return;
    }

    var destination = _destinationRoot?.trim();
    if (destination == null || destination.isEmpty) {
      await _chooseDestination();
      destination = _destinationRoot?.trim();
      if (!mounted || destination == null || destination.isEmpty) {
        return;
      }
    }

    final conflictPolicy = await _chooseConflictPolicy();
    if (!mounted || conflictPolicy == null) {
      return;
    }

    setState(() {
      _starting = true;
    });
    try {
      await downloadManager.startDownload(
        work: widget.work,
        selectedRoots: selectedRoots,
        destinationRoot: destination,
        conflictPolicy: conflictPolicy,
      );
      if (!mounted) return;
      final task = downloadManager.currentTask;
      if (task != null && task.status == AsmrDownloadTaskStatus.completed) {
        unawaited(Navigator.of(context).maybePop());
      } else if (task != null && task.failedFiles > 0) {
        showAppSnackBar(
          context,
          i18n.tr('asmr_download_completed_with_failures'),
          tone: AppFeedbackTone.warning,
          icon: Icons.error_outline_rounded,
          iconColor: asmrBlue,
        );
      }
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_failed', {'error': error}),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
        iconColor: asmrBlue,
      );
    } finally {
      if (mounted) {
        setState(() {
          _starting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selection = _selection;
    final i18n = context.watch<AppLanguageProvider>();
    final selectedLeafCount = selection?.selectedLeafCount() ?? 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final onAsmrBlue = isDark
        ? const Color(0xFF0F172A)
        : const Color(0xFFFFFFFF);
    final totalFileCount = selection == null
        ? 0
        : selection.rootNodes.fold<int>(
            0,
            (sum, node) => sum + _countDownloadFiles(node),
          );
    final totalFolderCount = selection == null
        ? 0
        : selection.rootNodes.fold<int>(
            0,
            (sum, node) => sum + _countDownloadFolders(node),
          );
    final hasDestination = (_destinationRoot?.trim().isNotEmpty ?? false);

    return Scaffold(
      appBar: AppBar(
        title: Text(i18n.tr('asmr_download_title')),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: asmrBlue),
            onPressed: _starting ? null : _chooseDestination,
            child: Text(
              i18n.tr(
                hasDestination
                    ? 'asmr_download_change_path'
                    : 'asmr_download_choose_path',
              ),
            ),
          ),
        ],
      ),
      body: _loading || selection == null
          ? Center(child: CircularProgressIndicator(color: asmrBlue))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: _DownloadSummaryCard(
                    work: widget.work,
                    selectedLeafCount: selectedLeafCount,
                    totalFileCount: totalFileCount,
                    totalFolderCount: totalFolderCount,
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [
                      for (final node in selection.rootNodes)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: _AsmrDownloadNodeTile(
                            node: node,
                            depth: 0,
                            selection: selection,
                            onSelectionChanged: _refreshSelection,
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    0,
                    16,
                    16 + MediaQuery.of(context).viewPadding.bottom,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: asmrBlue,
                            side: BorderSide(
                              color: asmrBlue.withValues(alpha: 0.5),
                            ),
                          ),
                          onPressed: _starting
                              ? null
                              : () => Navigator.of(context).maybePop(),
                          child: Text(i18n.tr('cancel')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: asmrBlue,
                            foregroundColor: onAsmrBlue,
                          ),
                          onPressed: _starting ? null : _startDownload,
                          icon: _starting
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: onAsmrBlue,
                                  ),
                                )
                              : const Icon(Icons.download_rounded),
                          label: Text(
                            i18n.tr(
                              _starting
                                  ? 'asmr_download_starting'
                                  : 'asmr_download_confirm',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class AsmrDownloadTaskPage extends StatelessWidget {
  const AsmrDownloadTaskPage({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<AsmrDownloadManager>();
    final task = manager.currentTask;
    final i18n = context.watch<AppLanguageProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return Scaffold(
      appBar: AppBar(title: Text(i18n.tr('asmr_download_task_title'))),
      bottomNavigationBar: task == null || !task.isActive
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: FilledButton.icon(
                onPressed: () => unawaited(_cancelTask(context, manager)),
                icon: const Icon(Icons.cancel_rounded),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  minimumSize: const Size.fromHeight(52),
                ),
                label: Text(i18n.tr('asmr_download_cancel_and_clear')),
              ),
            ),
      body: task == null
          ? Center(child: Text(i18n.tr('asmr_download_no_tasks')))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _TaskInfoCard(
                  title: task.work.title,
                  subtitle: _taskSubtitle(i18n, task),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: task.progress, color: asmrBlue),
                const SizedBox(height: 12),
                _TaskInfoRow(
                  label: i18n.tr('asmr_download_status'),
                  value: _statusText(i18n, task.status),
                ),
                _TaskInfoRow(
                  label: i18n.tr('asmr_download_destination'),
                  value: task.displayDestinationPath,
                ),
                _TaskInfoRow(
                  label: i18n.tr('asmr_download_progress'),
                  value: '${task.completedFiles}/${task.totalFiles}',
                ),
                _TaskInfoRow(
                  label: i18n.tr('asmr_download_skipped'),
                  value: '${task.skippedFiles}',
                ),
                _TaskInfoRow(
                  label: i18n.tr('asmr_download_failed_count'),
                  value: '${task.failedFiles}',
                ),
                _TaskInfoRow(
                  label: i18n.tr('asmr_download_downloaded'),
                  value: _formatBytes(task.downloadedBytes),
                ),
                _TaskInfoRow(
                  label: i18n.tr('asmr_download_total_size'),
                  value: _formatBytes(task.totalBytes),
                ),
                if (task.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    task.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

Future<void> _cancelTask(
  BuildContext context,
  AsmrDownloadManager manager,
) async {
  await manager.cancelCurrentDownload();
  if (!context.mounted) {
    return;
  }
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
  final i18n = context.read<AppLanguageProvider>();
  showAppSnackBar(
    context,
    i18n.tr('asmr_download_cancelled_and_cleared'),
    tone: AppFeedbackTone.warning,
    icon: Icons.delete_sweep_rounded,
    iconColor: asmrBlue,
  );
}

class _DownloadSummaryCard extends StatelessWidget {
  const _DownloadSummaryCard({
    required this.work,
    required this.selectedLeafCount,
    required this.totalFileCount,
    required this.totalFolderCount,
  });

  final AsmrWork work;
  final int selectedLeafCount;
  final int totalFileCount;
  final int totalFolderCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = context.watch<AppLanguageProvider>();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            work.title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            i18n.tr('asmr_download_summary_selected', {
              'count': selectedLeafCount,
            }),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            i18n.tr('asmr_download_summary_total', {
              'fileCount': totalFileCount,
              'folderCount': totalFolderCount,
            }),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _AsmrDownloadNodeTile extends StatefulWidget {
  const _AsmrDownloadNodeTile({
    required this.node,
    required this.depth,
    required this.selection,
    required this.onSelectionChanged,
  });

  final AsmrDownloadSelectionNode node;
  final int depth;
  final AsmrDownloadSelectionModel selection;
  final VoidCallback onSelectionChanged;

  @override
  State<_AsmrDownloadNodeTile> createState() => _AsmrDownloadNodeTileState();
}

class _AsmrDownloadNodeTileState extends State<_AsmrDownloadNodeTile> {
  static const double _indentWidth = 14;
  static const double _folderRowHeight = 44;
  static const double _fileRowHeight = 46;

  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.depth == 0;
  }

  void _toggleSelection(bool? next) {
    widget.selection.togglePath(widget.node.track.relativePath, next);
    widget.onSelectionChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.watch<AppLanguageProvider>();
    final value = widget.selection.stateForPath(widget.node.track.relativePath);
    final indent = _indentWidth * widget.depth;

    if (widget.node.track.isFolder) {
      final hasChildren = widget.node.children.isNotEmpty;
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _expanded,
          minTileHeight: _folderRowHeight,
          shape: const RoundedRectangleBorder(),
          collapsedShape: const RoundedRectangleBorder(),
          tilePadding: EdgeInsetsDirectional.only(start: indent, end: 2),
          childrenPadding: EdgeInsets.zero,
          onExpansionChanged: (expanded) {
            setState(() {
              _expanded = expanded;
            });
          },
          title: Row(
            children: [
              _CompactNodeCheckbox(value: value, onChanged: _toggleSelection),
              const SizedBox(width: 4),
              Icon(
                _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                size: 20,
                color: asmrBlue.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.node.track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    height: 1.06,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ],
          ),
          trailing: hasChildren
              ? AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.expand_more_rounded,
                    color: cs.onSurfaceVariant,
                    size: 20,
                  ),
                )
              : const SizedBox(width: 20),
          children: hasChildren
              ? [
                  for (final child in widget.node.children)
                    _AsmrDownloadNodeTile(
                      node: child,
                      depth: widget.depth + 1,
                      selection: widget.selection,
                      onSelectionChanged: widget.onSelectionChanged,
                    ),
                ]
              : [
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: indent + _indentWidth + 40,
                      end: 8,
                      bottom: 4,
                    ),
                    child: Text(
                      i18n.tr('asmr_download_empty_folder'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
        ),
      );
    }

    return InkWell(
      onTap: () => _toggleSelection(value == true ? false : true),
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: _fileRowHeight,
        child: Padding(
          padding: EdgeInsetsDirectional.only(start: indent, end: 4),
          child: Row(
            children: [
              _CompactNodeCheckbox(value: value, onChanged: _toggleSelection),
              const SizedBox(width: 4),
              Icon(
                _fileIconFor(widget.node.track),
                size: 18,
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.node.track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _formatFileSize(widget.node.track.size),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactNodeCheckbox extends StatelessWidget {
  const _CompactNodeCheckbox({required this.value, required this.onChanged});

  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return SizedBox(
      width: 28,
      height: 28,
      child: Checkbox(
        tristate: true,
        value: value,
        onChanged: onChanged,
        activeColor: asmrBlue,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _TaskInfoCard extends StatelessWidget {
  const _TaskInfoCard({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _TaskInfoRow extends StatelessWidget {
  const _TaskInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '--' : value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

String _statusText(AppLanguageProvider i18n, AsmrDownloadTaskStatus status) {
  switch (status) {
    case AsmrDownloadTaskStatus.preparing:
      return i18n.tr('asmr_download_status_preparing');
    case AsmrDownloadTaskStatus.downloading:
      return i18n.tr('asmr_download_status_downloading');
    case AsmrDownloadTaskStatus.completed:
      return i18n.tr('asmr_download_status_completed');
    case AsmrDownloadTaskStatus.failed:
      return i18n.tr('asmr_download_status_failed');
    case AsmrDownloadTaskStatus.idle:
      return i18n.tr('asmr_download_status_idle');
  }
}

String _taskSubtitle(AppLanguageProvider i18n, AsmrDownloadTaskSnapshot task) {
  final currentItemPath = task.currentItemPath;
  if (task.isActive &&
      currentItemPath != null &&
      currentItemPath.trim().isNotEmpty) {
    return currentItemPath;
  }
  if (task.failedFiles > 0 &&
      task.status == AsmrDownloadTaskStatus.failed &&
      task.completedFiles > 0) {
    return i18n.tr('asmr_download_completed_with_failures');
  }
  final error = task.error;
  if (error != null && error.trim().isNotEmpty) {
    return i18n.tr('asmr_download_failed', {'error': error});
  }
  return switch (task.status) {
    AsmrDownloadTaskStatus.preparing => i18n.tr(
      'asmr_download_status_preparing',
    ),
    AsmrDownloadTaskStatus.downloading => i18n.tr(
      'asmr_download_status_downloading',
    ),
    AsmrDownloadTaskStatus.completed => i18n.tr(
      'asmr_download_status_completed',
    ),
    AsmrDownloadTaskStatus.failed => i18n.tr('asmr_download_status_failed'),
    AsmrDownloadTaskStatus.idle => i18n.tr('asmr_download_waiting'),
  };
}

String _formatFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}';
}

String _formatBytes(int bytes) => _formatFileSize(bytes);

int _countDownloadFiles(AsmrDownloadSelectionNode node) {
  if (node.track.isFolder) {
    return node.children.fold<int>(
      0,
      (sum, child) => sum + _countDownloadFiles(child),
    );
  }
  return 1;
}

int _countDownloadFolders(AsmrDownloadSelectionNode node) {
  if (!node.track.isFolder) {
    return 0;
  }
  return 1 +
      node.children.fold<int>(
        0,
        (sum, child) => sum + _countDownloadFolders(child),
      );
}

IconData _fileIconFor(AsmrTrackFile track) {
  if (track.isSubtitle) {
    return Icons.subtitles_rounded;
  }
  switch (track.resolvedExtension) {
    case '.jpg':
    case '.jpeg':
    case '.png':
    case '.webp':
    case '.gif':
      return Icons.image_rounded;
    case '.txt':
    case '.md':
    case '.json':
    case '.cue':
      return Icons.description_rounded;
    case '.zip':
    case '.7z':
    case '.rar':
      return Icons.archive_rounded;
    default:
      return track.isAudio
          ? Icons.audio_file_rounded
          : Icons.insert_drive_file_rounded;
  }
}
