import 'dart:isolate';

import 'package:path/path.dart' as path;
import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import '../domain/library_entry.dart';

// Only immutable models and disk snapshots cross the isolate boundary. Never
// capture a facade, provider container or Widget State in the worker closure.
class LibraryEditTreeRequest {
  const LibraryEditTreeRequest({
    required this.libraryPath,
    required this.tracks,
    required this.diskTrackPaths,
    required this.diskTrackPathSet,
    required this.diskTrackParents,
    required this.liveFolders,
    required this.authoritative,
    required this.excludedTracks,
    required this.excludedFolders,
    required this.entries,
    required this.childFolders,
    required this.restoringFolders,
  });

  final String libraryPath;
  final List<MusicTrack> tracks;
  final List<String> diskTrackPaths;
  final Set<String> diskTrackPathSet;
  final Map<String, String> diskTrackParents;
  final Set<String> liveFolders;
  final bool authoritative;
  final List<String> excludedTracks;
  final List<String> excludedFolders;
  final List<LibraryEntry> entries;
  final List<String> childFolders;
  final List<LibraryEditFolderTreeNode> restoringFolders;

  Future<LibraryEditTreeSnapshot> project() {
    if (tracks.length + diskTrackPaths.length + entries.length < 512) {
      return Future.value(_projectLibraryEditTree(this));
    }
    return Isolate.run(() => _projectLibraryEditTree(this));
  }
}

class LibraryEditTreeSnapshot {
  const LibraryEditTreeSnapshot(this.libraryPath, this.nodes, this.searchText);

  final String libraryPath;
  final List<LibraryEditTreeNode> nodes;
  final Map<String, String> searchText;

  Future<List<LibraryEditTreeNode>> filter(String query) {
    if (query.isEmpty) return Future.value(nodes);
    if (searchText.length < 512) {
      return Future.value(_filter(query));
    }
    return Isolate.run(() => _filter(query));
  }

  List<LibraryEditTreeNode> _filter(String query) =>
      LibraryEditTreeProjection(libraryPath).filterEditTree(
        nodes,
        query,
        (track, normalizedQuery) =>
            (searchText[track] ?? '').contains(normalizedQuery),
      );
}

LibraryEditTreeSnapshot _projectLibraryEditTree(
  LibraryEditTreeRequest request,
) {
  final projection = LibraryEditTreeProjection(request.libraryPath);
  bool trackExists(String track) =>
      !request.authoritative ||
      request.diskTrackPathSet.contains(PathMatcher.normalize(track));
  bool belongs(String track) =>
      request.diskTrackParents.containsKey(PathMatcher.normalize(track)) ||
      PathMatcher.isWithinOrEqual(track, request.libraryPath);
  bool folderExists(String folder) =>
      !request.authoritative ||
      PathMatcher.equalsNormalized(folder, request.libraryPath) ||
      request.liveFolders.contains(PathMatcher.normalize(folder));
  final entries = request.entries
      .where(
        (entry) => entry.isFolder
            ? folderExists(projection.folderPathForLibraryChild(entry.path))
            : trackExists(entry.path),
      )
      .toList(growable: false);
  final tracksByPath = <String, MusicTrack>{};
  final paths = <String>{};
  for (final track in request.tracks) {
    if (!belongs(track.path) || !trackExists(track.path)) continue;
    final normalized = PathMatcher.normalize(track.path);
    paths.add(normalized);
    tracksByPath[PathMatcher.equivalenceKey(normalized)] = track;
  }
  for (final track in <String>[
    for (final entry in entries)
      if (entry.isTrack) entry.path,
    ...request.diskTrackPaths,
    ...request.excludedTracks.where(trackExists),
  ]) {
    if (belongs(track)) paths.add(PathMatcher.normalize(track));
  }
  final nodes = projection.buildEditTree(
    paths.toList(growable: false),
    <String>{
      for (final folder in [
        ...request.childFolders,
        ...request.excludedFolders,
      ])
        if (folderExists(projection.folderPathForLibraryChild(folder)))
          projection.folderPathForLibraryChild(folder),
      for (final entry in entries)
        if (entry.isFolder) projection.folderPathForLibraryChild(entry.path),
    }.toList(growable: false),
    request.restoringFolders
        .where((node) => folderExists(node.folderPath))
        .toList(growable: false),
    trackParentPaths: {
      for (final entry in entries)
        if (entry.isTrack)
          PathMatcher.normalize(entry.path):
              entry.parentPath ?? request.libraryPath,
      ...request.diskTrackParents,
    },
  );
  final searchText = <String, String>{};
  void index(List<LibraryEditTreeNode> nodes) {
    for (final node in nodes) {
      if (node is LibraryEditFolderTreeNode) {
        index(node.children);
      } else {
        final track = tracksByPath[PathMatcher.equivalenceKey(node.pathValue)];
        searchText[node.pathValue] = <String>[
          path.basenameWithoutExtension(node.pathValue),
          node.pathValue,
          if (track != null) ...[
            track.displayName,
            track.groupTitle,
            track.groupSubtitle,
          ],
        ].join('\u0000').toLowerCase();
      }
    }
  }

  index(nodes);
  return LibraryEditTreeSnapshot(request.libraryPath, nodes, searchText);
}

