import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/asmr_models.dart';
import '../services/asmr_download_manager.dart';
import '../theme/app_design_tokens.dart';
import '../widgets/top_page_header.dart';

class AsmrDownloadDetailsPage extends StatelessWidget {
  const AsmrDownloadDetailsPage({super.key, required this.workId});

  final int workId;

  @override
  Widget build(BuildContext context) {
    final task = context.select<AsmrDownloadManager, AsmrDownloadTaskSnapshot?>(
      (manager) => manager.getTask(workId),
    );
    final headerHeight = MediaQuery.paddingOf(context).top + 56;
    final cs = Theme.of(context).colorScheme;

    if (task == null) {
      return const Scaffold(
        body: Stack(
          children: [
            Center(child: Text('Task not found')),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                leading: BackButton(),
                title: 'Download Details',
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
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('No files selected')),
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
                      );
                    },
                  ),
                ),
            ],
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(leading: BackButton(), title: ''),
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
  });

  final AsmrTrackFile node;
  final int depth;
  final AsmrDownloadTaskSnapshot task;

  @override
  State<_AsmrDownloadDetailsNodeTile> createState() =>
      _AsmrDownloadDetailsNodeTileState();
}

class _AsmrDownloadDetailsNodeTileState
    extends State<_AsmrDownloadDetailsNodeTile> {
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
    final indent = widget.depth * 16.0;
    const fileRowHeight = 44.0;

    if (widget.node.isFolder) {
      final hasChildren = widget.node.children.isNotEmpty;
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _expanded,
          onExpansionChanged: (v) => _toggleExpanded(),
          tilePadding: EdgeInsetsDirectional.only(start: indent + 16, end: 16),
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
                    ),
                ]
              : [
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: indent + 16 + 40,
                      end: 8,
                      bottom: 8,
                    ),
                    child: Text(
                      'Empty folder',
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
    double progress = 0.0;
    if (total > 0) {
      progress = (downloaded / total).clamp(0.0, 1.0);
    }

    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: indent + 16 + 24,
        end: 16,
        top: 4,
        bottom: 4,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
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
                        '${_formatBytes(downloaded)} / ${_formatBytes(total)}',
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
