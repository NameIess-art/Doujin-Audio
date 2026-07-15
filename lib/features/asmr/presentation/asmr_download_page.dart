import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/audio_provider_riverpod.dart';
import '../domain/asmr_models.dart';
import '../application/asmr_download_manager.dart';
import '../application/asmr_download_selection.dart';
import '../application/asmr_library_controller.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/top_page_header.dart';
import 'asmr_download_details_page.dart';

class AsmrDownloadPage extends ConsumerStatefulWidget {
  const AsmrDownloadPage({super.key, required this.work});

  final AsmrWork work;

  @override
  ConsumerState<AsmrDownloadPage> createState() => _AsmrDownloadPageState();
}

class _AsmrDownloadPageState extends ConsumerState<AsmrDownloadPage> {
  AsmrDownloadSelectionModel? _selection;
  String? _destinationRoot;
  bool _loading = true;
  bool _starting = false;
  Object? _bootstrapError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrap());
    });
  }

  Future<void> _bootstrap() async {
    var destinationMissing = false;
    try {
      final result = await UiOperationService.instance
          .run<({List<AsmrTrackFile> tree, String? destinationRoot})>(
            scope: UiOperationScope.asmrDownloadInit,
            labelKey: 'asmr_download_title',
            task: (_) async {
              final libraryController = context.read<AsmrLibraryController>();
              final downloadManager = context.read<AsmrDownloadManager>();
              final settings = ref.read(settingsRepositoryProvider);
              final tree = await libraryController.ensureTrackTree(widget.work);
              await downloadManager.initialize();
              final savedDestination = settings.asmrDownloadDestinationRoot;
              destinationMissing =
                  savedDestination != null &&
                  savedDestination.trim().isNotEmpty &&
                  !await downloadManager.destinationExists(savedDestination);
              if (destinationMissing) {
                await settings.setAsmrDownloadDestinationRoot(null);
              }
              return (
                tree: tree,
                destinationRoot: destinationMissing ? null : savedDestination,
              );
            },
          );
      if (!mounted) return;
      setState(() {
        _selection = AsmrDownloadSelectionModel(result.tree);
        _destinationRoot = result.destinationRoot;
        _loading = false;
        _bootstrapError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _bootstrapError = error;
        _loading = false;
      });
      return;
    }
    if (destinationMissing && mounted) {
      final i18n = context.read<AppLanguageProvider>();
      final asmrBlue = AppDesignTokens.of(context).asmrAccent;
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_path_missing'),
        tone: AppFeedbackTone.warning,
        icon: Icons.folder_off_rounded,
        iconColor: asmrBlue,
      );
    }
  }

  Future<void> _chooseDestination() async {
    final downloadManager = context.read<AsmrDownloadManager>();
    final settings = ref.read(settingsRepositoryProvider);
    final i18n = context.read<AppLanguageProvider>();
    final folder = await downloadManager.pickDestinationFolder(
      dialogTitle: i18n.tr('asmr_download_choose_path'),
    );
    if (!mounted || folder == null || folder.trim().isEmpty) {
      return;
    }
    await settings.setAsmrDownloadDestinationRoot(folder);
    if (!mounted) return;
    setState(() {
      _destinationRoot = folder.trim();
    });
  }

  void _refreshSelection() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _startDownload() async {
    final selection = _selection;
    if (selection == null) return;
    if (_starting) return;

    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final downloadManager = context.read<AsmrDownloadManager>();
    final settings = ref.read(settingsRepositoryProvider);
    final i18n = context.read<AppLanguageProvider>();
    final task = downloadManager.getTask(widget.work.id);
    if (task != null &&
        task.status != AsmrDownloadTaskStatus.completed &&
        task.status != AsmrDownloadTaskStatus.failed) {
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
    if (!await downloadManager.destinationExists(destination)) {
      await settings.setAsmrDownloadDestinationRoot(null);
      if (!mounted) return;
      setState(() {
        _destinationRoot = null;
      });
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_path_missing'),
        tone: AppFeedbackTone.warning,
        icon: Icons.folder_off_rounded,
        iconColor: asmrBlue,
      );
      await _chooseDestination();
      destination = _destinationRoot?.trim();
      if (!mounted || destination == null || destination.isEmpty) {
        return;
      }
    }

    setState(() {
      _starting = true;
    });
    try {
      await UiOperationService.instance.run<void>(
        scope: UiOperationScope.asmrDownloadStart,
        labelKey: 'asmr_download_starting',
        task: (_) => downloadManager.startDownload(
          work: widget.work,
          selectedRoots: selectedRoots,
          destinationRoot: destination!,
          conflictPolicy: settings.asmrDownloadConflictPolicy,
        ),
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_added_to_list'),
        tone: AppFeedbackTone.success,
        icon: Icons.checklist_rounded,
        iconColor: asmrBlue,
      );
      if (!mounted) return;
      unawaited(Navigator.of(context).maybePop());
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_failed_next_step'),
        tone: AppFeedbackTone.destructive,
        title: i18n.tr('asmr_download_failed_title'),
        icon: Icons.error_outline_rounded,
        iconColor: asmrBlue,
        actionLabel: i18n.tr('retry'),
        onAction: () => unawaited(_startDownload()),
        duration: const Duration(seconds: 6),
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
    final selectedTotalSizeBytes = selection?.selectedTotalSizeBytes() ?? 0;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    final onAsmrBlue = tokens.onAsmrAccent;
    final hasDestination = (_destinationRoot?.trim().isNotEmpty ?? false);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: _DownloadSummaryCard(
              work: widget.work,
              selectedLeafCount: selectedLeafCount,
              selectedTotalSizeBytes: selectedTotalSizeBytes,
            ),
          ),
          Expanded(
            child: _loading
                ? const SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: OperationSkeletonList(
                      itemCount: 6,
                      showHeader: false,
                    ),
                  )
                : _bootstrapError != null || selection == null
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: OperationStatusBanner(
                      label: i18n.tr('asmr_detail_load_failed'),
                      error: _bootstrapError,
                      onRetry: () {
                        setState(() {
                          _loading = true;
                          _bootstrapError = null;
                        });
                        unawaited(_bootstrap());
                      },
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: selection.rootNodes.length,
                    itemBuilder: (context, index) {
                      final node = selection.rootNodes[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: _AsmrDownloadNodeTile(
                          node: node,
                          depth: 0,
                          selection: selection,
                          onSelectionChanged: _refreshSelection,
                        ),
                      );
                    },
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
                      side: BorderSide(color: asmrBlue.withValues(alpha: 0.5)),
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

class AsmrDownloadTaskPage extends ConsumerWidget {
  const AsmrDownloadTaskPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(asmrDownloadStateProvider).valueOrNull;
    final taskIds =
        state?.taskIds ?? ref.read(asmrDownloadManagerProvider).taskIds;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final headerHeight = MediaQuery.paddingOf(context).top + 56;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Stack(
        children: [
          if (taskIds.isEmpty)
            Center(
              child: Text(
                i18n.tr('asmr_download_no_tasks'),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ListView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                headerHeight + 16,
                16,
                MediaQuery.paddingOf(context).bottom + 16,
              ),
              physics: const ClampingScrollPhysics(),
              itemCount: taskIds.length,
              itemBuilder: (context, index) {
                return _TaskCard(workId: taskIds[index]);
              },
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              leading: const BackButton(),
              title: i18n.tr('asmr_download_task_title'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskCard extends ConsumerWidget {
  const _TaskCard({required this.workId});

  final int workId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(asmrDownloadTaskProvider(workId));
    if (task == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AsmrDownloadDetailsPage(workId: task.work.id),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      task.work.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (task.status != AsmrDownloadTaskStatus.completed &&
                      task.status != AsmrDownloadTaskStatus.failed)
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          task.status == AsmrDownloadTaskStatus.paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                        ),
                        iconSize: 22,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                        tooltip: task.status == AsmrDownloadTaskStatus.paused
                            ? i18n.tr('resume')
                            : i18n.tr('pause'),
                        onPressed: () {
                          final manager = ref.read(asmrDownloadManagerProvider);
                          if (task.status == AsmrDownloadTaskStatus.paused) {
                            manager.resumeTask(task.work.id);
                          } else {
                            manager.pauseTask(task.work.id);
                          }
                        },
                      ),
                    ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.cancel_rounded),
                      iconSize: 22,
                      color: cs.error.withValues(alpha: 0.8),
                      tooltip: i18n.tr('cancel'),
                      onPressed: () async {
                        await ref
                            .read(asmrDownloadManagerProvider)
                            .cancelTask(task.work.id);
                        if (!context.mounted) return;
                        showAppSnackBar(
                          context,
                          i18n.tr('asmr_download_cancelled_and_cleared'),
                          tone: AppFeedbackTone.warning,
                          icon: Icons.delete_sweep_rounded,
                          iconColor: asmrBlue,
                        );
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: task.progress,
                  minHeight: 6,
                  color: asmrBlue,
                  backgroundColor: asmrBlue.withValues(alpha: 0.2),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _statusText(i18n, task.status),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${_formatBytes(task.downloadedBytes)} / ${_formatBytes(task.totalBytes)}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadSummaryCard extends ConsumerWidget {
  const _DownloadSummaryCard({
    required this.work,
    required this.selectedLeafCount,
    required this.selectedTotalSizeBytes,
  });

  final AsmrWork work;
  final int selectedLeafCount;
  final int selectedTotalSizeBytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
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
              'size': _formatFileSize(selectedTotalSizeBytes),
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

class _AsmrDownloadNodeTile extends ConsumerStatefulWidget {
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
  ConsumerState<_AsmrDownloadNodeTile> createState() =>
      _AsmrDownloadNodeTileState();
}

class _AsmrDownloadNodeTileState extends ConsumerState<_AsmrDownloadNodeTile> {
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
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
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
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
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

String _statusText(AppLanguageProvider i18n, AsmrDownloadTaskStatus status) {
  switch (status) {
    case AsmrDownloadTaskStatus.preparing:
      return i18n.tr('asmr_download_status_preparing');
    case AsmrDownloadTaskStatus.downloading:
      return i18n.tr('asmr_download_status_downloading');
    case AsmrDownloadTaskStatus.paused:
      return i18n.tr('asmr_download_status_paused');
    case AsmrDownloadTaskStatus.completed:
      return i18n.tr('asmr_download_status_completed');
    case AsmrDownloadTaskStatus.failed:
      return i18n.tr('asmr_download_status_failed');
    case AsmrDownloadTaskStatus.idle:
      return i18n.tr('asmr_download_status_idle');
  }
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