abstract class LibraryEditTreeNode {
  String get name;
  String get pathValue;
}

class LibraryEditFolderTreeNode extends LibraryEditTreeNode {
  LibraryEditFolderTreeNode({
    required this.folderPath,
    required this.depth,
    List<LibraryEditTreeNode>? children,
  }) : children = children ?? <LibraryEditTreeNode>[];

  final String folderPath;
  final int depth;
  final List<LibraryEditTreeNode> children;

  @override
  String get name => PathDisplay.folderName(folderPath);

  @override
  String get pathValue => folderPath;
}

class LibraryEditTrackTreeNode extends LibraryEditTreeNode {
  LibraryEditTrackTreeNode(this.trackPath);

  final String trackPath;

  @override
  String get name => PathDisplay.fileName(trackPath, withoutExtension: true);

  @override
  String get pathValue => trackPath;
}

class LibraryEditTreeProjection {
  const LibraryEditTreeProjection(this.libraryPath);
  final String libraryPath;

  Map<String, int> includedTrackCounts(
    List<LibraryEditTreeNode> nodes,
    bool Function(String) isTrackIncluded,
  ) {
    final counts = <String, int>{};
    int count(LibraryEditTreeNode node) {
      if (node is LibraryEditTrackTreeNode) {
        return isTrackIncluded(node.trackPath) ? 1 : 0;
      }
      final folder = node as LibraryEditFolderTreeNode;
      final included = folder.children.fold<int>(
        0,
        (total, child) => total + count(child),
      );
      counts[folder.folderPath] = included;
      return included;
    }

    for (final node in nodes) {
      count(node);
    }
    return counts;
  }

  List<LibraryEditTreeNode> buildEditTree(
    List<String> trackPaths,
    List<String> persistentFolderPaths,
    List<LibraryEditFolderTreeNode> restoringFolderSnapshots, {
    Map<String, String> trackParentPaths = const <String, String>{},
  }) {
    final rootPath = PathMatcher.normalize(libraryPath);
    final folderByPath = <String, LibraryEditFolderTreeNode>{};
    final roots = <LibraryEditTreeNode>[];
    final insertedTrackPaths = <String>{};

    LibraryEditFolderTreeNode? ensureFolder(String folderPath) {
      final normalizedFolderPath = PathMatcher.normalize(folderPath);
      if (PathMatcher.equalsNormalized(normalizedFolderPath, rootPath) ||
          !PathMatcher.isWithinOrEqual(normalizedFolderPath, rootPath)) {
        return null;
      }

      final existing = folderByPath[normalizedFolderPath];
      if (existing != null) return existing;

      final parentPath = parentFolderPath(normalizedFolderPath, rootPath);
      final parent = parentPath == null ? null : ensureFolder(parentPath);
      final folder = LibraryEditFolderTreeNode(
        folderPath: normalizedFolderPath,
        depth: relativeFolderDepth(normalizedFolderPath),
      );
      folderByPath[normalizedFolderPath] = folder;
      if (parent == null) {
        roots.add(folder);
      } else {
        parent.children.add(folder);
      }
      return folder;
    }

    void addTrackNode(String trackPath, {String? snapshotParent}) {
      final normalizedTrackPath = PathMatcher.normalize(trackPath);
      if (PathMatcher.isContentUri(rootPath) &&
          PathMatcher.contentPathSegmentAfter(normalizedTrackPath, 'tree') !=
              null &&
          !PathMatcher.hasSameContentTree(normalizedTrackPath, rootPath)) {
        return;
      }
      final confirmedParent =
          trackParentPaths[normalizedTrackPath] ?? snapshotParent;
      final hasConfirmedParent =
          confirmedParent != null &&
          PathMatcher.hasSameContentTree(normalizedTrackPath, rootPath) &&
          PathMatcher.isWithinOrEqual(confirmedParent, rootPath);
      if ((!PathMatcher.isWithinOrEqual(normalizedTrackPath, libraryPath) &&
              !hasConfirmedParent) ||
          !insertedTrackPaths.add(normalizedTrackPath)) {
        return;
      }
      final trackNode = LibraryEditTrackTreeNode(normalizedTrackPath);
      final folderPath = hasConfirmedParent
          ? confirmedParent
          : folderPathForTrack(normalizedTrackPath);
      final folder = folderPath == null ? null : ensureFolder(folderPath);
      if (folder == null) {
        roots.add(trackNode);
      } else {
        folder.children.add(trackNode);
      }
    }

    void mergeFolderSnapshot(LibraryEditFolderTreeNode snapshot) {
      final folder = ensureFolder(snapshot.folderPath);
      if (folder == null) return;
      for (final child in snapshot.children) {
        if (child is LibraryEditFolderTreeNode) {
          mergeFolderSnapshot(child);
        } else if (child is LibraryEditTrackTreeNode) {
          addTrackNode(child.trackPath, snapshotParent: snapshot.folderPath);
        }
      }
    }

    for (final folderPath in persistentFolderPaths) {
      ensureFolder(folderPath);
    }
    for (final snapshot in restoringFolderSnapshots) {
      mergeFolderSnapshot(snapshot);
    }

    for (final trackPath in trackPaths) {
      addTrackNode(trackPath);
    }

    _sortEditTree(roots);
    return roots;
  }

