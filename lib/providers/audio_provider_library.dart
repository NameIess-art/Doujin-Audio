part of 'audio_provider.dart';

extension AudioProviderLibrary on AudioProvider {
  String _libraryRootPathForTrack(MusicTrack track, List<String> watchedRoots) {
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

  List<String> _currentLibraryTopLevelNodeIds() {
    final watchedRoots = _watchedFolders.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
    final ids = <String>[];
    final seen = <String>{};
    for (final track in _library) {
      final nodeId = _libraryRootPathForTrack(track, watchedRoots);
      if (seen.add(nodeId)) {
        ids.add(nodeId);
      }
    }
    return ids;
  }

  void _syncLibraryNodeOrder({bool persist = true}) {
    final validNodeIds = _currentLibraryTopLevelNodeIds();
    final validNodeIdSet = validNodeIds.toSet();
    var changed = false;
    final previousLength = _libraryNodeOrder.length;
    _libraryNodeOrder.removeWhere((id) => !validNodeIdSet.contains(id));
    if (_libraryNodeOrder.length != previousLength) {
      changed = true;
    }

    for (final nodeId in validNodeIds) {
      if (_libraryNodeOrder.contains(nodeId)) continue;
      _libraryNodeOrder.add(nodeId);
      changed = true;
    }

    if (changed && persist) {
      unawaited(_saveLibraryNodeOrder());
    }
  }

  void reorderLibraryNodes(int oldIndex, int newIndex) {
    final currentIds = buildLibraryTree().map((node) => node.path).toList();
    if (oldIndex < 0 || oldIndex >= currentIds.length) return;
    if (newIndex < 0 || newIndex > currentIds.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final movedId = currentIds.removeAt(oldIndex);
    currentIds.insert(newIndex, movedId);
    _libraryNodeOrder
      ..clear()
      ..addAll(currentIds);
    _markLibraryStructureDirty();
    _notifyListeners();
    unawaited(_saveLibraryNodeOrder());
  }

  void addWatchedFolder(String folderPath, {bool notify = true}) {
    if (!_watchedFolders.contains(folderPath)) {
      _watchedFolders.add(folderPath);
      _syncLibraryNodeOrder();
      _markLibraryStructureDirty();
      if (notify) _notifyListeners();
      unawaited(_saveWatchedFolders());
    }
  }

  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    if (!_watchedLibraries.contains(folderPath)) {
      _watchedLibraries.add(folderPath);
      if (notify) _notifyListeners();
      unawaited(_saveWatchedLibraries());
    }
  }

  void removeWatchedFolder(String folderPath, {bool notify = true}) {
    if (_watchedFolders.remove(folderPath)) {
      _syncLibraryNodeOrder();
      _markLibraryStructureDirty();
      if (notify) _notifyListeners();
      unawaited(_saveWatchedFolders());
    }
  }

  void removeWatchedLibrary(String folderPath, {bool notify = true}) {
    if (_watchedLibraries.remove(folderPath)) {
      if (notify) _notifyListeners();
      unawaited(_saveWatchedLibraries());
    }
  }

  void setScanning(bool scanning) {
    if (_isScanning == scanning) return;
    _isScanning = scanning;
    if (scanning) {
      _scanCurrentFolder = '';
      _scanFoundCount = 0;
      _scanDuplicateCount = 0;
      _scanFailureCount = 0;
    }
    _notifyListeners();
  }

  void addTracks(
    List<MusicTrack> newTracks, {
    bool notify = true,
    bool persist = true,
  }) {
    if (newTracks.isEmpty) return;

    final toAdd = <MusicTrack>[];
    var didChangeGroupOrder = false;
    for (final track in newTracks) {
      if (_libraryByPath.containsKey(track.path)) {
        continue;
      }
      _library.add(track);
      _libraryByPath[track.path] = track;
      toAdd.add(track);
      if (_groupOrderSet.add(track.groupKey)) {
        _groupOrder.add(track.groupKey);
        didChangeGroupOrder = true;
      }
    }

    if (toAdd.isNotEmpty) {
      _clearResolvedCoverPaths();
      _rebuildLibraryIndexes();
      _syncLibraryNodeOrder(persist: false);
      if (notify) {
        _notifyListeners();
      }
      if (persist) {
        unawaited(AppDatabase.instance.insertTracks(toAdd));
        if (didChangeGroupOrder) {
          _saveGroupOrder();
        }
        _saveLibraryNodeOrder();
      }
    }
  }

  Future<void> removeTrackFromLibrary(String trackPath) async {
    final removedTrack = _libraryByPath.remove(trackPath);
    if (removedTrack == null) return;

    _library.removeWhere((track) => track.path == trackPath);
    _clearResolvedCoverPaths();

    final sessionsToRemove = _sessions.values
        .where((s) => s.currentTrackPath == trackPath)
        .map((s) => s.id)
        .toList();
    if (sessionsToRemove.isNotEmpty) {
      await _removeSessions(sessionsToRemove, persist: false, notify: false);
    }

    if (!_library.any((track) => track.groupKey == removedTrack.groupKey)) {
      _groupOrder.remove(removedTrack.groupKey);
      _groupOrderSet.remove(removedTrack.groupKey);
    }

    _rebuildLibraryIndexes();
    _syncLibraryNodeOrder(persist: false);
    _notifyListeners();
    unawaited(AppDatabase.instance.deleteTracks([trackPath]));
    _saveGroupOrder();
    _saveLibraryNodeOrder();
  }

  Future<void> removeFolderFromLibrary(String folderPath) async {
    _clearResolvedCoverPaths();
    final trackPaths = _library
        .where((track) => track.path.startsWith(folderPath))
        .map((track) => track.path)
        .toSet();
    if (trackPaths.isEmpty && !_watchedFolders.contains(folderPath)) {
      return;
    }

    final sessionsToRemove = _sessions.values
        .where((s) => trackPaths.contains(s.currentTrackPath))
        .map((s) => s.id)
        .toList();
    if (sessionsToRemove.isNotEmpty) {
      await _removeSessions(sessionsToRemove, persist: false, notify: false);
    }

    _library.removeWhere((track) => track.path.startsWith(folderPath));
    for (final trackPath in trackPaths) {
      _libraryByPath.remove(trackPath);
    }
    _groupOrder.removeWhere((key) => key.startsWith(folderPath));
    _groupOrderSet
      ..clear()
      ..addAll(_groupOrder);

    if (_watchedFolders.contains(folderPath)) {
      _watchedFolders.remove(folderPath);
      unawaited(_saveWatchedFolders());
    }

    _rebuildLibraryIndexes();
    _syncLibraryNodeOrder(persist: false);
    _notifyListeners();
    unawaited(AppDatabase.instance.deleteTracks(trackPaths.toList()));
    _saveGroupOrder();
    _saveLibraryNodeOrder();
  }

  int getTrackComparator(MusicTrack a, MusicTrack b) {
    final groupResult = a.groupTitle.toLowerCase().compareTo(
      b.groupTitle.toLowerCase(),
    );
    if (groupResult != 0) return groupResult;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  }

  List<LibraryNode> buildLibraryTree() => libraryTree;

  _LibraryTreeSnapshot _buildLibraryTreeSnapshot() {
    final rootNodes = <String, FolderNode>{};
    final folderIndexByPath = <String, Map<String, FolderNode>>{};
    final singleFiles = <TrackNode>[];
    final watchedRoots = _watchedFolders.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));

