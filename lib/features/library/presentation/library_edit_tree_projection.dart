import 'package:path/path.dart' as path;
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';

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
  List<LibraryEditTreeNode> buildEditTree(
    List<String> trackPaths,
    List<String> persistentFolderPaths,
    List<LibraryEditFolderTreeNode> restoringFolderSnapshots,
  ) {
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

    void addTrackNode(String trackPath) {
      final normalizedTrackPath = PathMatcher.normalize(trackPath);
      if (!PathMatcher.isWithinOrEqual(normalizedTrackPath, libraryPath) ||
          !insertedTrackPaths.add(normalizedTrackPath)) {
        return;
      }
      final trackNode = LibraryEditTrackTreeNode(normalizedTrackPath);
      final folderPath = folderPathForTrack(normalizedTrackPath);
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
          addTrackNode(child.trackPath);
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

  LibraryEditFolderTreeNode cloneFolderNode(LibraryEditFolderTreeNode folder) {
    return LibraryEditFolderTreeNode(
      folderPath: folder.folderPath,
      depth: folder.depth,
      children: folder.children
          .map<LibraryEditTreeNode>((child) {
            if (child is LibraryEditFolderTreeNode) {
              return cloneFolderNode(child);
            }
            return LibraryEditTrackTreeNode(
              (child as LibraryEditTrackTreeNode).trackPath,
            );
          })
          .toList(growable: false),
    );
  }
}
