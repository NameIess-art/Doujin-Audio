import 'package:path/path.dart' as path;

import '../models/library_node.dart';
import '../models/music_track.dart';
import 'natural_sort.dart';
import 'path_matcher.dart';
import 'path_display.dart';

class LibraryOrganizer {
  const LibraryOrganizer();

  String rootPathForTrack(MusicTrack track, List<String> watchedRoots) {
    final sortedRoots = watchedRoots.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
    return _rootPathForTrack(track, sortedRoots);
  }

  String _rootPathForTrack(MusicTrack track, List<String> sortedRoots) {
    if (track.isSingle) {
      return track.path;
    }
    for (final root in sortedRoots) {
      if (PathMatcher.isWithinOrEqual(track.groupKey, root) ||
          PathMatcher.isWithinOrEqual(track.path, root)) {
        return root;
      }
    }
    return track.groupKey;
  }

  List<String> topLevelNodeIds(
    List<MusicTrack> tracks,
    List<String> watchedFolders,
  ) {
    final watchedRoots = watchedFolders.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
    final ids = <String>[];
    final seen = <String>{};
    for (final track in tracks) {
      final nodeId = _rootPathForTrack(track, watchedRoots);
      if (seen.add(nodeId)) {
        ids.add(nodeId);
      }
    }
    return ids;
  }

  int compareTracks(MusicTrack a, MusicTrack b) {
    final groupResult = compareNatural(a.groupTitle, b.groupTitle);
    if (groupResult != 0) return groupResult;
    return compareNatural(a.displayName, b.displayName);
  }

  LibraryTreeSnapshot buildCardTree({
    required List<MusicTrack> tracks,
    required List<String> watchedFolders,
    required List<String> nodeOrder,
  }) {
    final watchedRoots = watchedFolders.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
    final groups = <String, _LibraryCardGroup>{};
    final singleFiles = <TrackNode>[];

    for (final track in tracks) {
      if (track.isSingle) {
        singleFiles.add(TrackNode(track));
        continue;
      }
      final rootPath = _rootPathForTrack(track, watchedRoots);
      final group = groups.putIfAbsent(
        rootPath,
        () => _LibraryCardGroup(
          rootPath: rootPath,
          rootName: _resolveRootNodeName(rootPath, track),
        ),
      );
      group.tracks.add(track);

      final directoryPath = PathMatcher.isContentUri(track.path)
          ? track.groupKey
          : path.dirname(track.path);
      final relativeDirectory = PathMatcher.relativeWithin(
        directoryPath,
        rootPath,
      );
      final parts = (relativeDirectory ?? '')
          .replaceAll('\\', '/')
          .split('/')
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
      final directoryKey = parts.join('/');
      group.directories.add(directoryKey);
      if (parts.isNotEmpty) {
        group.nonLeafDirectories.add('');
      }
      for (var index = 1; index < parts.length; index++) {
        group.nonLeafDirectories.add(parts.take(index).join('/'));
      }
    }

    var leafFolderCount = 0;
    final topLevel = <LibraryNode>[];
    for (final group in groups.values) {
      group.tracks.sort(compareTracks);
      final immutableTracks = List<MusicTrack>.unmodifiable(group.tracks);
      final groupLeafFolderCount = group.directories
          .where((directory) => !group.nonLeafDirectories.contains(directory))
          .length;
      final folder = FolderNode(group.rootName, group.rootPath)
        ..cacheTreeMetrics(
          totalTrackCount: immutableTracks.length,
          leafFolderCount: groupLeafFolderCount,
          firstTrack: immutableTracks.first,
          totalDuration: immutableTracks.fold<Duration>(
            Duration.zero,
            (total, track) => total + track.duration,
          ),
          allTracks: immutableTracks,
        );
      leafFolderCount += groupLeafFolderCount;
      topLevel.add(folder);
    }
    topLevel.addAll(singleFiles);
    _sortTopLevel(topLevel, nodeOrder);
    return LibraryTreeSnapshot(
      tree: List<LibraryNode>.unmodifiable(topLevel),
      leafFolderCount: leafFolderCount,
    );
  }

