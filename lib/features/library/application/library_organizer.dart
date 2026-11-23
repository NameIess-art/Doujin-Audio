import 'package:path/path.dart' as path;

import '../domain/library_node.dart';
import '../domain/library_entry.dart';
import 'library_state_models.dart' show LibraryExclusionMatcher;
import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';

class LibraryOrganizer {
  const LibraryOrganizer();

  static const String singleFilesGroupKey = '__single_files__';
  static final RegExp _leadingSlashPattern = RegExp(r'^/+');
  static final RegExp _trailingSlashPattern = RegExp(r'/+$');
  static final RegExp _pathSeparatorPattern = RegExp(r'[\\/]+');
  static final RegExp _documentPrefixPattern = RegExp(
    r'^document[\\/]+',
    caseSensitive: false,
  );

  List<LibraryEntry> buildLibraryEntries(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    required LibraryExclusionMatcher exclusionMatcher,
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final matcher = exclusionMatcher;
    final entriesByKey = <String, LibraryEntry>{};

    void putEntry(LibraryEntry entry) {
      entriesByKey['${entry.kind.dbValue}:${entry.path}'] = entry;
    }

    void ensureFolder(String folderPath) {
      final normalizedFolderPath = canonicalLibraryFolderPath(
        normalizedLibraryPath,
        folderPath,
      );
      if (PathMatcher.equalsNormalized(
            normalizedFolderPath,
            normalizedLibraryPath,
          ) ||
          !PathMatcher.isWithinOrEqual(
            normalizedFolderPath,
            normalizedLibraryPath,
          )) {
        return;
      }
      if (entriesByKey.containsKey(
        '${LibraryEntryKind.folder.dbValue}:$normalizedFolderPath',
      )) {
        return;
      }
      final parentPath = parentLibraryFolderPath(
        normalizedFolderPath,
        normalizedLibraryPath,
      );
      if (parentPath != null) ensureFolder(parentPath);
      putEntry(
        LibraryEntry.folder(
          libraryPath: normalizedLibraryPath,
          path: normalizedFolderPath,
          parentPath: parentPath,
          state: matcher.isExcluded(normalizedFolderPath)
              ? LibraryEntryState.excluded
              : LibraryEntryState.active,
          displayName: PathDisplay.folderName(normalizedFolderPath),
        ),
      );
    }

    for (final folderPath in folderPaths) {
      ensureFolder(folderPath);
    }
    for (final track in tracks) {
      if (!trackBelongsToLibrary(normalizedLibraryPath, track)) {
        continue;
      }
      final parentPath = folderPathForLibraryTrack(
        normalizedLibraryPath,
        track,
      );
      if (parentPath != null) ensureFolder(parentPath);
      putEntry(
        LibraryEntry.track(
          libraryPath: normalizedLibraryPath,
          track: track,
          parentPath: parentPath,
          state:
              matcher.isExcluded(track.path) ||
                  (parentPath != null &&
                      entriesByKey['${LibraryEntryKind.folder.dbValue}:$parentPath']
                              ?.isExcluded ==
                          true)
              ? LibraryEntryState.excluded
              : LibraryEntryState.active,
        ),
      );
    }
    return entriesByKey.values.toList(growable: false);
  }

  bool trackBelongsToLibrary(String libraryPath, MusicTrack track) {
    if (PathMatcher.isContentUri(libraryPath) &&
        PathMatcher.isContentUri(track.path) &&
        PathMatcher.contentPathSegmentAfter(track.path, 'tree') != null &&
        !PathMatcher.hasSameContentTree(track.path, libraryPath)) {
      return false;
    }
    if (PathMatcher.isWithinOrEqual(track.path, libraryPath)) return true;
    return !track.isSingle &&
        PathMatcher.hasSameContentTree(track.path, libraryPath) &&
        PathMatcher.isWithinOrEqual(track.groupKey, libraryPath);
  }

  String? folderPathForLibraryTrack(String libraryPath, MusicTrack track) {
    if (!track.isSingle &&
        track.groupKey.isNotEmpty &&
        track.groupKey != singleFilesGroupKey &&
        PathMatcher.isWithinOrEqual(track.groupKey, libraryPath) &&
        !PathMatcher.equalsNormalized(track.groupKey, libraryPath)) {
      return canonicalLibraryFolderPath(libraryPath, track.groupKey);
    }
    final relative = PathMatcher.relativeWithin(track.path, libraryPath);
    if (relative == null || relative.isEmpty) return null;
    final normalizedRelative = relative.replaceAll('\\', '/');
    final relativeFolder = path.posix.dirname(normalizedRelative);
    if (relativeFolder == '.' || relativeFolder.isEmpty) return null;
    if (PathMatcher.isContentUri(libraryPath)) {
      return '$libraryPath::$relativeFolder';
    }
    return PathMatcher.join(libraryPath, relativeFolder);
  }

