import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/natural_sort.dart';
import '../../../../core/media/path_display.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
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

class _SessionTrackSwitcherSheetState extends State<SessionTrackSwitcherSheet> {
  final Set<String> _expandedFolders = <String>{};
  List<_QueueTreeNode> _tree = const [];
  List<({_QueueTreeNode node, int depth, String key})> _rows = const [];

  @override
  void initState() {
    super.initState();
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
  }

  void _toggleFolder(String key) {
    setState(() {
      if (!_expandedFolders.remove(key)) _expandedFolders.add(key);
      _projectRows();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ListView.builder(
        shrinkWrap: _rows.length <= 8,
        padding: AppBottomSheet.contentPadding,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: _rows.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _QueueSheetHeader(count: widget.tracks.length),
            );
          }
          final row = _rows[index - 1];
          return Padding(
            key: ValueKey<String>('queue_switcher_row_${row.key}'),
            padding: EdgeInsetsDirectional.only(start: row.depth * 16),
            child: _QueueTreeNodeTile(
              node: row.node,
              expanded: _expandedFolders.contains(row.key),
              onToggleExpansion: () => _toggleFolder(row.key),
              onTrackTap: (selected) => widget.onSelected(
                SessionTrackSelection(
                  track: selected.track!,
                  queueIndex: selected.queueIndex,
                ),
              ),
            ),
          );
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
    required this.expanded,
    required this.onToggleExpansion,
    required this.onTrackTap,
  });

  final _QueueTreeNode node;
  final bool expanded;
  final VoidCallback onToggleExpansion;
  final ValueChanged<_QueueTreeNode> onTrackTap;

  @override
  Widget build(BuildContext context) {
    if (!node.isFolder) {
      return _QueueTrackLeaf(
        track: node.track!,
        selected: node.selected,
        onTap: node.selected ? null : () => onTrackTap(node),
      );
    }

    final cs = Theme.of(context).colorScheme;
    return Semantics(
      expanded: expanded,
      child: InkWell(
        onTap: onToggleExpansion,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                  size: 19,
                  color: cs.primary.withValues(alpha: 0.78),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    node.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.9),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueTrackLeaf extends StatelessWidget {
  const _QueueTrackLeaf({
    required this.track,
    required this.selected,
    required this.onTap,
  });

  final MusicTrack track;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const borderRadius = BorderRadius.all(Radius.circular(12));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Material(
        key: ValueKey<String>('queue_switcher_track_${track.path}'),
        color: selected
            ? cs.primaryContainer.withValues(alpha: 0.24)
            : Colors.transparent,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.volume_up_rounded
                        : Icons.audio_file_rounded,
                    size: 16,
                    color: selected
                        ? cs.primary
                        : cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      track.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Text(
                    track.duration <= Duration.zero
                        ? '--:--'
                        : formatDurationCompact(track.duration),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.chevron_right_rounded,
                    size: 20,
                    color: selected
                        ? cs.primary
                        : cs.onSurfaceVariant.withValues(alpha: 0.55),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
