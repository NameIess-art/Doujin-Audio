import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/natural_sort.dart';
import '../../../../core/media/path_display.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../application/playback_session_snapshot.dart';
import '../../domain/playback_queue.dart';
import 'playlist_shared_helpers.dart';

class SessionTrackSelection {
  const SessionTrackSelection({required this.track, required this.queueIndex});
  final MusicTrack track;
  final int queueIndex;
}

class SessionTrackSwitcherSheet extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final tree = _buildQueueTree(
      tracks,
      session: session,
      workRoot: workRoot,
      currentPath: session.currentTrackPath,
    );
    return SizedBox(
      width: double.infinity,
      child: ListView.builder(
        shrinkWrap: tree.length <= 8,
        padding: AppBottomSheet.contentPadding,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: tree.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _QueueSheetHeader(count: tracks.length),
            );
          }
          final node = tree[index - 1];
          return _QueueTreeNodeTile(
            key: ValueKey<String>(node.stableKey),
            node: node,
            onTrackTap: (selected) => onSelected(
              SessionTrackSelection(
                track: selected.track!,
                queueIndex: selected.queueIndex,
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
      var queueIndex = 0;
      final resolvedTracks = <String, MusicTrack?>{};
      for (final entry in session.playbackQueue!.entries) {
        final firstTrack = entry.tracks.firstOrNull;
        final isAsmrEntry = firstTrack?.isRemoteAsmr ?? false;
        final fallbackRoot = entry.workRootPath != null || firstTrack == null
            ? null
            : workRootForTrack(firstTrack.path);
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
              )
            : root;
        if (!identical(parent, root)) {
          root.children.add(parent);
        }
        for (final track in entry.tracks) {
          final latestTrack = resolvedTracks.putIfAbsent(
            track.path,
            () => resolveTrack(track.path),
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
              selected: identical(track, selectedTrack),
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
  _QueueTreeNode.folder(this.title)
    : track = null,
      selected = false,
      queueIndex = -1;

  _QueueTreeNode.track(
    this.track, {
    required this.selected,
    required this.queueIndex,
  }) : title = track!.displayName;

  final String title;
  final MusicTrack? track;
  final bool selected;
  final int queueIndex;
  final List<_QueueTreeNode> children = <_QueueTreeNode>[];

  bool get isFolder => track == null;
  String get stableKey => isFolder ? 'folder:$title' : 'track:${track!.path}';
  bool get containsSelected =>
      selected || children.any((child) => child.containsSelected);

  _QueueTreeNode folderChild(String name) {
    for (final child in children) {
      if (child.isFolder && child.title == name) return child;
    }
    final folder = _QueueTreeNode.folder(name);
    children.add(folder);
    return folder;
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

class _QueueTreeNodeTile extends StatefulWidget {
  const _QueueTreeNodeTile({
    super.key,
    required this.node,
    required this.onTrackTap,
  });

  final _QueueTreeNode node;
  final ValueChanged<_QueueTreeNode> onTrackTap;

  @override
  State<_QueueTreeNodeTile> createState() => _QueueTreeNodeTileState();
}

class _QueueTreeNodeTileState extends State<_QueueTreeNodeTile> {
  final _controller = ExpansibleController();
  late bool _expanded = widget.node.containsSelected;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _QueueTreeNodeTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.stableKey != widget.node.stableKey ||
        widget.node.containsSelected) {
      _expanded = widget.node.containsSelected;
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    if (!node.isFolder) {
      return _QueueTrackLeaf(
        track: node.track!,
        selected: node.selected,
        onTap: node.selected ? null : () => widget.onTrackTap(node),
      );
    }

    final cs = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        controller: _controller,
        expansionAnimationStyle: appExpansionAnimationStyle(context),
        initiallyExpanded: _expanded,
        minTileHeight: 52,
        onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
        shape: const RoundedRectangleBorder(),
        collapsedShape: const RoundedRectangleBorder(),
        showTrailingIcon: false,
        tilePadding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 0, 0),
        title: Row(
          children: [
            Icon(
              _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
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
          ],
        ),
        trailing: AnimatedRotation(
          turns: _expanded ? 0.5 : 0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: Icon(
            Icons.expand_more_rounded,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
        ),
        children: [
          // ExpansionTile mounts this builder only while its body is visible,
          // including the reverse animation when collapsing.
          Builder(
            builder: (_) => Column(
              children: [
                for (final child in node.children)
                  _QueueTreeNodeTile(
                    key: ValueKey<String>(child.stableKey),
                    node: child,
                    onTrackTap: widget.onTrackTap,
                  ),
              ],
            ),
          ),
        ],
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
