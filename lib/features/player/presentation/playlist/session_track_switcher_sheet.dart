import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/natural_sort.dart';
import '../../../../core/media/path_display.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/file_tree_row.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/playing_sound_wave_indicator.dart';
import '../../application/playback_session_snapshot.dart';
import '../../domain/playback_queue.dart';
import 'playlist_shared_helpers.dart';

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
  final Set<String> _expandedFolders = <String>{};
  Key _listKey = UniqueKey();
  List<_QueueTreeNode> _tree = const [];
  List<({_QueueTreeNode node, int depth, String key})> _rows = const [];
  final Map<String, int> _rowIndices = {};
  late final AnimationController _expansionController;
  late final Animation<double> _opacity;
  late final Animation<double> _sizeFactor;
  String? _animatingKey;
  int _animationStart = 0;
  int _animationCount = 0;

  @override
  void initState() {
    super.initState();
    _expansionController = AnimationController(
      vsync: this,
      duration: kAppMotionStandard,
      value: 1,
    )..addStatusListener(_handleAnimationStatus);
    _opacity = _expansionController.drive(
      CurveTween(curve: Curves.easeInOutCubic),
    );
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
    _expansionController.stop();
    _animatingKey = null;
    _listKey = UniqueKey();
    _tree = _buildQueueTree(
      widget.tracks,
      session: widget.session,
      workRoot: widget.workRoot,
      currentPath: widget.session.currentTrackPath,
    );
    final folderKeys = <String>{};
    bool visit(_QueueTreeNode node) {
      var selected = node.selected;
      for (final child in node.children) {
        if (visit(child)) selected = true;
      }
      if (node.isFolder) {
        folderKeys.add(node.key);
        if (expandSelected && selected) _expandedFolders.add(node.key);
      }
      return selected;
    }

    for (final node in _tree) {
      visit(node);
    }
    _expandedFolders.retainAll(folderKeys);
    _projectRows();
  }

  void _projectRows() {
    final rows = <({_QueueTreeNode node, int depth, String key})>[];
    void visit(_QueueTreeNode node, int depth) {
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

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ListView.builder(
        key: _listKey,
        // Keep outgoing rows until the shared reverse animation completes.
        shrinkWrap: _rows.length <= 8,
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
      ),
    );
  }

  List<_QueueTreeNode> _buildQueueTree(
    List<MusicTrack> tracks, {
    required PlaybackSessionSnapshot session,
    required String? workRoot,
    required String currentPath,
  }) {
    final root = _QueueTreeNode.folder('');
    final queueTracks = session.isPlaybackQueue
        ? tracks
        : session.customQueueTracks;
    final selectedTrack = resolveSessionSwitcherSelectedTrack(
      displayedTracks: tracks,
      queueTracks: queueTracks,
      currentPath: currentPath,
      currentQueueIndex: session.currentQueueIndex,
    );
    if (session.isPlaybackQueue) {
      final playbackTracks = session.playbackQueue!.expandedTracks;
      final preferredIndex = session.currentQueueIndex;
      final selectedQueueIndex =
          preferredIndex >= 0 &&
              preferredIndex < playbackTracks.length &&
              selectedTrack != null &&
              sameSessionSwitcherTrack(
                playbackTracks[preferredIndex],
                selectedTrack,
              )
          ? preferredIndex
          : playbackTracks.indexWhere(
              (track) => identical(track, selectedTrack),
            );
      var queueIndex = 0;
      final resolvedTracks = <String, MusicTrack?>{};
      for (final entry in session.playbackQueue!.entries) {
        final firstTrack = entry.tracks.firstOrNull;
        final isAsmrEntry = firstTrack?.isRemoteAsmr ?? false;
        final fallbackRoot = entry.workRootPath != null || firstTrack == null
            ? null
            : widget.workRootForTrack(firstTrack.path);
        final groupRoot = firstTrack?.groupKey.trim();
        final entryWorkRoot =
            entry.workRootPath ??
            fallbackRoot ??
            ((groupRoot == null ||
                    groupRoot.isEmpty ||
                    groupRoot == '__single_files__')
                ? null
                : PathMatcher.normalize(groupRoot));
        final showWorkRoot =
            firstTrack?.isSingle != true &&
            (entry.kind == PlaybackQueueEntryKind.work || isAsmrEntry);
        final parent = showWorkRoot
            ? _QueueTreeNode.folder(
                isAsmrEntry
                    ? (firstTrack!.groupTitle.trim().isEmpty
                          ? entry.title
                          : firstTrack.groupTitle)
                    : entryWorkRoot == null
                    ? entry.title
                    : PathDisplay.folderName(entryWorkRoot),
                key: 'queue:${entry.id}',
              )
            : root;
        if (!identical(parent, root)) {
          root.children.add(parent);
        }
        for (final track in entry.tracks) {
          final latestTrack = resolvedTracks.putIfAbsent(
            track.path,
            () => widget.resolveTrack(track.path),
          );
          final displayTrack =
              latestTrack != null && latestTrack.duration > Duration.zero
              ? latestTrack
              : track;
          var trackParent = parent;
          if (showWorkRoot) {
            for (final folder in _queueFolderSegments(
              track,
              workRoot: entryWorkRoot,
            )) {
              trackParent = trackParent.folderChild(folder);
            }
          }
          trackParent.children.add(
            _QueueTreeNode.track(
              displayTrack,
              selected: queueIndex == selectedQueueIndex,
              queueIndex: queueIndex,
            ),
          );
          queueIndex++;
        }
        if (!identical(parent, root)) {
          parent.sortChildrenNaturally();
        }
      }
      return root.children;
    }
    for (var index = 0; index < tracks.length; index++) {
      final track = tracks[index];
      var parent = root;
      for (final folder in _queueFolderSegments(track, workRoot: workRoot)) {
        parent = parent.folderChild(folder);
      }
      parent.children.add(
        _QueueTreeNode.track(
          track,
          selected: identical(track, selectedTrack),
          queueIndex: index,
        ),
      );
    }
    if (session.customQueueTracks == null ||
        tracks.every((track) => track.isRemoteAsmr)) {
      root.sortChildrenNaturally();
    }
    return root.children;
  }

  List<String> _queueFolderSegments(
    MusicTrack track, {
    required String? workRoot,
  }) {
    final remoteRelativePath = track.remoteMetadata?['trackRelativePath']
        ?.toString()
        .trim();
    final relativePath = remoteRelativePath?.isNotEmpty == true
        ? remoteRelativePath!
        : workRoot == null
        ? PathMatcher.relativeWithin(track.path, track.groupKey)
        : PathMatcher.relativeWithin(track.path, workRoot);
    if (relativePath == null || relativePath.isEmpty) {
      return const <String>[];
    }
    final displayPath = PathDisplay.displayPathFor(relativePath);
    final segments = displayPath
        .replaceAll('\\', '/')
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.length <= 1) return const <String>[];
    return segments.take(segments.length - 1).toList(growable: false);
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

