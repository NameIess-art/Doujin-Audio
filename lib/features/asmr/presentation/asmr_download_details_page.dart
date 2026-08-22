import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../domain/asmr_models.dart';
import '../application/asmr_download_manager.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/top_page_header.dart';

class AsmrDownloadDetailsPage extends ConsumerWidget {
  const AsmrDownloadDetailsPage({super.key, required this.workId});

  final int workId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final task = ref.watch(asmrDownloadTaskProvider(workId));
    final headerHeight = MediaQuery.paddingOf(context).top + 56;
    final cs = Theme.of(context).colorScheme;

    if (task == null) {
      return Scaffold(
        body: Stack(
          children: [
            Center(child: Text(i18n.tr('asmr_download_task_not_found'))),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                leading: const BackButton(),
                title: i18n.tr('asmr_download_details_title'),
              ),
            ),
          ],
        ),
      );
    }

    final tracks = task.selectedRoots;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Stack(
        children: [
          CustomScrollView(
            physics: const ClampingScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, headerHeight + 16, 16, 16),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.work.title,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.3,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            Icons.sd_storage_rounded,
                            size: 16,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_formatBytes(task.downloadedBytes)} / ${_formatBytes(task.totalBytes)}',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
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
              if (tracks.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(i18n.tr('asmr_download_no_files_selected')),
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.paddingOf(context).bottom + 16,
                  ),
                  sliver: SliverList.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      return _AsmrDownloadDetailsNodeTile(
                        node: tracks[index],
                        depth: 0,
                        task: task,
                        i18n: i18n,
                      );
                    },
                  ),
                ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              leading: const BackButton(),
              title: i18n.tr('asmr_download_details_title'),
            ),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
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
}

class _AsmrDownloadDetailsNodeTile extends StatefulWidget {
  const _AsmrDownloadDetailsNodeTile({
    required this.node,
    required this.depth,
    required this.task,
    required this.i18n,
  });

  final AsmrTrackFile node;
  final int depth;
  final AsmrDownloadTaskSnapshot task;
  final AppLanguageProvider i18n;

  @override
  State<_AsmrDownloadDetailsNodeTile> createState() =>
      _AsmrDownloadDetailsNodeTileState();
}

class _AsmrDownloadDetailsNodeTileState
    extends State<_AsmrDownloadDetailsNodeTile> {
  static const double _indentWidth = 12;
  static const double _rootContentInset = 16;
  static const double _nestedContentInset = 8;

  bool _expanded = true;

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final indent = widget.depth * _indentWidth;
    const fileRowHeight = 44.0;

    if (widget.node.isFolder) {
      final hasChildren = widget.node.children.isNotEmpty;
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          expansionAnimationStyle: appExpansionAnimationStyle(context),
          initiallyExpanded: _expanded,
          onExpansionChanged: (v) => _toggleExpanded(),
          tilePadding: EdgeInsetsDirectional.only(
            start: indent + _rootContentInset,
            end: 16,
          ),
          childrenPadding: EdgeInsets.zero,
          minTileHeight: fileRowHeight,
          iconColor: asmrBlue,
          collapsedIconColor: cs.onSurfaceVariant,
          title: Text(
            widget.node.title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: _expanded ? asmrBlue : null,
            ),
          ),
          leading: Icon(
            _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
            color: _expanded ? asmrBlue : cs.onSurfaceVariant,
            size: 22,
          ),
          children: hasChildren
              ? [
                  for (final child in widget.node.children)
                    _AsmrDownloadDetailsNodeTile(
                      node: child,
                      depth: widget.depth + 1,
                      task: widget.task,
                      i18n: widget.i18n,
                    ),
                ]
              : [
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: indent + _rootContentInset,
                      end: 8,
                      bottom: 8,
                    ),
                    child: Text(
                      widget.i18n.tr('asmr_download_empty_folder'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
        ),
      );
    }

    final total =
        widget.task.fileTotalBytes[widget.node.relativePath] ??
        widget.node.size;
    final downloaded =
        widget.task.fileDownloadedBytes[widget.node.relativePath] ?? 0;
    final retryAttempt = widget.task.isActive
        ? widget.task.fileRetryAttempts[widget.node.relativePath]
        : null;
    double progress = 0.0;
    if (total > 0) {
      progress = (downloaded / total).clamp(0.0, 1.0);
    }

    final contentStart = widget.depth == 0
        ? _rootContentInset
        : indent + _nestedContentInset;
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
              _fileIconFor(widget.node),
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
                    widget.node.title,
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
                            ? '${_formatBytes(downloaded)} / ${_formatBytes(total)}'
                            : widget.i18n.tr('asmr_download_status_retrying', {
                                'attempt': retryAttempt,
                                'max':
                                    AsmrDownloadManager.maxAutomaticFileRetries,
                              }),
                        key: retryAttempt == null
                            ? null
                            : ValueKey<String>(
                                'asmr_download_retry_${widget.node.relativePath}',
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
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
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
}
