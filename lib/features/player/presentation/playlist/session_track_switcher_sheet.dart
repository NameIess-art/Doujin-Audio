import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/file_tree_expansion_motion.dart';
import '../../../../core/widgets/file_tree_row.dart';
import '../../../../core/widgets/playing_sound_wave_indicator.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/session_switcher_tree.dart';

class SessionTrackSelection {
  const SessionTrackSelection({required this.track, required this.queueIndex});
  final MusicTrack track;
  final int queueIndex;
}

class SessionTrackSwitcherSheet extends ConsumerStatefulWidget {
  const SessionTrackSwitcherSheet({
    super.key,
    required this.session,
    required this.trackCount,
    required this.tree,
    required this.onSelected,
  });
  final PlaybackSessionSnapshot session;
  final int trackCount;
  final SessionSwitcherTree tree;
  final ValueChanged<SessionTrackSelection> onSelected;

  @override
  ConsumerState<SessionTrackSwitcherSheet> createState() =>
      _SessionTrackSwitcherSheetState();
}

class _SessionTrackSwitcherSheetState
    extends ConsumerState<SessionTrackSwitcherSheet>
    with SingleTickerProviderStateMixin {
  late final Set<String> _expandedFolders = Set.of(widget.tree.expanded);
  late List<SessionSwitcherRow> _rows = widget.tree.rows;
  late Map<String, int> _rowIndices = widget.tree.indices;
  late final FileTreeExpansionMotion<String, SessionSwitcherRow> _motion;

  @override
  void initState() {
    super.initState();
    _motion = FileTreeExpansionMotion(this, () {
      if (mounted) setState(_motion.finish);
    });
  }

  void _projectRows() {
    final rows = <SessionSwitcherRow>[];
    void visit(SessionSwitcherNode node, int depth) {
      rows.add((node: node, depth: depth, key: node.key));
      if (_expandedFolders.contains(node.key)) {
        for (final child in node.children) {
          visit(child, depth + 1);
        }
      }
    }

    for (final node in widget.tree.roots) {
      visit(node, 0);
    }
    _rows = rows;
    _rowIndices = {
      for (var index = 0; index < rows.length; index++) rows[index].key: index,
    };
  }

  void _toggleFolder(String key) {
    setState(() {
      final progress = _motion.progressFor(key);
      _motion.finish();
      final expanding = !_expandedFolders.remove(key);
      if (expanding) _expandedFolders.add(key);
      final outgoing = expanding ? null : _rows;
      _projectRows();
      if (!MediaQuery.disableAnimationsOf(context)) {
        _motion.start(key, outgoing: outgoing, from: progress);
      }
    });
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  Widget _buildRow(SessionSwitcherRow row, int index) {
    return _motion.wrap(
      index,
      KeyedSubtree(
        key: ValueKey<String>('queue_switcher_row_${row.key}'),
        child: _QueueTreeNodeTile(
          node: row.node,
          depth: row.depth,
          expanded: _expandedFolders.contains(row.key),
          isPlaying: widget.session.playbackRequested,
          onToggleExpansion: () => _toggleFolder(row.key),
          onTrackTap: (selected) => widget.onSelected(
            SessionTrackSelection(
              track: selected.track!,
              queueIndex: selected.queueIndex,
            ),
          ),
        ),
      ),
      key: ValueKey<String>(row.key),
    );
  }

  Widget _buildContent(BuildContext context) {
    final rows = _motion.project(
      context,
      _rows,
      parentIndex: (rows, key) {
        final index = rows.indexWhere((row) => row.key == key);
        return index < 0 ? null : index;
      },
      depth: (row) => row.depth,
      minRowHeight: 44,
    );
    final indices = identical(rows, _rows)
        ? _rowIndices
        : {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    return ListView.builder(
      padding: AppBottomSheet.contentPadding,
      itemCount: rows.length + 1,
      findChildIndexCallback: (key) {
        if (key == const ValueKey<String>('queue_switcher_header')) return 0;
        final index = indices[(key as ValueKey<String>).value];
        return index == null ? null : index + 1;
      },
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            key: const ValueKey<String>('queue_switcher_header'),
            padding: const EdgeInsets.only(bottom: 6),
            child: _QueueSheetHeader(count: widget.trackCount),
          );
        }
        final rowIndex = index - 1;
        return _buildRow(rows[rowIndex], rowIndex);
      },
    ).withWindowsSmoothScroll();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height * 0.75;
        return SizedBox(
          width: double.infinity,
          height: height,
          child: _buildContent(context),
        );
      },
    );
  }
}

class _QueueSheetHeader extends StatelessWidget {
  const _QueueSheetHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return AppBottomSheetHeader(
      icon: Icons.queue_music_rounded,
      title: i18n.tr('switch_audio'),
      trailing: Text(
        count.toString(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _QueueTreeNodeTile extends StatelessWidget {
  const _QueueTreeNodeTile({
    required this.node,
    required this.depth,
    required this.expanded,
    required this.isPlaying,
    required this.onToggleExpansion,
    required this.onTrackTap,
  });

  final SessionSwitcherNode node;
  final int depth;
  final bool expanded;
  final bool isPlaying;
  final VoidCallback onToggleExpansion;
  final ValueChanged<SessionSwitcherNode> onTrackTap;

  @override
  Widget build(BuildContext context) {
    if (!node.isFolder) {
      return _QueueTrackLeaf(
        track: node.track!,
        depth: depth,
        selected: node.selected,
        isPlaying: isPlaying,
        onTap: node.selected ? null : () => onTrackTap(node),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      expanded: expanded,
      child: FileTreeRow(
        title: node.title,
        titleMaxLines: 2,
        depth: depth,
        isFolder: true,
        titleColor: cs.onSurface.withValues(alpha: 0.9),
        onTap: onToggleExpansion,
        leading: Icon(
          expanded
              ? AppDesignTokens.openFolderIcon
              : AppDesignTokens.folderIcon,
          size: AppDesignTokens.fileEntryIconSize,
          color: AppDesignTokens.folderIconColor,
        ),
        trailing: FileTreeExpansionArrow(expanded: expanded),
      ),
    );
  }
}

class _QueueTrackLeaf extends StatelessWidget {
  const _QueueTrackLeaf({
    required this.track,
    required this.depth,
    required this.selected,
    this.isPlaying = false,
    required this.onTap,
  });

  final MusicTrack track;
  final int depth;
  final bool selected;
  final bool isPlaying;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accentColor = cs.primary;
    return FileTreeRow(
      surfaceKey: ValueKey<String>('queue_switcher_track_${track.path}'),
      title: track.displayName,
      titleMaxLines: 2,
      depth: depth,
      emphasized: selected,
      backgroundColor: selected
          ? cs.primaryContainer.withValues(alpha: 0.24)
          : null,
      onTap: onTap,
      leading: track.isVideo
          ? Icon(
              Icons.videocam_outlined,
              size: AppDesignTokens.fileEntryIconSize,
              color: accentColor,
            )
          : selected && isPlaying
          ? SizedBox(
              width: AppDesignTokens.fileEntryIconSize,
              height: AppDesignTokens.fileEntryIconSize,
              child: Center(
                child: PlayingSoundWaveIndicator(color: accentColor),
              ),
            )
          : Icon(
              selected
                  ? Icons.volume_up_rounded
                  : AppDesignTokens.audioFileIcon,
              size: AppDesignTokens.fileEntryIconSize,
              color: accentColor,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              track.duration <= Duration.zero
                  ? '--:--'
                  : formatDurationCompact(track.duration),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
            size: 20,
            color: selected
                ? cs.primary
                : cs.onSurfaceVariant.withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }
}