  String canonicalLibraryFolderPath(String libraryPath, String folderPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (!PathMatcher.isContentUri(normalizedLibraryPath) ||
        normalizedFolderPath.contains('::')) {
      return normalizedFolderPath;
    }
    final relativeFolderPath = PathMatcher.relativeWithin(
      normalizedFolderPath,
      normalizedLibraryPath,
    );
    if (relativeFolderPath == null || relativeFolderPath.isEmpty) {
      return normalizedFolderPath;
    }
    return '$normalizedLibraryPath::${relativeFolderPath.replaceAll('\\', '/')}';
  }

  String? parentLibraryFolderPath(String folderPath, String rootPath) {
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
            .replaceFirst(_leadingSlashPattern, '')
            .replaceFirst(_trailingSlashPattern, '');
        final parentRelative = path.posix.dirname(relative);
        if (parentRelative == '.' || parentRelative.isEmpty) return base;
        return '$base::$parentRelative';
      }
    }
    final parentPath = PathMatcher.parentPath(normalizedFolderPath);
    return parentPath != null &&
            PathMatcher.equalsNormalized(parentPath, rootPath)
        ? rootPath
        : parentPath;
  }

  /// [rootsAlreadySorted] applies to both lists, in descending path length.
  String rootPathForTrack(
    MusicTrack track,
    Iterable<String> watchedRoots, {
    List<String> watchedLibraries = const <String>[],
    bool rootsAlreadySorted = false,
    PathRootIndex? watchedRootsIndex,
    PathRootIndex? watchedLibrariesIndex,
  }) {
    if (watchedRootsIndex != null || watchedLibrariesIndex != null) {
      return _rootPathForTrackWithIndex(
        track,
        watchedRootsIndex ?? PathRootIndex(watchedRoots),
        watchedLibrariesIndex ?? PathRootIndex(watchedLibraries),
      );
    }
    if (track.isSingle) return track.path;
    String? longestContainingRoot(Iterable<String> roots) {
      String? best;
      for (final root in roots) {
        if (best != null && root.length <= best.length) continue;
        if (PathMatcher.isWithinOrEqual(track.groupKey, root) ||
            PathMatcher.isWithinOrEqual(track.path, root)) {
          if (rootsAlreadySorted) return root;
          best = root;
        }
      }
      return best;
    }

    final libraryRoot = longestContainingRoot(watchedLibraries);
    if (libraryRoot != null) {
      return workScopeFolderPath(libraryRoot, track.groupKey) ?? libraryRoot;
    }
    return longestContainingRoot(watchedRoots) ?? track.groupKey;
  }

  String? _longerPath(String? first, String? second) {
    if (first == null) return second;
    if (second == null) return first;
    return second.length > first.length ? second : first;
  }

  String _rootPathForTrackWithIndex(
    MusicTrack track,
    PathRootIndex watchedRootsIndex,
    PathRootIndex watchedLibrariesIndex,
  ) {
    if (track.isSingle) {
      return track.path;
    }
    if (!watchedLibrariesIndex.isEmpty) {
      final groupLibrary = track.groupKey.isEmpty
          ? null
          : watchedLibrariesIndex.mostSpecificContaining(track.groupKey);
      final pathLibrary = watchedLibrariesIndex.mostSpecificContaining(
        track.path,
      );
      final libraryRoot = _longerPath(groupLibrary, pathLibrary);
      if (libraryRoot != null) {
        return workScopeFolderPath(libraryRoot, track.groupKey) ?? libraryRoot;
      }
    }
    if (!watchedRootsIndex.isEmpty) {
      final groupRoot = track.groupKey.isEmpty
          ? null
          : watchedRootsIndex.mostSpecificContaining(track.groupKey);
      final pathRoot = watchedRootsIndex.mostSpecificContaining(track.path);
      final root = _longerPath(groupRoot, pathRoot);
      if (root != null) return root;
    }
    return track.groupKey;
  }

  /// Prepared lists use descending path length. [watchedFolderByPath] uses
  /// PathMatcher path equivalence and stores normalized root paths.
  String rootFolderPath(
    String folderPath,
    Iterable<String> watchedFolders, {
    List<String> watchedLibraries = const <String>[],
    bool rootsAlreadySorted = false,
    Map<String, String>? watchedFolderByPath,
    PathRootIndex? watchedFoldersIndex,
    PathRootIndex? watchedLibrariesIndex,
  }) {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    if (watchedLibrariesIndex != null || watchedFoldersIndex != null) {
      final libraryRoot = watchedLibrariesIndex?.mostSpecificContaining(
        normalizedFolder,
      );
      if (libraryRoot != null) {
        return workScopeFolderPath(libraryRoot, normalizedFolder) ??
            PathMatcher.normalize(libraryRoot);
      }
      final exactFolder = watchedFolderByPath?[normalizedFolder];
      if (exactFolder != null) return exactFolder;
      final watchedFolder = watchedFoldersIndex?.mostSpecificContaining(
        normalizedFolder,
      );
      if (watchedFolder != null) {
        return PathMatcher.normalize(watchedFolder);
      }
      return normalizedFolder;
    }
    String? longestContainingRoot(Iterable<String> roots) {
      String? best;
      for (final root in roots) {
        if (best != null && root.length <= best.length) continue;
        if (PathMatcher.isWithinOrEqual(normalizedFolder, root)) {
          if (rootsAlreadySorted) return root;
          best = root;
        }
      }
      return best;
    }

    final libraryRoot = longestContainingRoot(watchedLibraries);
    if (libraryRoot != null) {
      return workScopeFolderPath(libraryRoot, normalizedFolder) ??
          PathMatcher.normalize(libraryRoot);
    }

    final exactFolder = watchedFolderByPath?[normalizedFolder];
    if (exactFolder != null) return exactFolder;

    final watchedFolder = longestContainingRoot(watchedFolders);
    if (watchedFolder != null) {
      return PathMatcher.normalize(watchedFolder);
    }
    return normalizedFolder;
  }

  String? workScopeFolderPath(String libraryRoot, String groupKey) {
    final relativePath = PathMatcher.relativeWithin(groupKey, libraryRoot);
    if (relativePath == null || relativePath.isEmpty) return null;

    final firstSegment = relativePath
        .split(_pathSeparatorPattern)
        .firstWhere((segment) => segment.isNotEmpty, orElse: () => '');
    if (firstSegment.isEmpty) return null;

    final normalizedRoot = PathMatcher.normalize(libraryRoot);
    if (PathMatcher.isContentUri(normalizedRoot)) {
      return '$normalizedRoot::$firstSegment';
    }
    return PathMatcher.join(normalizedRoot, firstSegment);
  }

  List<String> topLevelNodeIds(
    List<MusicTrack> tracks,
    List<String> watchedFolders, {
    List<String> watchedLibraries = const <String>[],
  }) {
    final watchedRootsIndex = PathRootIndex(watchedFolders);
    final watchedLibrariesIndex = PathRootIndex(watchedLibraries);
    final ids = <String>[];
    final seen = <String>{};
    for (final track in tracks) {
      final nodeId = _rootPathForTrackWithIndex(
        track,
        watchedRootsIndex,
        watchedLibrariesIndex,
      );
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
    List<String> watchedLibraries = const <String>[],
    bool tracksAlreadySorted = false,
  }) {
    final watchedRootsIndex = PathRootIndex(watchedFolders);
    final watchedLibrariesIndex = PathRootIndex(watchedLibraries);
    final groups = <String, _LibraryCardGroup>{};
    final singleFiles = <TrackNode>[];

    for (final track in tracks) {
      if (track.isSingle) {
        singleFiles.add(TrackNode(track));
        continue;
      }
      final rootPath = _rootPathForTrackWithIndex(
        track,
        watchedRootsIndex,
        watchedLibrariesIndex,
      );
      final group = groups.putIfAbsent(
        rootPath,
        () => _LibraryCardGroup(
          rootPath: rootPath,
          rootName: _resolveRootNodeName(rootPath, track),
        ),
      );
      group.tracks.add(track);
      final scannedAt = track.scannedAt;
      if (scannedAt != null &&
          (group.earliestScannedAt == null ||
              scannedAt.isBefore(group.earliestScannedAt!))) {
        group.earliestScannedAt = scannedAt;
      }
      final playedAt = track.lastPlayedAt;
      if (playedAt != null &&
          (group.latestPlayedAt == null ||
              playedAt.isAfter(group.latestPlayedAt!))) {
        group.latestPlayedAt = playedAt;
      }

      final directoryPath = PathMatcher.isContentUri(track.path)
          ? track.groupKey
          : PathMatcher.parentPath(track.path) ?? path.dirname(track.path);
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
      if (!tracksAlreadySorted) {
        group.tracks.sort(compareTracks);
      }
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
          trackDatesCached: true,
          earliestScannedAt: group.earliestScannedAt,
          latestPlayedAt: group.latestPlayedAt,
        );
      leafFolderCount += groupLeafFolderCount;
      topLevel.add(folder);
    }
    topLevel.addAll(singleFiles);
    _sortTopLevel(topLevel);
    return LibraryTreeSnapshot(
      tree: List<LibraryNode>.unmodifiable(topLevel),
      leafFolderCount: leafFolderCount,
    );
  }

  LibraryTreeSnapshot buildTree({
    required List<MusicTrack> tracks,
    required List<String> watchedFolders,
    List<String> watchedLibraries = const <String>[],
  }) {
    final rootNodes = <String, FolderNode>{};
    final folderIndexByPath = <String, Map<String, FolderNode>>{};
    final singleFiles = <TrackNode>[];
    final watchedRootsIndex = PathRootIndex(watchedFolders);
    final watchedLibrariesIndex = PathRootIndex(watchedLibraries);

    for (final track in tracks) {
      if (track.isSingle) {
        singleFiles.add(TrackNode(track));
        continue;
      }

      final dirPath = PathMatcher.isContentUri(track.path)
          ? track.groupKey
          : PathMatcher.parentPath(track.path) ?? path.dirname(track.path);
      final matchedRoot = _rootPathForTrackWithIndex(
        track,
        watchedRootsIndex,
        watchedLibrariesIndex,
      );

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
            .replaceFirst(_leadingSlashPattern, '');
        final parts = relDir.split(_pathSeparatorPattern);
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
            currentNode.addChild(newFolder);
            childFolders[part] = newFolder;
            folderIndexByPath[currentPath] = <String, FolderNode>{};
            currentNode = newFolder;
          } else {
            currentNode = existingFolder;
          }
        }
      }

      currentNode.addChild(TrackNode(track));
    }

    var leafFolderCount = 0;
    final roots = rootNodes.values.toList();
    for (final root in roots) {
      _sortFolder(root);
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
    _sortTopLevel(topLevel);

    return LibraryTreeSnapshot(
      tree: List<LibraryNode>.unmodifiable(topLevel),
      leafFolderCount: leafFolderCount,
    );
  }

  void _sortTopLevel(List<LibraryNode> topLevel) {
    topLevel.sort((a, b) {
      return compareNatural(a.name, b.name);
    });
  }

  void _sortFolder(FolderNode folder) {
    folder.sortChildren((a, b) {
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
      final separator = rootPath.contains('::') ? '/' : '::';
      return '$rootPath$separator${parts.join('/')}';
    }
    return parts.fold(rootPath, PathMatcher.join);
  }

  String _normalizeDisplaySegment(String value) {
    return PathDisplay.normalizeDisplaySegment(value);
  }

  String _sanitizeFolderPart(String rawPart, String rootDisplayName) {
    var part = _normalizeDisplaySegment(rawPart);
    if (part.isEmpty) return part;

    part = part.replaceFirst(_documentPrefixPattern, '');
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
    var totalDuration = Duration.zero;
    MusicTrack? firstTrack;

    for (final child in folder.children) {
      if (child is TrackNode) {
        totalTrackCount++;
        totalDuration += child.track.duration;
        firstTrack ??= child.track;
        continue;
      }
      if (child is FolderNode) {
        hasChildFolder = true;
        _cacheFolderTreeMetrics(child);
        totalTrackCount += child.totalTrackCount;
        childLeafFolderCount += child.leafFolderCount;
        totalDuration += child.totalDuration;
        firstTrack ??= child.firstTrack;
      }
    }

    folder.cacheTreeMetrics(
      totalTrackCount: totalTrackCount,
      leafFolderCount: hasChildFolder ? childLeafFolderCount : 1,
      firstTrack: firstTrack,
      totalDuration: totalDuration,
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
  DateTime? earliestScannedAt;
  DateTime? latestPlayedAt;
}