    for (final track in _library) {
      if (track.isSingle) {
        singleFiles.add(TrackNode(track));
        continue;
      }

      final dirPath = track.groupKey;
      final matchedRoot = _libraryRootPathForTrack(track, watchedRoots);

      if (!rootNodes.containsKey(matchedRoot)) {
        final rootName = _resolveRootNodeName(matchedRoot, track);
        rootNodes[matchedRoot] = FolderNode(rootName, matchedRoot, depth: 0);
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

    void sortFolder(FolderNode folder) {
      folder.children.sort((a, b) {
        if (a is FolderNode && b is TrackNode) return -1;
        if (a is TrackNode && b is FolderNode) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      for (final child in folder.children) {
        if (child is FolderNode) sortFolder(child);
      }
    }

    final topLevel = <LibraryNode>[];
    var leafFolderCount = 0;

    final topLevelOrderIndex = <String, int>{
      for (var i = 0; i < _libraryNodeOrder.length; i++)
        _libraryNodeOrder[i]: i,
    };
    final roots = rootNodes.values.toList();
    for (final root in roots) {
      sortFolder(root);
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

    return _LibraryTreeSnapshot(
      tree: List<LibraryNode>.unmodifiable(topLevel),
      leafFolderCount: leafFolderCount,
    );
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

  MusicTrack? trackByPath(String trackPath) => _libraryByPath[trackPath];

  PlaybackSession? sessionById(String sessionId) => _sessions[sessionId];

  String? sessionTrackPath(String sessionId) =>
      _sessions[sessionId]?.currentTrackPath;

  bool isTrackActive(String trackPath) =>
      _sessions.values.any((session) => session.currentTrackPath == trackPath);

  List<MusicTrack> tracksInSameGroup(String trackPath) {
    final track = trackByPath(trackPath);
    if (track == null) return [];
    return _tracksByGroup[track.groupKey] ?? const <MusicTrack>[];
  }
}
