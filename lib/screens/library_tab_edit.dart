part of 'library_tab.dart';

class LibraryEditPage extends ConsumerStatefulWidget {
  const LibraryEditPage({super.key, required this.libraryPath});

  final String libraryPath;

  @override
  ConsumerState<LibraryEditPage> createState() => _LibraryEditPageState();
}

class _LibraryEditPageState extends ConsumerState<LibraryEditPage> {
  final TextEditingController _searchController = TextEditingController();
  List<String> _diskAudioFilePaths = const <String>[];
  Set<String> _diskAudioFilePathSet = const <String>{};
  Set<String> _diskLiveFolderPaths = const <String>{};
  bool _diskSnapshotLoaded = false;
  Timer? _searchDebounceTimer;
  String _searchQuery = '';
  final Map<String, _LibraryEditFolderTreeNode> _folderStructureSnapshots =
      <String, _LibraryEditFolderTreeNode>{};
  int _folderStructureSnapshotRevision = 0;

  // Edit-tree cache (memoized per build inputs).
  Object? _editTreeCacheKey;
  List<_LibraryEditTreeNode>? _cachedEditTree;

  @override
  void initState() {
    super.initState();
    _loadDiskLibrarySnapshot();
  }

  Future<void> _loadDiskLibrarySnapshot() async {
    if (PathMatcher.isContentUri(widget.libraryPath)) {
      if (!mounted) return;
      setState(() {
        _diskAudioFilePaths = const <String>[];
        _diskAudioFilePathSet = const <String>{};
        _diskLiveFolderPaths = const <String>{};
        _diskSnapshotLoaded = false;
      });
      return;
    }
    final directory = Directory(widget.libraryPath);
    if (!await directory.exists()) {
      if (!mounted) return;
      final provider = ref.read(audioProviderFacadeProvider);
      provider.removeTracksDeletedFromFolder(
        widget.libraryPath,
        const <String>{},
      );
      provider.removeLibraryEntriesDeletedFromFolder(
        widget.libraryPath,
        widget.libraryPath,
        const <String>{},
      );
      setState(() {
        _diskAudioFilePaths = const <String>[];
        _diskAudioFilePathSet = const <String>{};
        _diskLiveFolderPaths = const <String>{};
        _diskSnapshotLoaded = true;
      });
      return;
    }
    final audioFiles = <String>{};
    final folderPaths = <String>{};
    final pendingDirs = Queue<Directory>()..add(directory);
    var processedEntities = 0;

    try {
      while (pendingDirs.isNotEmpty) {
        final currentDir = pendingDirs.removeFirst();
        late final Stream<FileSystemEntity> stream;
        try {
          stream = currentDir.list(followLinks: false);
        } catch (_) {
          continue;
        }
        await for (final entity in stream.handleError((_) {})) {
          processedEntities++;
          if (processedEntities % 200 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
          final normalizedPath = PathMatcher.normalize(entity.path);
          if (entity is Directory) {
            folderPaths.add(normalizedPath);
            pendingDirs.add(entity);
            continue;
          }
          if (entity is File && isSupportedMediaFile(normalizedPath)) {
            audioFiles.add(normalizedPath);
          }
        }
      }
    } catch (_) {}
    final liveFolderPaths = _buildLiveDiskFolderPathSet(
      folderPaths,
      audioFiles,
    );

    final sortedAudioFiles = audioFiles.toList(growable: false)
      ..sort(
        (a, b) => compareNatural(
          path.basenameWithoutExtension(a),
          path.basenameWithoutExtension(b),
        ),
      );
    if (!mounted) return;
    final retainedPaths = <String>{...sortedAudioFiles, ...liveFolderPaths};
    final provider = ref.read(audioProviderFacadeProvider);
    provider.removeTracksDeletedFromFolder(widget.libraryPath, audioFiles);
    provider.removeLibraryEntriesDeletedFromFolder(
      widget.libraryPath,
      widget.libraryPath,
      retainedPaths,
    );
    setState(() {
      _diskAudioFilePaths = sortedAudioFiles;
      _diskAudioFilePathSet = audioFiles;
      _diskLiveFolderPaths = liveFolderPaths;
      _diskSnapshotLoaded = true;
    });
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _confirmRemoveLibrary(BuildContext context) async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('remove_library'),
      message: i18n.tr('remove_library_confirm', {
        'name': _displaySourceName(widget.libraryPath),
      }),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('remove'),
      icon: Icons.library_music_rounded,
    );
    if (!confirmed || !context.mounted) return;
    await ref
        .read(audioProviderFacadeProvider)
        .removeLibrary(widget.libraryPath);
    if (context.mounted) {
      showAppSnackBar(
        context,
        i18n.tr('library_removed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.delete_outline_rounded,
      );
      await Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(libraryStateProvider);
    final i18n = context.watch<AppLanguageProvider>();
    final libraryService = ref.read(libraryServiceProvider);
    final cs = Theme.of(context).colorScheme;
    final excludedTracks = libraryService
        .excludedTracksForLibrary(widget.libraryPath)
        .where(_trackExistsInDiskSnapshot)
        .toList(growable: false);
    final excludedFolders = libraryService
        .excludedFoldersForLibrary(widget.libraryPath)
        .map(_folderPathForLibraryChild)
        .where(_folderExistsInDiskSnapshot)
        .toList(growable: false);
    final persistedEntries = libraryService
        .libraryEntriesForLibrary(widget.libraryPath)
        .where(_libraryEntryExistsInDiskSnapshot)
        .toList(growable: false);
    final childFolders = libraryService
        .childFoldersForLibrary(widget.libraryPath)
        .map(_folderPathForLibraryChild)
        .where(_folderExistsInDiskSnapshot)
        .toList(growable: false);
    final folderStructureSnapshots = _folderStructureSnapshots.entries
        .where((entry) => _folderExistsInDiskSnapshot(entry.key))
        .map((entry) => entry.value)
        .toList(growable: false);
    final cacheKey = Object.hash(
      _libraryTrackPathsHash(libraryService),
      Object.hashAll(_diskAudioFilePaths),
      _folderStructureSnapshotRevision,
      Object.hashAll(childFolders),
      Object.hashAll(excludedTracks),
      Object.hashAll(excludedFolders),
      _libraryEntriesHash(persistedEntries),
      Object.hashAll(
        folderStructureSnapshots.map((folder) => folder.folderPath),
      ),
      _searchQuery,
    );
    if (_editTreeCacheKey != cacheKey) {
      _editTreeCacheKey = cacheKey;
      _cachedEditTree = _filterEditTree(
        _buildEditTree(
          _collectLibraryEditTrackPaths(
            libraryService,
            _diskAudioFilePaths,
            excludedTracks,
            persistedEntries,
          ),
          <String>{
            ...childFolders,
            ...excludedFolders,
            for (final entry in persistedEntries)
              if (entry.isFolder) _folderPathForLibraryChild(entry.path),
          }.toList(growable: false),
          folderStructureSnapshots,
        ),
        _searchQuery,
      );
    }
    final editTree = _cachedEditTree!;
    final isEmpty = editTree.isEmpty;

    return Scaffold(
      backgroundColor: cs.surface,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + 92,
              16,
              24,
            ),
            children: [
              _buildSearchBar(i18n),
              const SizedBox(height: 12),
              if (isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 96),
                  child: Center(
                    child: Text(
                      _searchQuery.isEmpty
                          ? i18n.tr('library_edit_empty')
                          : i18n.tr('no_search_results'),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                )
              else ...[
                for (final node in editTree)
                  _LibraryEditTreeNodeWidget(
                    libraryPath: widget.libraryPath,
                    node: node,
                    initiallyExpanded: _searchQuery.isNotEmpty,
                  ),
              ],
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              icon: Icons.edit_note_rounded,
              title: i18n.tr('edit_library'),
              titleSuffix: Text(
                _displaySourceName(widget.libraryPath),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              trailing: SizedBox(
                width: 96,
                height: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: i18n.tr('remove_library'),
                      onPressed: () => _confirmRemoveLibrary(context),
                      icon: Icon(Icons.delete_outline_rounded, color: cs.error),
                    ),
                    IconButton(
                      tooltip: i18n.tr('close'),
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              bottomSpacing: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(AppLanguageProvider i18n) {
    final cs = Theme.of(context).colorScheme;
    final hasText = _searchController.text.isNotEmpty;
    return SizedBox(
      height: 38,
      child: TextField(
        controller: _searchController,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
        decoration: InputDecoration(
          filled: true,
          fillColor: cs.surfaceContainerHigh,
          prefixIcon: Icon(
            Icons.search_rounded,
            color: cs.onSurfaceVariant,
            size: 18,
          ),
          suffixIcon: hasText
              ? IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    _searchDebounceTimer?.cancel();
                    setState(() => _searchQuery = '');
                  },
                  color: cs.onSurfaceVariant,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                )
              : null,
          hintText: i18n.tr('search_audio_placeholder'),
          hintStyle: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(19),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(19),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(19),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          isDense: true,
        ),
        onChanged: (value) {
          _searchDebounceTimer?.cancel();
          _searchDebounceTimer = Timer(const Duration(milliseconds: 180), () {
            if (!mounted) return;
            setState(() => _searchQuery = value.trim());
          });
          setState(() {});
        },
      ),
    );
  }

  int _libraryTrackPathsHash(LibraryService libraryService) {
    return Object.hashAll(
      libraryService.library
          .where((track) => _trackBelongsToLibrary(track.path))
          .where((track) => _trackExistsInDiskSnapshot(track.path))
          .map((track) => PathMatcher.normalize(track.path)),
    );
  }

  bool get _hasAuthoritativeDiskSnapshot =>
      !PathMatcher.isContentUri(widget.libraryPath) && _diskSnapshotLoaded;

  Set<String> _buildLiveDiskFolderPathSet(
    Set<String> scannedFolderPaths,
    Set<String> scannedTrackPaths,
  ) {
    final rootPath = PathMatcher.normalize(widget.libraryPath);
    final liveFolders = <String>{};

    void addFolderAndAncestors(String folderPath) {
      var current = PathMatcher.normalize(folderPath);
      while (!PathMatcher.equalsNormalized(current, rootPath) &&
          PathMatcher.isWithinOrEqualNormalized(current, rootPath)) {
        liveFolders.add(current);
        final parent = path.dirname(current);
        if (parent == current || parent == '.' || parent.isEmpty) break;
        current = parent;
      }
    }

    for (final folderPath in scannedFolderPaths) {
      addFolderAndAncestors(folderPath);
    }
    for (final trackPath in scannedTrackPaths) {
      addFolderAndAncestors(path.dirname(trackPath));
    }
    return liveFolders;
  }

  bool _trackExistsInDiskSnapshot(String trackPath) {
    if (!_hasAuthoritativeDiskSnapshot) return true;
    return _diskAudioFilePathSet.contains(PathMatcher.normalize(trackPath));
  }

  bool _folderExistsInDiskSnapshot(String folderPath) {
    if (!_hasAuthoritativeDiskSnapshot) return true;
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    return PathMatcher.equalsNormalized(
          normalizedFolderPath,
          widget.libraryPath,
        ) ||
        _diskLiveFolderPaths.contains(normalizedFolderPath);
  }

  bool _libraryEntryExistsInDiskSnapshot(LibraryEntry entry) {
    if (entry.isFolder) {
      return _folderExistsInDiskSnapshot(
        _folderPathForLibraryChild(entry.path),
      );
    }
    return _trackExistsInDiskSnapshot(entry.path);
  }

  int _libraryEntriesHash(List<LibraryEntry> entries) {
    return Object.hashAll(
      entries.map(
        (entry) => Object.hash(
          entry.path,
          entry.kind,
          entry.state,
          entry.parentPath,
          entry.displayName,
        ),
      ),
    );
  }

  List<String> _collectLibraryEditTrackPaths(
    LibraryService libraryService,
    List<String> diskAudioFilePaths,
    List<String> excludedTracks,
    List<LibraryEntry> persistedEntries,
  ) {
    final tracks = <String>{
      for (final track in libraryService.library)
        if (_trackBelongsToLibrary(track.path) &&
            _trackExistsInDiskSnapshot(track.path))
          PathMatcher.normalize(track.path),
      for (final entry in persistedEntries)
        if (entry.isTrack && _trackBelongsToLibrary(entry.path))
          PathMatcher.normalize(entry.path),
      for (final trackPath in diskAudioFilePaths)
        if (_trackBelongsToLibrary(trackPath)) PathMatcher.normalize(trackPath),
      for (final trackPath in excludedTracks)
        if (_trackBelongsToLibrary(trackPath)) PathMatcher.normalize(trackPath),
    }.toList(growable: false);

    tracks.sort(
      (a, b) => compareNatural(
        path.basenameWithoutExtension(a),
        path.basenameWithoutExtension(b),
      ),
    );
    return tracks;
  }

  List<_LibraryEditTreeNode> _buildEditTree(
    List<String> trackPaths,
    List<String> persistentFolderPaths,
    List<_LibraryEditFolderTreeNode> restoringFolderSnapshots,
  ) {
    final rootPath = PathMatcher.normalize(widget.libraryPath);
    final folderByPath = <String, _LibraryEditFolderTreeNode>{};
    final roots = <_LibraryEditTreeNode>[];
    final insertedTrackPaths = <String>{};

    _LibraryEditFolderTreeNode? ensureFolder(String folderPath) {
      final normalizedFolderPath = PathMatcher.normalize(folderPath);
      if (PathMatcher.equalsNormalized(normalizedFolderPath, rootPath) ||
          !PathMatcher.isWithinOrEqual(normalizedFolderPath, rootPath)) {
        return null;
      }

      final existing = folderByPath[normalizedFolderPath];
      if (existing != null) return existing;

      final parentPath = _parentFolderPath(normalizedFolderPath, rootPath);
      final parent = parentPath == null ? null : ensureFolder(parentPath);
      final folder = _LibraryEditFolderTreeNode(
        folderPath: normalizedFolderPath,
        depth: _relativeFolderDepth(normalizedFolderPath),
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
      if (!_trackBelongsToLibrary(normalizedTrackPath) ||
          !insertedTrackPaths.add(normalizedTrackPath)) {
        return;
      }
      final trackNode = _LibraryEditTrackTreeNode(normalizedTrackPath);
      final folderPath = _folderPathForTrack(normalizedTrackPath);
      final folder = folderPath == null ? null : ensureFolder(folderPath);
      if (folder == null) {
        roots.add(trackNode);
      } else {
        folder.children.add(trackNode);
      }
    }

    void mergeFolderSnapshot(_LibraryEditFolderTreeNode snapshot) {
      final folder = ensureFolder(snapshot.folderPath);
      if (folder == null) return;
      for (final child in snapshot.children) {
        if (child is _LibraryEditFolderTreeNode) {
          mergeFolderSnapshot(child);
        } else if (child is _LibraryEditTrackTreeNode) {
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

  String? _parentFolderPath(String folderPath, String rootPath) {
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

  int _relativeFolderDepth(String folderPath) {
    final relative = PathMatcher.relativeWithin(
      PathMatcher.normalize(folderPath),
      PathMatcher.normalize(widget.libraryPath),
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

  String? _folderPathForTrack(String trackPath) {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final rootPath = PathMatcher.normalize(widget.libraryPath);
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

  String _folderPathForLibraryChild(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final rootPath = PathMatcher.normalize(widget.libraryPath);
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

  void _sortEditTree(List<_LibraryEditTreeNode> nodes) {
    nodes.sort((a, b) {
      if (a is _LibraryEditFolderTreeNode && b is _LibraryEditTrackTreeNode) {
        return -1;
      }
      if (a is _LibraryEditTrackTreeNode && b is _LibraryEditFolderTreeNode) {
        return 1;
      }
      return compareNatural(a.name, b.name);
    });
    for (final node in nodes) {
      if (node is _LibraryEditFolderTreeNode) {
        _sortEditTree(node.children);
      }
    }
  }

  List<_LibraryEditTreeNode> _filterEditTree(
    List<_LibraryEditTreeNode> nodes,
    String query,
  ) {
    if (query.isEmpty) return nodes;
    final normalizedQuery = query.toLowerCase();
    final result = <_LibraryEditTreeNode>[];

    for (final node in nodes) {
      if (node is _LibraryEditFolderTreeNode) {
        final filteredChildren = _filterEditTree(node.children, query);
        if (filteredChildren.isEmpty) continue;
        result.add(
          _LibraryEditFolderTreeNode(
            folderPath: node.folderPath,
            depth: node.depth,
            children: filteredChildren,
          ),
        );
      } else if (node is _LibraryEditTrackTreeNode &&
          _trackPathMatchesQuery(node.trackPath, normalizedQuery)) {
        result.add(node);
      }
    }

    return result;
  }

  bool _trackPathMatchesQuery(String trackPath, String normalizedQuery) {
    final track = ref.read(libraryServiceProvider).trackByPath(trackPath);
    return path
            .basenameWithoutExtension(trackPath)
            .toLowerCase()
            .contains(normalizedQuery) ||
        trackPath.toLowerCase().contains(normalizedQuery) ||
        (track?.displayName.toLowerCase().contains(normalizedQuery) ?? false) ||
        (track?.groupTitle.toLowerCase().contains(normalizedQuery) ?? false) ||
        (track?.groupSubtitle.toLowerCase().contains(normalizedQuery) ?? false);
  }

  int _includedEditTrackCount(
    _LibraryEditFolderTreeNode folder,
    LibraryService libraryService,
  ) {
    var count = 0;
    for (final child in folder.children) {
      if (child is _LibraryEditTrackTreeNode) {
        if (!libraryService.isLibraryPathExcluded(
          widget.libraryPath,
          child.trackPath,
        )) {
          count++;
        }
      } else if (child is _LibraryEditFolderTreeNode) {
        count += _includedEditTrackCount(child, libraryService);
      }
    }
    return count;
  }

  bool _trackBelongsToLibrary(String trackPath) {
    return PathMatcher.isWithinOrEqual(trackPath, widget.libraryPath);
  }

  void rememberFolderStructureSnapshot(
    String folderPath,
    _LibraryEditFolderTreeNode folder,
  ) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    setState(() {
      _folderStructureSnapshots[normalizedFolderPath] = _cloneFolderNode(
        folder,
      );
      _folderStructureSnapshotRevision++;
    });
  }

  _LibraryEditFolderTreeNode _cloneFolderNode(
    _LibraryEditFolderTreeNode folder,
  ) {
    return _LibraryEditFolderTreeNode(
      folderPath: folder.folderPath,
      depth: folder.depth,
      children: folder.children
          .map<_LibraryEditTreeNode>((child) {
            if (child is _LibraryEditFolderTreeNode) {
              return _cloneFolderNode(child);
            }
            return _LibraryEditTrackTreeNode(
              (child as _LibraryEditTrackTreeNode).trackPath,
            );
          })
          .toList(growable: false),
    );
  }
}

abstract class _LibraryEditTreeNode {
  String get name;
  String get pathValue;
}

class _LibraryEditFolderTreeNode extends _LibraryEditTreeNode {
  _LibraryEditFolderTreeNode({
    required this.folderPath,
    required this.depth,
    List<_LibraryEditTreeNode>? children,
  }) : children = children ?? <_LibraryEditTreeNode>[];

  final String folderPath;
  final int depth;
  final List<_LibraryEditTreeNode> children;

  @override
  String get name => _displaySourceName(folderPath);

  @override
  String get pathValue => folderPath;
}

class _LibraryEditTrackTreeNode extends _LibraryEditTreeNode {
  _LibraryEditTrackTreeNode(this.trackPath);

  final String trackPath;

  @override
  String get name => _displayTrackName(trackPath);

  @override
  String get pathValue => trackPath;
}

class _LibraryEditTreeNodeWidget extends ConsumerWidget {
  const _LibraryEditTreeNodeWidget({
    super.key,
    required this.libraryPath,
    required this.node,
    required this.initiallyExpanded,
  });

  final String libraryPath;
  final _LibraryEditTreeNode node;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(libraryStateProvider);
    final libraryService = ref.read(libraryServiceProvider);
    if (node is _LibraryEditFolderTreeNode) {
      return _LibraryEditFolderTreeTile(
        libraryPath: libraryPath,
        folder: node as _LibraryEditFolderTreeNode,
        initiallyExpanded: initiallyExpanded,
      );
    }
    if (node is _LibraryEditTrackTreeNode) {
      final track = node as _LibraryEditTrackTreeNode;
      final explicitExcluded = libraryService.isLibraryTrackExplicitlyExcluded(
        libraryPath,
        track.trackPath,
      );
      final muted = libraryService.isLibraryPathExcluded(
        libraryPath,
        track.trackPath,
      );
      return _LibraryEditTrackTile(
        libraryPath: libraryPath,
        trackPath: track.trackPath,
        explicitExcluded: explicitExcluded,
        muted: muted,
      );
    }
    return const SizedBox.shrink();
  }
}

class _LibraryEditFolderTreeTile extends ConsumerStatefulWidget {
  const _LibraryEditFolderTreeTile({
    required this.libraryPath,
    required this.folder,
    required this.initiallyExpanded,
  });

  final String libraryPath;
  final _LibraryEditFolderTreeNode folder;
  final bool initiallyExpanded;

  @override
  ConsumerState<_LibraryEditFolderTreeTile> createState() =>
      _LibraryEditFolderTreeTileState();
}

class _LibraryEditFolderTreeTileState
    extends ConsumerState<_LibraryEditFolderTreeTile> {
  final ExpansibleController _expansionController = ExpansibleController();
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant _LibraryEditFolderTreeTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initiallyExpanded && !_expanded) {
      _expanded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expansionController.expand();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(libraryStateProvider);
    final i18n = context.watch<AppLanguageProvider>();
    final libraryService = ref.read(libraryServiceProvider);
    final audioProvider = ref.read(audioProviderFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final editState = context.findAncestorStateOfType<_LibraryEditPageState>();
    final folderPath = widget.folder.folderPath;
    final explicitExcluded = libraryService.isLibraryFolderExplicitlyExcluded(
      widget.libraryPath,
      folderPath,
    );
    final inheritedExcluded = libraryService.isLibraryPathInheritedExcluded(
      widget.libraryPath,
      folderPath,
    );
    final muted = libraryService.isLibraryPathExcluded(
      widget.libraryPath,
      folderPath,
    );
    final includedCount =
        editState?._includedEditTrackCount(widget.folder, libraryService) ?? 0;
    final isRootFolder = widget.folder.depth == 0;

    final content = Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        controller: _expansionController,
        initiallyExpanded: widget.initiallyExpanded,
        onExpansionChanged: (expanded) {
          if (_expanded == expanded) return;
          setState(() => _expanded = expanded);
        },
        tilePadding: EdgeInsets.fromLTRB(isRootFolder ? 14 : 6, 3, 6, 3),
        childrenPadding: EdgeInsets.fromLTRB(isRootFolder ? 12 : 16, 0, 0, 6),
        leading: Icon(
          muted ? Icons.folder_off_rounded : Icons.folder_rounded,
          size: isRootFolder ? 24 : 20,
          color: muted ? cs.onSurfaceVariant : cs.primary,
        ),
        title: Text(
          widget.folder.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: muted ? cs.onSurfaceVariant : cs.onSurface,
            fontWeight: isRootFolder ? FontWeight.w900 : FontWeight.w800,
          ),
        ),
        subtitle: Text(
          muted
              ? i18n.tr('excluded')
              : i18n.tr('audio_count', {'count': includedCount}),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        trailing: SizedBox(
          width: 126,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: TextButton.icon(
                  style: muted ? _libraryMutedButtonStyle(cs) : null,
                  onPressed: inheritedExcluded
                      ? null
                      : () {
                          if (widget.folder.children.isNotEmpty) {
                            editState?.rememberFolderStructureSnapshot(
                              folderPath,
                              widget.folder,
                            );
                          }
                          audioProvider.setLibraryFolderExcluded(
                            widget.libraryPath,
                            folderPath,
                            !explicitExcluded,
                          );
                        },
                  icon: Icon(
                    explicitExcluded
                        ? Icons.restore_rounded
                        : Icons.block_rounded,
                    size: 16,
                  ),
                  label: Text(
                    explicitExcluded ? i18n.tr('restore') : i18n.tr('exclude'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              IgnorePointer(
                child: AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.expand_more_rounded,
                    color: cs.onSurfaceVariant,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
        children: [
          for (final child in widget.folder.children)
            _LibraryEditTreeNodeWidget(
              key: ValueKey(child.pathValue),
              libraryPath: widget.libraryPath,
              node: child,
              initiallyExpanded: widget.initiallyExpanded,
            ),
        ],
      ),
    );

    if (!isRootFolder) {
      return Padding(
        padding: const EdgeInsets.only(left: 12, bottom: 2),
        child: content,
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      color: muted
          ? cs.surfaceContainerHighest.withValues(alpha: 0.46)
          : cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: muted
              ? cs.outlineVariant.withValues(alpha: 0.48)
              : cs.outlineVariant,
        ),
      ),
      child: content,
    );
  }
}

class _LibraryEditTrackTile extends ConsumerWidget {
  const _LibraryEditTrackTile({
    required this.libraryPath,
    required this.trackPath,
    required this.explicitExcluded,
    this.muted,
  });

  final String libraryPath;
  final String trackPath;
  final bool explicitExcluded;
  final bool? muted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(libraryStateProvider);
    final i18n = context.watch<AppLanguageProvider>();
    final libraryService = ref.read(libraryServiceProvider);
    final provider = ref.read(audioProviderFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final track = libraryService.trackByPath(trackPath);
    final persistedDisplayName = libraryService
        .libraryEntriesForLibrary(libraryPath)
        .where(
          (entry) =>
              entry.isTrack &&
              PathMatcher.equalsNormalized(entry.path, trackPath) &&
              entry.displayName.trim().isNotEmpty,
        )
        .firstOrNull
        ?.displayName
        .trim();
    final title = track?.displayName.trim().isNotEmpty == true
        ? track!.displayName
        : persistedDisplayName ??
              PathDisplay.fileName(trackPath, withoutExtension: true);
    final isMuted =
        muted ?? libraryService.isLibraryPathExcluded(libraryPath, trackPath);
    final inheritedExcluded = libraryService.isLibraryPathInheritedExcluded(
      libraryPath,
      trackPath,
    );

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      leading: Icon(
        isMuted ? Icons.music_off_rounded : Icons.music_note_rounded,
        color: isMuted ? cs.onSurfaceVariant : cs.primary,
      ),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isMuted ? cs.onSurfaceVariant : cs.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: isMuted ? Text(i18n.tr('excluded')) : null,
      trailing: TextButton(
        style: isMuted ? _libraryMutedButtonStyle(cs) : null,
        onPressed: inheritedExcluded
            ? null
            : () {
                provider.setLibraryTrackExcluded(
                  libraryPath,
                  trackPath,
                  !explicitExcluded,
                );
              },
        child: Text(explicitExcluded ? i18n.tr('restore') : i18n.tr('exclude')),
      ),
    );
  }
}

ButtonStyle _libraryMutedButtonStyle(ColorScheme cs) {
  return TextButton.styleFrom(
    foregroundColor: cs.onSurfaceVariant,
    backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.72),
    side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.68)),
  );
}