  String? parentFolderPath(String folderPath, String rootPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (PathMatcher.equalsNormalized(normalizedFolderPath, rootPath)) {
      return null;
    }

    if (PathMatcher.isContentUri(normalizedFolderPath)) {
      final markerIndex = normalizedFolderPath.indexOf('::');
      if (markerIndex >= 0) {
        final base = normalizedFolderPath.substring(0, markerIndex);
        final relative = normalizedFolderPath
            .substring(markerIndex + 2)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^/+'), '')
            .replaceFirst(RegExp(r'/+$'), '');
        final parentRelative = path.posix.dirname(relative);
        if (parentRelative == '.' || parentRelative.isEmpty) {
          return base;
        }
        return '$base::$parentRelative';
      }
    }

    return path.dirname(normalizedFolderPath);
  }

  int relativeFolderDepth(String folderPath) {
    final relative = PathMatcher.relativeWithin(
      PathMatcher.normalize(folderPath),
      PathMatcher.normalize(libraryPath),
    );
    if (relative == null || relative.isEmpty) {
      return 0;
    }
    return relative
            .split(RegExp(r'[\\/]+'))
            .where((segment) => segment.isNotEmpty)
            .length -
        1;
  }

  String? folderPathForTrack(String trackPath) {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final rootPath = PathMatcher.normalize(libraryPath);
    final relativeTrackPath = PathMatcher.relativeWithin(
      normalizedTrackPath,
      rootPath,
    );
    if (relativeTrackPath == null || relativeTrackPath.isEmpty) {
      final parentPath = path.dirname(normalizedTrackPath);
      if (parentPath == '.' ||
          parentPath.isEmpty ||
          PathMatcher.equalsNormalized(parentPath, rootPath)) {
        return null;
      }
      return parentPath;
    }

    final normalizedRelativeTrackPath = relativeTrackPath.replaceAll('\\', '/');
    final relativeFolderPath = path.posix.dirname(normalizedRelativeTrackPath);
    if (relativeFolderPath == '.' || relativeFolderPath.isEmpty) {
      return null;
    }
    if (PathMatcher.isContentUri(rootPath)) {
      return '$rootPath::$relativeFolderPath';
    }
    return path.normalize(path.join(rootPath, relativeFolderPath));
  }

  String folderPathForLibraryChild(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final rootPath = PathMatcher.normalize(libraryPath);
    if (!PathMatcher.isContentUri(rootPath)) {
      return normalizedFolderPath;
    }

    final relativeFolderPath = PathMatcher.relativeWithin(
      normalizedFolderPath,
      rootPath,
    );
    if (relativeFolderPath == null || relativeFolderPath.isEmpty) {
      return normalizedFolderPath;
    }
    return '$rootPath::${relativeFolderPath.replaceAll('\\', '/')}';
  }

  void _sortEditTree(List<LibraryEditTreeNode> nodes) {
    nodes.sort((a, b) {
      if (a is LibraryEditFolderTreeNode && b is LibraryEditTrackTreeNode) {
        return -1;
      }
      if (a is LibraryEditTrackTreeNode && b is LibraryEditFolderTreeNode) {
        return 1;
      }
      return compareNatural(a.name, b.name);
    });
    for (final node in nodes) {
      if (node is LibraryEditFolderTreeNode) {
        _sortEditTree(node.children);
      }
    }
  }

  List<LibraryEditTreeNode> filterEditTree(
    List<LibraryEditTreeNode> nodes,
    String query,
    bool Function(String, String) matchesQuery,
  ) {
    if (query.isEmpty) return nodes;
    final normalizedQuery = query.toLowerCase();
    final result = <LibraryEditTreeNode>[];

    for (final node in nodes) {
      if (node is LibraryEditFolderTreeNode) {
        final filteredChildren = filterEditTree(
          node.children,
          query,
          matchesQuery,
        );
        if (filteredChildren.isEmpty) continue;
        result.add(
          LibraryEditFolderTreeNode(
            folderPath: node.folderPath,
            depth: node.depth,
            children: filteredChildren,
          ),
        );
      } else if (node is LibraryEditTrackTreeNode &&
          matchesQuery(node.trackPath, normalizedQuery)) {
        result.add(node);
      }
    }

    return result;
  }
}
