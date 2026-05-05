import 'dart:convert';

import 'package:path/path.dart' as path;

import '../models/library_node.dart';
import '../models/music_track.dart';

class LibraryOrganizer {
  const LibraryOrganizer();

  String rootPathForTrack(MusicTrack track, List<String> watchedRoots) {
    if (track.isSingle) {
      return track.path;
    }
    for (final root in watchedRoots) {
      if (track.groupKey.startsWith(root)) {
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
      final nodeId = rootPathForTrack(track, watchedRoots);
      if (seen.add(nodeId)) {
        ids.add(nodeId);
      }
    }
    return ids;
  }

  int compareTracks(MusicTrack a, MusicTrack b) {
    final groupResult = a.groupTitle.toLowerCase().compareTo(
      b.groupTitle.toLowerCase(),
    );
    if (groupResult != 0) return groupResult;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
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

      final dirPath = track.groupKey;
      final matchedRoot = rootPathForTrack(track, watchedRoots);

      if (!rootNodes.containsKey(matchedRoot)) {
        final rootName = _resolveRootNodeName(matchedRoot, track);
        rootNodes[matchedRoot] = FolderNode(rootName, matchedRoot);
        folderIndexByPath[matchedRoot] = <String, FolderNode>{};
      }

      FolderNode currentNode = rootNodes[matchedRoot]!;
      final rootDisplayName = currentNode.name;

      if (dirPath != matchedRoot && dirPath.length > matchedRoot.length) {
        String relDir = dirPath.substring(matchedRoot.length);
        if (relDir.startsWith('::')) {
          relDir = relDir.substring(2);
        }
        if (relDir.startsWith(path.separator)) relDir = relDir.substring(1);

        final parts = relDir.split(RegExp(r'[\\/]+'));
        String currentPath = matchedRoot;

        for (final rawPart in parts) {
          final part = _sanitizeFolderPart(rawPart, rootDisplayName);
          if (part.isEmpty) continue;
          currentPath = currentPath.endsWith(path.separator)
              ? currentPath + part
              : currentPath + path.separator + part;

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

    final topLevel = <LibraryNode>[];
    var leafFolderCount = 0;
    final topLevelOrderIndex = <String, int>{
      for (var i = 0; i < nodeOrder.length; i++) nodeOrder[i]: i,
    };

    final roots = rootNodes.values.toList();
    for (final root in roots) {
      _sortFolder(root);
      _cacheFolderTreeMetrics(root);
      leafFolderCount += root.leafFolderCount;
      topLevel.add(root);
    }

    topLevel.addAll(singleFiles);
    topLevel.sort((a, b) {
      final aIndex = topLevelOrderIndex[a.path];
      final bIndex = topLevelOrderIndex[b.path];
      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      }
      if (aIndex != null) return -1;
      if (bIndex != null) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return LibraryTreeSnapshot(
      tree: List<LibraryNode>.unmodifiable(topLevel),
      leafFolderCount: leafFolderCount,
    );
  }

  void _sortFolder(FolderNode folder) {
    folder.children.sort((a, b) {
      if (a is FolderNode && b is TrackNode) return -1;
      if (a is TrackNode && b is FolderNode) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    for (final child in folder.children) {
      if (child is FolderNode) _sortFolder(child);
    }
  }

  String _resolveRootNodeName(String rootPath, MusicTrack track) {
    final subtitle = _normalizeDisplaySegment(track.groupSubtitle);
    if (subtitle.isNotEmpty) {
      final fromSubtitle = _normalizeDisplaySegment(
        subtitle.split('/').first.trim(),
      );
      if (fromSubtitle.isNotEmpty && fromSubtitle != rootPath) {
        return fromSubtitle;
      }
    }

    final decodedTreeName = _decodeTreeRootName(rootPath);
    if (decodedTreeName != null && decodedTreeName.isNotEmpty) {
      return decodedTreeName;
    }

    final baseName = _normalizeDisplaySegment(path.basename(rootPath));
    return baseName.isEmpty ? rootPath : baseName;
  }

  String? _decodeTreeRootName(String rawPath) {
    if (!rawPath.startsWith('content://')) return null;
    final uri = Uri.tryParse(rawPath);
    if (uri == null) return null;

    final segments = uri.pathSegments;
    final treeIndex = segments.indexOf('tree');
    if (treeIndex < 0 || treeIndex + 1 >= segments.length) return null;

    final documentId = _safeUriDecode(segments[treeIndex + 1]);
    if (documentId.isEmpty) return null;
    final lastPart = documentId.split('/').last;
    final colonIndex = lastPart.lastIndexOf(':');
    if (colonIndex >= 0 && colonIndex + 1 < lastPart.length) {
      return _normalizeDisplaySegment(
        lastPart.substring(colonIndex + 1).trim(),
      );
    }
    return _normalizeDisplaySegment(lastPart.trim());
  }

  String _normalizeDisplaySegment(String value) {
    var normalized = value.trim();
    if (normalized.isEmpty) return normalized;

    normalized = _safeUriDecode(normalized);
    final maybeFixed = _tryLatin1ToUtf8(normalized);
    if (_looksLikeMojibake(normalized) && !_looksLikeMojibake(maybeFixed)) {
      normalized = maybeFixed;
    }
    return normalized;
  }

  String _safeUriDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  String _tryLatin1ToUtf8(String input) {
    try {
      return utf8.decode(latin1.encode(input), allowMalformed: false);
    } catch (_) {
      return input;
    }
  }

  bool _looksLikeMojibake(String value) {
    const mojibakePattern =
        r'[\\u00C0-\\u00FF]{2,}|[\\u4E00-\\u9FFF][\\u0080-\\u00FF]';
    return RegExp(mojibakePattern).hasMatch(value);
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