class _QueueTreeNode {
  _QueueTreeNode.folder(this.title, {this.key = ''})
    : track = null,
      selected = false,
      queueIndex = -1;

  _QueueTreeNode.track(
    this.track, {
    required this.selected,
    required this.queueIndex,
  }) : title = track!.displayName,
       key = 'track:$queueIndex:${track.path}';

  final String title;
  final String key;
  final MusicTrack? track;
  final bool selected;
  final int queueIndex;
  final List<_QueueTreeNode> children = <_QueueTreeNode>[];

  bool get isFolder => track == null;
  Map<String, _QueueTreeNode>? _foldersByName;

  _QueueTreeNode folderChild(String name) {
    return (_foldersByName ??= <String, _QueueTreeNode>{}).putIfAbsent(
      name,
      () {
        final folder = _QueueTreeNode.folder(
          name,
          key: '$key/${Uri.encodeComponent(name)}',
        );
        children.add(folder);
        return folder;
      },
    );
  }

  void sortChildrenNaturally() {
    for (final child in children) {
      child.sortChildrenNaturally();
    }
    children.sort(
      (left, right) => compareNaturalTreeEntries(
        leftIsFolder: left.isFolder,
        leftName: left.title,
        leftPath: left.track?.path ?? left.title,
        rightIsFolder: right.isFolder,
        rightName: right.title,
        rightPath: right.track?.path ?? right.title,
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

  final _QueueTreeNode node;
  final int depth;
  final bool expanded;
  final bool isPlaying;
  final VoidCallback onToggleExpansion;
  final ValueChanged<_QueueTreeNode> onTrackTap;

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
    final accentColor = track.usesAsmrVisualTheme
        ? AppDesignTokens.of(context).asmrAccent
        : cs.primary;
    return FileTreeRow(
      surfaceKey: ValueKey<String>('queue_switcher_track_${track.path}'),
      title: track.displayName,
      depth: depth,
      emphasized: selected,
      backgroundColor: selected
          ? cs.primaryContainer.withValues(alpha: 0.24)
          : null,
      onTap: onTap,
      leading: selected && isPlaying
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
