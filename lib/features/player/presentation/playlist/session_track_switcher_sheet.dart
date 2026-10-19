import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/file_tree_row.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/playing_sound_wave_indicator.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/session_switcher_tree.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';

class SessionTrackSelection {
  const SessionTrackSelection({required this.track, required this.queueIndex});
  final MusicTrack track;
  final int queueIndex;
}

class SessionTrackSwitcherSheet extends StatefulWidget {
  const SessionTrackSwitcherSheet({
    super.key,
    required this.session,
    required this.tracks,
    required this.workRoot,
    required this.resolveTrack,
    required this.workRootForTrack,
    required this.onSelected,
  });
  final PlaybackSessionSnapshot session;
  final List<MusicTrack> tracks;
  final String? workRoot;
  final MusicTrack? Function(String path) resolveTrack;
  final String? Function(String path) workRootForTrack;
  final ValueChanged<SessionTrackSelection> onSelected;

  @override
  State<SessionTrackSwitcherSheet> createState() =>
      _SessionTrackSwitcherSheetState();
}

class _SessionTrackSwitcherSheetState extends State<SessionTrackSwitcherSheet>
    with SingleTickerProviderStateMixin {
  Set<String> _expandedFolders = <String>{};
  Key _listKey = UniqueKey();
  List<SessionSwitcherNode> _tree = const [];
  List<({SessionSwitcherNode node, int depth, String key})> _rows = const [];
  Map<String, int> _rowIndices = {};
  late final AnimationController _expansionController;
  late final Animation<double> _opacity;
  late final Animation<double> _sizeFactor;
  int _treeRequest = 0;
  bool _loading = true;
  Object? _treeError;
  String get _treeCommitKey => 'switcher_tree_${identityHashCode(this)}';
  String? _animatingKey;
  int _animationStart = 0;
  int _animationCount = 0;

  @override
  void initState() {
    super.initState();
    _expansionController = AnimationController(
      vsync: this,
      duration: kAppFadeDuration,
      value: 1,
    )..addStatusListener(_handleAnimationStatus);
    _opacity = _expansionController.drive(CurveTween(curve: kAppFadeCurve));
    // Non-zero row extents keep the lazy viewport bounded during expansion.
    _sizeFactor = _opacity.drive(Tween<double>(begin: 0.2, end: 1));
    _rebuildTree(expandSelected: true);
  }

  @override
  void didUpdateWidget(covariant SessionTrackSwitcherSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        !identical(oldWidget.tracks, widget.tracks) ||
        oldWidget.workRoot != widget.workRoot ||
        oldWidget.resolveTrack != widget.resolveTrack ||
        oldWidget.workRootForTrack != widget.workRootForTrack) {
      _rebuildTree(
        expandSelected:
            oldWidget.session.currentTrackPath !=
                widget.session.currentTrackPath ||
            oldWidget.session.currentQueueIndex !=
                widget.session.currentQueueIndex,
      );
    }
  }

  void _rebuildTree({required bool expandSelected}) {
    final request = ++_treeRequest;
    _loading = true;
    _treeError = null;
    _expansionController.stop();
    _animatingKey = null;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _treeCommitKey,
      commit: () => unawaited(_loadTree(request, expandSelected)),
    );
  }

  Future<void> _loadTree(int request, bool expandSelected) async {
    try {
      final tree = await prepareSessionSwitcherTree(
        tracks: widget.tracks,
        queue: widget.session.playbackQueue,
        customQueueTracks: widget.session.customQueueTracks,
        currentPath: widget.session.currentTrackPath,
        currentQueueIndex: widget.session.currentQueueIndex,
        workRoot: widget.workRoot,
        resolveTrack: widget.resolveTrack,
        workRootForTrack: widget.workRootForTrack,
        expanded: Set.of(_expandedFolders),
        expandSelected: expandSelected,
      );
      if (!mounted || request != _treeRequest) return;
      UiInteractionCoordinator.instance.scheduleCommit(
        key: _treeCommitKey,
        structural: true,
        commit: () {
          if (!mounted || request != _treeRequest) return;
          setState(() {
            _tree = tree.roots;
            _rows = tree.rows;
            _rowIndices = tree.indices;
            _expandedFolders = tree.expanded;
            _listKey = UniqueKey();
            _loading = false;
          });
        },
      );
    } catch (error) {
      if (!mounted || request != _treeRequest) return;
      setState(() {
        _treeError = error;
        _loading = false;
      });
    }
  }

  void _projectRows() {
    final rows = <({SessionSwitcherNode node, int depth, String key})>[];
    void visit(SessionSwitcherNode node, int depth) {
      rows.add((node: node, depth: depth, key: node.key));
      if (_expandedFolders.contains(node.key)) {
        for (final child in node.children) {
          visit(child, depth + 1);
        }
      }
    }

    for (final node in _tree) {
      visit(node, 0);
    }
    _rows = rows;
    _rowIndices.clear();
    for (var index = 0; index < rows.length; index++) {
      _rowIndices[rows[index].key] = index;
    }
  }

  void _finishAnimation() {
    _expansionController.stop();
    _animatingKey = null;
    _projectRows();
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (_animatingKey != null &&
        (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed)) {
      setState(_finishAnimation);
    }
  }

  void _toggleFolder(String key) {
    setState(() {
      if (_animatingKey != null && _animatingKey != key) {
        _finishAnimation();
      }
      if (!_expandedFolders.remove(key)) _expandedFolders.add(key);
      if (MediaQuery.disableAnimationsOf(context)) {
        _finishAnimation();
        return;
      }
      final expanding = _expandedFolders.contains(key);
      if (_animatingKey != key) {
        final folderIndex = _rowIndices[key]!;
        final previousCount = _rows.length;
        if (expanding) _projectRows();
        _animationStart = folderIndex + 1;
        if (expanding) {
          _animationCount = _rows.length - previousCount;
        } else {
          final depth = _rows[folderIndex].depth;
          var end = _animationStart;
          while (end < _rows.length && _rows[end].depth > depth) {
            end++;
          }
          _animationCount = end - _animationStart;
        }
        if (_animationCount == 0) return;
        _expansionController.value = expanding ? 0 : 1;
        _animatingKey = key;
      }
      if (expanding) {
        _expansionController.forward();
      } else {
        _expansionController.reverse();
      }
    });
  }

  @override
  void dispose() {
    _treeRequest++;
    UiInteractionCoordinator.instance.cancelCommit(_treeCommitKey);
    _expansionController.dispose();
    super.dispose();
  }

  Widget _buildRow(int index) {
    final row = _rows[index];
    final animating =
        _animatingKey != null &&
        index >= _animationStart &&
        index < _animationStart + _animationCount;
    final collapsing = animating && !_expandedFolders.contains(_animatingKey);
    return SizeTransition(
      key: ValueKey<String>(row.key),
      sizeFactor: animating ? _sizeFactor : const AlwaysStoppedAnimation(1),
      axisAlignment: -1,
      child: FadeTransition(
        opacity: animating ? _opacity : const AlwaysStoppedAnimation(1),
        child: IgnorePointer(
          ignoring: collapsing,
          child: ExcludeSemantics(
            excluding: collapsing,
            child: KeyedSubtree(
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
          ),
        ),
      ),
    );
  }

  Widget _buildSkeleton(BuildContext context) {
    return Padding(
      padding: AppBottomSheet.contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: const ValueKey<String>('queue_switcher_skeleton_header'),
            padding: const EdgeInsets.only(bottom: 6),
            child: _QueueSheetHeader(count: widget.tracks.length),
          ),
          const Expanded(
            child: RepaintBoundary(
              key: ValueKey<String>('queue_switcher_skeleton'),
              child: FileTreeSkeleton(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return Padding(
      padding: AppBottomSheet.contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: const ValueKey<String>('queue_switcher_error_header'),
            padding: const EdgeInsets.only(bottom: 6),
            child: _QueueSheetHeader(count: widget.tracks.length),
          ),
          Expanded(
            child: Center(
              child: TextButton(
                onPressed: () =>
                    setState(() => _rebuildTree(expandSelected: true)),
                child: Text(i18n.tr('retry')),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return ListView.builder(
      key: _listKey,
      padding: AppBottomSheet.contentPadding,
      itemCount: _rows.length + 1,
      findChildIndexCallback: (key) {
        if (key == const ValueKey<String>('queue_switcher_header')) return 0;
        final index = _rowIndices[(key as ValueKey<String>).value];
        return index == null ? null : index + 1;
      },
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            key: const ValueKey<String>('queue_switcher_header'),
            padding: const EdgeInsets.only(bottom: 6),
            child: _QueueSheetHeader(count: widget.tracks.length),
          );
        }
        return _buildRow(index - 1);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height * 0.75;
        return SizedBox(
          width: double.infinity,
          height: height,
          child: _treeError != null
              ? _buildError(context)
              : PlaceholderContentTransition(
                  showPlaceholder: _loading,
                  placeholder: _buildSkeleton(context),
                  content: _buildContent(context),
                ),
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
          fontFeatures: const [FontFeature.tabularFigures()],
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
                fontFeatures: const [FontFeature.tabularFigures()],
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
