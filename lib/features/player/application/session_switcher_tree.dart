import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../asmr/domain/asmr_models.dart' show withoutJapaneseAsmrSiteFolder;
import '../domain/playback_queue.dart';

typedef SessionSwitcherRow = ({
  SessionSwitcherNode node,
  int depth,
  String key,
});
typedef SessionSwitcherTree = ({
  List<SessionSwitcherNode> roots,
  List<SessionSwitcherRow> rows,
  Map<String, int> indices,
  Set<String> expanded,
});
typedef _SwitcherRequest = ({
  List<MusicTrack> tracks,
  PlaybackQueueDefinition? queue,
  List<MusicTrack>? customQueueTracks,
  String currentPath,
  int currentQueueIndex,
  int selectedIndex,
  String? workRoot,
  Map<String, MusicTrack?> resolvedTracks,
  Map<String, String?> workRoots,
});

// Small queues can render on the first frame without starting an isolate.
const _inlineSwitcherTrackLimit = 64;

Future<SessionSwitcherTree> prepareSessionSwitcherTree({
  required List<MusicTrack> tracks,
  required PlaybackQueueDefinition? queue,
  required List<MusicTrack>? customQueueTracks,
  required String currentPath,
  required int currentQueueIndex,
  required String? workRoot,
  required MusicTrack? Function(String) resolveTrack,
  required String? Function(String) workRootForTrack,
}) async {
  final buildInline = tracks.length <= _inlineSwitcherTrackLimit;
  final resolvedTracks = <String, MusicTrack?>{};
  final workRoots = <String, String?>{};
  final budget = Stopwatch()..start();
  if (queue != null) {
    for (final entry in queue.entries) {
      final first = entry.tracks.firstOrNull;
      if (entry.workRootPath == null && first != null) {
        workRoots[first.path] = workRootForTrack(first.path);
      }
      for (final track in entry.tracks) {
        resolvedTracks.putIfAbsent(track.path, () => resolveTrack(track.path));
        if (!buildInline && budget.elapsedMicroseconds >= 1000) {
          await Future<void>.delayed(Duration.zero);
          budget.reset();
        }
      }
    }
  }
  final orderedTracks = orderTracksForSessionSwitcher(
    tracks,
    preserveQueueOrder: queue != null,
  );
  final selectedTrack = resolveSessionSwitcherSelectedTrack(
    displayedTracks: orderedTracks,
    queueTracks: queue != null ? orderedTracks : customQueueTracks,
    currentPath: currentPath,
    currentQueueIndex: currentQueueIndex,
  );
  final int selectedIndex;
  if (queue != null) {
    final playbackTracks = queue.expandedTracks;
    final preferredIndex = currentQueueIndex;
    selectedIndex =
        preferredIndex >= 0 &&
            preferredIndex < playbackTracks.length &&
            selectedTrack != null &&
            sameSessionSwitcherTrack(
              playbackTracks[preferredIndex],
              selectedTrack,
            )
        ? preferredIndex
        : selectedTrack == null
        ? -1
        : playbackTracks.indexWhere((track) => identical(track, selectedTrack));
  } else {
    selectedIndex = selectedTrack == null
        ? -1
        : orderedTracks.indexWhere((track) => identical(track, selectedTrack));
  }
  final request = (
    tracks: tracks,
    queue: queue,
    customQueueTracks: customQueueTracks,
    currentPath: currentPath,
    currentQueueIndex: currentQueueIndex,
    selectedIndex: selectedIndex,
    workRoot: workRoot,
    resolvedTracks: resolvedTracks,
    workRoots: workRoots,
  );
  if (buildInline) return _prepareSwitcherSnapshot(request);

  final tree = await compute(_prepareSwitcherSnapshot, request);
  // Workers return topology; selection still uses the original track objects.
  final pending = <SessionSwitcherNode>[...tree.roots];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node.sourceIndex >= 0) {
      final original = tracks[node.sourceIndex];
      final latest = resolvedTracks[original.path];
      node.track = latest != null && latest.duration > Duration.zero
          ? latest
          : original;
    }
    pending.addAll(node.children);
    if (budget.elapsedMicroseconds >= 1000) {
      await Future<void>.delayed(Duration.zero);
      budget.reset();
    }
  }
  return tree;
}

