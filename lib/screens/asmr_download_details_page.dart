import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/asmr_models.dart';
import '../services/asmr_download_manager.dart';

class AsmrDownloadDetailsPage extends StatelessWidget {
  const AsmrDownloadDetailsPage({super.key, required this.workId});

  final int workId;

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<AsmrDownloadManager>();
    final task = manager.getTask(workId);

    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Download Details')),
        body: const Center(child: Text('Task not found')),
      );
    }

    final tracks = task.selectedRoots;

    return Scaffold(
      appBar: AppBar(
        title: Text(task.work.title),
      ),
      body: tracks.isEmpty
          ? const Center(child: Text('No files selected'))
          : ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                return _AsmrDownloadDetailsNodeTile(
                  node: tracks[index],
                  depth: 0,
                  task: task,
                );
              },
            ),
    );
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
    final indent = widget.depth * 24.0;
    const fileRowHeight = 56.0;

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
          title: Text(
            widget.node.title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          leading: Icon(
            _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
            color: cs.onSurfaceVariant,
            size: 20,
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
                      start: indent + 24 + 40,
                      end: 8,
                      bottom: 4,
                    ),
                    child: Text(
                      'Empty folder',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
        ),
      );
    }

    final total = widget.task.fileTotalBytes[widget.node.relativePath] ?? widget.node.size;
    final downloaded = widget.task.fileDownloadedBytes[widget.node.relativePath] ?? 0;
    double progress = 0.0;
    if (total > 0) {
      progress = (downloaded / total).clamp(0.0, 1.0);
    }

    return SizedBox(
      height: fileRowHeight + 16,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: indent + 16 + 24, end: 16, top: 4, bottom: 4),
        child: Row(
          children: [
            Icon(
              _fileIconFor(widget.node),
              size: 20,
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
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
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${_formatBytes(downloaded)} / ${_formatBytes(total)}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
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