  LibraryTreeSnapshot buildTree({
    required List<MusicTrack> tracks,
    required List<String> watchedFolders,
    required List<String> nodeOrder,
  }) {
    final rootNodes = <String, FolderNode>{};
    final folderIndexByPath = <String, Map<String, FolderNode>>{};
    final singleFiles = <TrackNode>[];
    final watchedRoots = watchedFolders.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));

    for (final track in tracks) {
      if (track.isSingle) {
        singleFiles.add(TrackNode(track));
        continue;
      }

      final dirPath = PathMatcher.isContentUri(track.path)
          ? track.groupKey
          : path.dirname(track.path);
      final matchedRoot = _rootPathForTrack(track, watchedRoots);

      if (!rootNodes.containsKey(matchedRoot)) {
        final rootName = _resolveRootNodeName(matchedRoot, track);
        rootNodes[matchedRoot] = FolderNode(rootName, matchedRoot);
        folderIndexByPath[matchedRoot] = <String, FolderNode>{};
      }

      FolderNode currentNode = rootNodes[matchedRoot]!;
      final rootDisplayName = currentNode.name;

      final relativeDir = PathMatcher.relativeWithin(dirPath, matchedRoot);
      if (relativeDir != null && relativeDir.isNotEmpty) {
        final relDir = relativeDir
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^/+'), '');
        final parts = relDir.split(RegExp(r'[\\/]+'));
        final currentParts = <String>[];

        for (final rawPart in parts) {
          final part = _sanitizeFolderPart(rawPart, rootDisplayName);
          if (part.isEmpty) continue;
          currentParts.add(part);
          final currentPath = _folderPathForRelativeParts(
            matchedRoot,
            currentParts,
          );

          final childFolders = folderIndexByPath.putIfAbsent(
            currentNode.path,
            () => <String, FolderNode>{},
          );
          final existingFolder = childFolders[part];
          if (existingFolder == null) {
            final newFolder = FolderNode(
              part,
              currentPath,
              depth: currentNode.depth + 1,
            );
            currentNode.children.add(newFolder);
            childFolders[part] = newFolder;
            folderIndexByPath[currentPath] = <String, FolderNode>{};
            currentNode = newFolder;
          } else {
            currentNode = existingFolder;
          }
        }
      }

      currentNode.children.add(TrackNode(track));
    }

    var leafFolderCount = 0;
    final roots = rootNodes.values.toList();
    for (final root in roots) {
      _sortFolder(root);
      _cacheFolderTreeMetrics(root);
    }

    // Prune empty folders (those with 0 totalTrackCount)
    for (final root in roots) {
      _pruneEmptyFolders(root);
      _cacheFolderTreeMetrics(root);
    }

    final topLevel = <LibraryNode>[];
    for (final root in roots) {
      if (root.totalTrackCount > 0) {
        leafFolderCount += root.leafFolderCount;
        topLevel.add(root);
      }
    }

    topLevel.addAll(singleFiles);
    _sortTopLevel(topLevel, nodeOrder);

    return LibraryTreeSnapshot(
      tree: List<LibraryNode>.unmodifiable(topLevel),
      leafFolderCount: leafFolderCount,
    );
  }

  void _sortTopLevel(List<LibraryNode> topLevel, List<String> nodeOrder) {
    final topLevelOrderIndex = <String, int>{
      for (var i = 0; i < nodeOrder.length; i++) nodeOrder[i]: i,
    };
    topLevel.sort((a, b) {
      final aIndex = topLevelOrderIndex[a.path];
      final bIndex = topLevelOrderIndex[b.path];
      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      }
      if (aIndex != null) return -1;
      if (bIndex != null) return 1;
      return compareNatural(a.name, b.name);
    });
  }

  void _pruneEmptyFolders(FolderNode folder) {
    folder.children.removeWhere((child) {
      if (child is FolderNode) {
        _pruneEmptyFolders(child);
        return child.totalTrackCount == 0;
      }
      return false;
    });
  }

  void _sortFolder(FolderNode folder) {
    folder.children.sort((a, b) {
      if (a is FolderNode && b is TrackNode) return -1;
      if (a is TrackNode && b is FolderNode) return 1;
      return compareNatural(a.name, b.name);
    });
    for (final child in folder.children) {
      if (child is FolderNode) _sortFolder(child);
    }
  }

  String _resolveRootNodeName(String rootPath, MusicTrack track) {
    final displayName = PathDisplay.folderName(rootPath);
    if (displayName.isNotEmpty && displayName != rootPath) {
      return displayName;
    }

    final subtitle = _normalizeDisplaySegment(track.groupSubtitle);
    if (subtitle.isNotEmpty) {
      final fromSubtitle = _normalizeDisplaySegment(
        subtitle.split('/').first.trim(),
      );
      if (fromSubtitle.isNotEmpty && fromSubtitle != rootPath) {
        return fromSubtitle;
      }
    }

    final baseName = PathDisplay.folderName(rootPath);
    return baseName.isEmpty ? rootPath : baseName;
  }

  String _folderPathForRelativeParts(String rootPath, List<String> parts) {
    if (parts.isEmpty) return rootPath;
    if (PathMatcher.isContentUri(rootPath)) {
      return '$rootPath::${parts.join('/')}';
    }
    return path.normalize(path.joinAll(<String>[rootPath, ...parts]));
  }

  String _normalizeDisplaySegment(String value) {
    return PathDisplay.normalizeDisplaySegment(value);
  }

  String _sanitizeFolderPart(String rawPart, String rootDisplayName) {
    var part = _normalizeDisplaySegment(rawPart);
    if (part.isEmpty) return part;

    part = part.replaceFirst(
      RegExp(r'^document[\\/]+', caseSensitive: false),
      '',
    );
    if (part.isEmpty) return part;

    if (part.contains('::')) {
      part = part.split('::').last;
    }

    part = _normalizeDisplaySegment(part);
    if (part.startsWith('primary:') ||
        part.startsWith('home:') ||
        part.startsWith('raw:')) {
      final idx = part.indexOf(':');
      if (idx >= 0 && idx + 1 < part.length) {
        part = part.substring(idx + 1);
      }
    }

    if (part.contains('/')) {
      part = part.split('/').last;
    }
    part = part.trim();

    if (part.toLowerCase() == 'document') return '';
    if (part == rootDisplayName) return '';
    return part;
  }

  void _cacheFolderTreeMetrics(FolderNode folder) {
    var totalTrackCount = 0;
    var childLeafFolderCount = 0;
    var hasChildFolder = false;
    MusicTrack? firstTrack;

    for (final child in folder.children) {
      if (child is TrackNode) {
        totalTrackCount++;
        firstTrack ??= child.track;
        continue;
      }
      if (child is FolderNode) {
        hasChildFolder = true;
        _cacheFolderTreeMetrics(child);
        totalTrackCount += child.totalTrackCount;
        childLeafFolderCount += child.leafFolderCount;
        firstTrack ??= child.firstTrack;
      }
    }

    folder.cacheTreeMetrics(
      totalTrackCount: totalTrackCount,
      leafFolderCount: hasChildFolder ? childLeafFolderCount : 1,
      firstTrack: firstTrack,
    );
  }
}

class _LibraryCardGroup {
  _LibraryCardGroup({required this.rootPath, required this.rootName});

  final String rootPath;
  final String rootName;
  final List<MusicTrack> tracks = <MusicTrack>[];
  final Set<String> directories = <String>{};
  final Set<String> nonLeafDirectories = <String>{};
}