SessionSwitcherTree _prepareSwitcherSnapshot(_SwitcherRequest request) {
  final roots = _buildQueueTree(request);
  final expanded = <String>{};
  bool visit(SessionSwitcherNode node) {
    var selected = node.selected;
    for (final child in node.children) {
      if (visit(child)) selected = true;
    }
    if (node.isFolder && selected) {
      expanded.add(node.key);
    }
    return selected;
  }

  for (final root in roots) {
    visit(root);
  }
  final rows = <SessionSwitcherRow>[];
  final indices = <String, int>{};
  void flatten(SessionSwitcherNode node, int depth) {
    indices[node.key] = rows.length;
    rows.add((node: node, depth: depth, key: node.key));
    if (expanded.contains(node.key)) {
      for (final child in node.children) {
        flatten(child, depth + 1);
      }
    }
  }

  for (final root in roots) {
    flatten(root, 0);
  }
  return (roots: roots, rows: rows, indices: indices, expanded: expanded);
}

List<SessionSwitcherNode> _buildQueueTree(_SwitcherRequest request) {
  final tracks = orderTracksForSessionSwitcher(
    request.tracks,
    preserveQueueOrder: request.queue != null,
  );
  final workRoot = request.workRoot;
  final sourceIndices = Map<MusicTrack, int>.identity();
  for (var i = 0; i < request.tracks.length; i++) {
    sourceIndices[request.tracks[i]] = i;
  }
  final root = SessionSwitcherNode.folder('');
  if (request.queue != null) {
    final selectedQueueIndex = request.selectedIndex;
    var queueIndex = 0;

    for (final entry in request.queue!.entries) {
      final firstTrack = entry.tracks.firstOrNull;
      final isAsmrEntry = firstTrack?.isRemoteAsmr ?? false;
      final fallbackRoot = entry.workRootPath != null || firstTrack == null
          ? null
          : request.workRoots[firstTrack.path];
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
          ? SessionSwitcherNode.folder(
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
        final latestTrack = request.resolvedTracks[track.path];
        final displayTrack =
            latestTrack != null && latestTrack.duration > Duration.zero
            ? latestTrack
            : track;
        final trackParent = showWorkRoot
            ? parent.folderForTrack(track, workRoot: entryWorkRoot)
            : parent;
        trackParent.children.add(
          SessionSwitcherNode.track(
            displayTrack,
            selected: queueIndex == selectedQueueIndex,
            queueIndex: queueIndex,
            sourceIndex: queueIndex,
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
    final parent = root.folderForTrack(track, workRoot: workRoot);
    parent.children.add(
      SessionSwitcherNode.track(
        track,
        selected: index == request.selectedIndex,
        queueIndex: index,
        sourceIndex: sourceIndices[track]!,
      ),
    );
  }
  if (request.customQueueTracks == null ||
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
  final displayPath = withoutJapaneseAsmrSiteFolder(
    PathDisplay.displayPathFor(relativePath),
  );
  final segments = displayPath
      .replaceAll('\\', '/')
      .split('/')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.length <= 1) return const <String>[];
  return segments.take(segments.length - 1).toList(growable: false);
}

class SessionSwitcherNode {
  SessionSwitcherNode.folder(this.title, {this.key = ''})
    : track = null,
      selected = false,
      queueIndex = -1,
      sourceIndex = -1;

  SessionSwitcherNode.track(
    this.track, {
    required this.selected,
    required this.queueIndex,
    required this.sourceIndex,
  }) : title = track!.displayName,
       key = 'track:$queueIndex:${track.path}';

  final String title;
  final String key;
  MusicTrack? track;
  final int sourceIndex;
  final bool selected;
  final int queueIndex;
  final List<SessionSwitcherNode> children = <SessionSwitcherNode>[];

  bool get isFolder => track == null;
  Map<String, SessionSwitcherNode>? _foldersByName;
  Map<(String?, String), SessionSwitcherNode>? _foldersByParentDir;

  SessionSwitcherNode folderForTrack(MusicTrack track, {String? workRoot}) {
    final remoteRelative = track.remoteMetadata?['trackRelativePath']
        ?.toString()
        .trim();
    if (remoteRelative != null && remoteRelative.isNotEmpty) {
      final sep = math.max(
        remoteRelative.lastIndexOf('/'),
        remoteRelative.lastIndexOf('\\'),
      );
      if (sep < 0) return this;
      final dir = remoteRelative.substring(0, sep);
      return (_foldersByParentDir ??=
              <(String?, String), SessionSwitcherNode>{})
          .putIfAbsent(
            ('remote', dir),
            () => _resolveFoldersForTrack(track, workRoot: workRoot),
          );
    }
    if (!track.path.contains('%')) {
      final sep = math.max(
        track.path.lastIndexOf('/'),
        track.path.lastIndexOf('\\'),
      );
      if (sep >= 0) {
        final dir = track.path.substring(0, sep);
        return (_foldersByParentDir ??=
                <(String?, String), SessionSwitcherNode>{})
            .putIfAbsent(
              (workRoot ?? track.groupKey, dir),
              () => _resolveFoldersForTrack(track, workRoot: workRoot),
            );
      }
    }
    return _resolveFoldersForTrack(track, workRoot: workRoot);
  }

  SessionSwitcherNode _resolveFoldersForTrack(
    MusicTrack track, {
    String? workRoot,
  }) {
    var parent = this;
    for (final folder in _queueFolderSegments(track, workRoot: workRoot)) {
      parent = parent.folderChild(folder);
    }
    return parent;
  }

  SessionSwitcherNode folderChild(String name) {
    return (_foldersByName ??= <String, SessionSwitcherNode>{}).putIfAbsent(
      name,
      () {
        final folder = SessionSwitcherNode.folder(
          name,
          key: '$key/${Uri.encodeComponent(name)}',
        );
        children.add(folder);
        return folder;
      },
    );
  }

  void sortChildrenNaturally() {
    if (children.isEmpty) return;
    for (final child in children) {
      if (child.isFolder) child.sortChildrenNaturally();
    }
    if (children.length < 2) return;
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

List<MusicTrack> orderTracksForSessionSwitcher(
  List<MusicTrack> tracks, {
  required bool preserveQueueOrder,
}) {
  if (preserveQueueOrder ||
      tracks.length < 2 ||
      !tracks.every((track) => track.isRemoteAsmr)) {
    return tracks;
  }
  final sorted = List<MusicTrack>.of(tracks);
  sorted.sort((left, right) {
    final leftPath = left.remoteMetadata?['trackRelativePath']?.toString();
    final rightPath = right.remoteMetadata?['trackRelativePath']?.toString();
    final pathResult = compareNatural(
      leftPath?.trim().isNotEmpty == true ? leftPath!.trim() : left.displayName,
      rightPath?.trim().isNotEmpty == true
          ? rightPath!.trim()
          : right.displayName,
    );
    if (pathResult != 0) return pathResult;
    return compareNatural(left.path, right.path, caseSensitive: true);
  });
  return List<MusicTrack>.unmodifiable(sorted);
}

MusicTrack? resolveSessionSwitcherSelectedTrack({
  required List<MusicTrack> displayedTracks,
  required List<MusicTrack>? queueTracks,
  required String currentPath,
  required int currentQueueIndex,
}) {
  for (final track in displayedTracks) {
    if (PathMatcher.equalsNormalized(track.path, currentPath)) return track;
  }
  if (queueTracks == null ||
      currentQueueIndex < 0 ||
      currentQueueIndex >= queueTracks.length) {
    return null;
  }
  final queuedTrack = queueTracks[currentQueueIndex];
  if (!queuedTrack.isRemoteAsmr) return null;
  for (final track in displayedTracks) {
    if (sameSessionSwitcherTrack(track, queuedTrack)) return track;
  }
  return null;
}

bool sameSessionSwitcherTrack(MusicTrack left, MusicTrack right) {
  if (identical(left, right) ||
      PathMatcher.equalsNormalized(left.path, right.path)) {
    return true;
  }
  if (!left.isRemoteAsmr || !right.isRemoteAsmr) {
    return false;
  }
  final leftRelative = left.remoteMetadata?['trackRelativePath']
      ?.toString()
      .trim();
  final rightRelative = right.remoteMetadata?['trackRelativePath']
      ?.toString()
      .trim();
  if (leftRelative == null ||
      leftRelative.isEmpty ||
      rightRelative == null ||
      rightRelative.isEmpty ||
      _normalizedRemoteRelativePath(leftRelative) !=
          _normalizedRemoteRelativePath(rightRelative)) {
    return false;
  }
  final leftWorkId = left.remoteMetadata?['id']?.toString().trim();
  final rightWorkId = right.remoteMetadata?['id']?.toString().trim();
  if (leftWorkId?.isNotEmpty == true && rightWorkId?.isNotEmpty == true) {
    return leftWorkId == rightWorkId;
  }
  return left.groupKey.isNotEmpty && left.groupKey == right.groupKey;
}

String _normalizedRemoteRelativePath(String value) =>
    path.posix.normalize(value.replaceAll('\\', '/'));
