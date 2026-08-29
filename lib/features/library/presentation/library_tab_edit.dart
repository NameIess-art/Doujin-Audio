part of 'library_tab.dart';

final _libraryEditTrackViewStateProvider =
    Provider.family<_LibraryEditTrackViewState, _LibraryEditTrackKey>((
      ref,
      key,
    ) {
      ref.watch(
        libraryStateProvider.select(
          (value) => value.value?.contentRevision ?? 0,
        ),
      );
      final libraryService = ref.read(libraryFacadeProvider);
      final track = libraryService.trackByPath(key.trackPath);
      final persistedDisplayName = libraryService
          .libraryEntryDisplayNameForPath(key.libraryPath, key.trackPath);
      final title = track?.displayName.trim().isNotEmpty == true
          ? track!.displayName
          : persistedDisplayName ??
                PathDisplay.fileName(key.trackPath, withoutExtension: true);
      return _LibraryEditTrackViewState(
        title: title,
        explicitExcluded: libraryService.isLibraryTrackExplicitlyExcluded(
          key.libraryPath,
          key.trackPath,
        ),
        muted: libraryService.isLibraryPathExcluded(
          key.libraryPath,
          key.trackPath,
        ),
        inheritedExcluded: libraryService.isLibraryPathInheritedExcluded(
          key.libraryPath,
          key.trackPath,
        ),
      );
    });

class _LibraryEditTrackKey {
  const _LibraryEditTrackKey(this.libraryPath, this.trackPath);

  final String libraryPath;
  final String trackPath;

  @override
  bool operator ==(Object other) {
    return other is _LibraryEditTrackKey &&
        other.libraryPath == libraryPath &&
        other.trackPath == trackPath;
  }

  @override
  int get hashCode => Object.hash(libraryPath, trackPath);
}

class _LibraryEditTrackViewState {
  const _LibraryEditTrackViewState({
    required this.title,
    required this.explicitExcluded,
    required this.muted,
    required this.inheritedExcluded,
  });

  final String title;
  final bool explicitExcluded;
  final bool muted;
  final bool inheritedExcluded;

  @override
  bool operator ==(Object other) {
    return other is _LibraryEditTrackViewState &&
        other.title == title &&
        other.explicitExcluded == explicitExcluded &&
        other.muted == muted &&
        other.inheritedExcluded == inheritedExcluded;
  }

  @override
  int get hashCode =>
      Object.hash(title, explicitExcluded, muted, inheritedExcluded);
}

class LibraryManagementPage extends ConsumerWidget {
  const LibraryManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final libraries = ref.watch(
      libraryListUiProvider.select((state) => state.watchedLibraries),
    );
    return Scaffold(
      backgroundColor: cs.surface,
      body: Stack(
        children: [
          if (libraries.isEmpty)
            Center(
              child: Text(
                i18n.tr('library_manage_empty'),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            ListView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + 60,
                16,
                24,
              ),
              itemCount: libraries.length,
              itemBuilder: (context, index) {
                final libraryPath = libraries[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  elevation: 0,
                  color: cs.surfaceContainerHigh,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.of(context).push(
                      buildAppPageRoute<void>(
                        context: context,
                        child: LibraryEditPage(libraryPath: libraryPath),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                      child: ListTile(
                        title: Text(
                          _displaySourceName(libraryPath),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            PathDisplay.displayPathFor(libraryPath),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: i18n.tr('remove_library'),
                          onPressed: () => _confirmRemoveWatchedLibrary(
                            context,
                            ref,
                            libraryPath,
                          ),
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            color: cs.error.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              icon: Icons.edit_note_rounded,
              title: i18n.tr('edit_library'),
              leading: IconButton(
                tooltip: i18n.tr('close'),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> _confirmRemoveWatchedLibrary(
  BuildContext context,
  WidgetRef ref,
  String libraryPath,
) async {
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  final confirmed = await showConfirmActionDialog(
    context: context,
    title: i18n.tr('remove_library'),
    message: i18n.tr('remove_library_confirm', {
      'name': _displaySourceName(libraryPath),
    }),
    cancelLabel: i18n.tr('cancel'),
    confirmLabel: i18n.tr('remove_library'),
    icon: Icons.library_music_rounded,
  );
  if (!confirmed || !context.mounted) return false;
  final result = await ref
      .read(libraryFacadeProvider)
      .removeFolder(libraryPath);
  if (!context.mounted || result == null) return result != null;
  _showLibraryRemovalFeedback(context, result);
  return result == LibraryRemovalKind.libraryPermanent;
}

class LibraryEditPage extends ConsumerStatefulWidget {
  const LibraryEditPage({
    super.key,
    required this.libraryPath,
    @visibleForTesting this.entryEditorService,
  });

  final String libraryPath;
  @visibleForTesting
  final LibraryEntryEditorService? entryEditorService;

  @override
  ConsumerState<LibraryEditPage> createState() => _LibraryEditPageState();
}

class _LibraryEditPageState extends ConsumerState<LibraryEditPage>
    with WidgetsBindingObserver {
  late final LibraryEntryEditorService _entryEditorService;
  final TextEditingController _searchController = TextEditingController();
  List<String> _diskAudioFilePaths = const <String>[];
  Set<String> _diskAudioFilePathSet = const <String>{};
  Set<String> _diskLiveFolderPaths = const <String>{};
  bool _diskSnapshotLoaded = false;
  bool _initialLoadPending = true;
  bool _diskSnapshotError = false;
  int _diskSnapshotGeneration = 0;
  int _diskSnapshotRevision = 0;
  Timer? _searchDebounceTimer;
  String _searchQuery = '';
  final Map<String, _LibraryEditFolderTreeNode> _folderStructureSnapshots =
      <String, _LibraryEditFolderTreeNode>{};
  int _folderStructureSnapshotRevision = 0;

  // Edit-tree caches: structural work is independent from query filtering.
  Object? _baseEditTreeCacheKey;
  List<_LibraryEditTreeNode>? _cachedBaseEditTree;
  Object? _filteredEditTreeCacheKey;
  List<_LibraryEditTreeNode>? _cachedEditTree;
  int _searchMetadataRevision = -1;
  final Map<String, String> _trackSearchTextCache = <String, String>{};

  @override
  void initState() {
    super.initState();
    _entryEditorService =
        widget.entryEditorService ?? LibraryEntryEditorService();
    WidgetsBinding.instance.addObserver(this);
    _loadDiskLibrarySnapshot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadDiskLibrarySnapshot());
    }
  }

  Future<void> _loadDiskLibrarySnapshot() async {
    final requestGeneration = ++_diskSnapshotGeneration;
    late final LibraryEntryDiskSnapshot snapshot;
    try {
      snapshot = await _entryEditorService.loadDiskSnapshot(widget.libraryPath);
    } catch (_) {
      if (!mounted || requestGeneration != _diskSnapshotGeneration) return;
      _showDiskSnapshotFailure(requestGeneration);
      return;
    }
    if (!mounted || requestGeneration != _diskSnapshotGeneration) return;
    if (!snapshot.authoritative) {
      _showDiskSnapshotFailure(requestGeneration);
      return;
    }

    final audioFilePaths = snapshot.audioFilePathSet;
    final liveFolderPaths = _buildLiveDiskFolderPathSet(
      scannedTrackPaths: audioFilePaths,
      scannedFolderPaths: snapshot.scannedFolderPaths,
    );
    final retainedPaths = <String>{
      ...snapshot.audioFilePaths,
      ...liveFolderPaths,
    };
    final library = ref.read(libraryFacadeProvider);
    library.removeTracksDeletedFromFolder(widget.libraryPath, audioFilePaths);
    library.removeLibraryEntriesDeletedFromFolder(
      widget.libraryPath,
      widget.libraryPath,
      retainedPaths,
    );
    setState(() {
      _diskAudioFilePaths = snapshot.audioFilePaths;
      _diskAudioFilePathSet = audioFilePaths;
      _diskLiveFolderPaths = liveFolderPaths;
      _diskSnapshotRevision++;
      _diskSnapshotLoaded = true;
      _diskSnapshotError = false;
      _initialLoadPending = false;
    });
  }

  void _showDiskSnapshotFailure(int requestGeneration) {
    if (!mounted || requestGeneration != _diskSnapshotGeneration) return;
    setState(() {
      _diskSnapshotError = true;
      _initialLoadPending = false;
    });
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('scan_failed_next_step'),
      tone: AppFeedbackTone.warning,
      icon: Icons.warning_amber_rounded,
      actionLabel: i18n.tr('retry'),
      onAction: () => unawaited(_loadDiskLibrarySnapshot()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _confirmRemoveLibrary(BuildContext context) async {
    final removed = await _confirmRemoveWatchedLibrary(
      context,
      ref,
      widget.libraryPath,
    );
    if (removed && context.mounted) {
      await Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final libraryService = ref.read(libraryFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final localSnapshotPending = _initialLoadPending;
    final structureRevision = libraryService.structureRevision;
    if (_searchMetadataRevision != structureRevision) {
      _searchMetadataRevision = structureRevision;
      _trackSearchTextCache.clear();
    }
    final baseCacheKey = Object.hash(
      structureRevision,
      _diskSnapshotRevision,
      _folderStructureSnapshotRevision,
      localSnapshotPending,
      _diskSnapshotError,
    );
    if (_baseEditTreeCacheKey != baseCacheKey) {
      _baseEditTreeCacheKey = baseCacheKey;
      final excludedTracks = localSnapshotPending
          ? const <String>[]
          : libraryService
                .excludedTracksForLibrary(widget.libraryPath)
                .where(_trackExistsInDiskSnapshot)
                .toList(growable: false);
      final excludedFolders = localSnapshotPending
          ? const <String>[]
          : libraryService
                .excludedFoldersForLibrary(widget.libraryPath)
                .map(_folderPathForLibraryChild)
                .where(_folderExistsInDiskSnapshot)
                .toList(growable: false);
      final persistedEntries = localSnapshotPending
          ? const <LibraryEntry>[]
          : libraryService
                .libraryEntriesForLibrary(widget.libraryPath)
                .where(_libraryEntryExistsInDiskSnapshot)
                .toList(growable: false);
      final childFolders = localSnapshotPending
          ? const <String>[]
          : libraryService
                .childFoldersForLibrary(widget.libraryPath)
                .map(_folderPathForLibraryChild)
                .where(_folderExistsInDiskSnapshot)
                .toList(growable: false);
      final folderStructureSnapshots = localSnapshotPending
          ? const <_LibraryEditFolderTreeNode>[]
          : _folderStructureSnapshots.entries
                .where((entry) => _folderExistsInDiskSnapshot(entry.key))
                .map((entry) => entry.value)
                .toList(growable: false);
      final editTrackPaths = localSnapshotPending
          ? const <String>[]
          : _collectLibraryEditTrackPaths(
              libraryService,
              _diskAudioFilePaths,
              excludedTracks,
              persistedEntries,
            );
      final persistentFolderPaths =
          localSnapshotPending
                ? <String>[]
                : <String>{
                    ...childFolders,
                    ...excludedFolders,
                    for (final entry in persistedEntries)
                      if (entry.isFolder)
                        _folderPathForLibraryChild(entry.path),
                  }.toList(growable: false)
            ..sort(compareNatural);
      _cachedBaseEditTree = _buildEditTree(
        editTrackPaths,
        persistentFolderPaths,
        folderStructureSnapshots,
      );
    }
    final filteredCacheKey = Object.hash(baseCacheKey, _searchQuery);
    if (_filteredEditTreeCacheKey != filteredCacheKey) {
      _filteredEditTreeCacheKey = filteredCacheKey;
      _cachedEditTree = _filterEditTree(_cachedBaseEditTree!, _searchQuery);
    }
    final editTree = _cachedEditTree!;
    final isEmpty = editTree.isEmpty;
    final snapshotError = _diskSnapshotError;

    return Scaffold(
      backgroundColor: cs.surface,
      body: Stack(
        children: [
          ListView.builder(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + 60,
              16,
              24,
            ),
            itemCount: localSnapshotPending || isEmpty
                ? 2
                : snapshotError
                ? editTree.length + 2
                : editTree.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _buildSearchBar(i18n),
                );
              }
              if (localSnapshotPending) {
                return Padding(
                  padding: const EdgeInsets.only(top: 96),
                  child: Center(
                    child: CircularProgressIndicator(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                );
              }
              if (snapshotError && index == 1) {
                return Padding(
                  padding: const EdgeInsets.only(top: 96),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          i18n.tr('scan_failed_next_step'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: () =>
                              unawaited(_loadDiskLibrarySnapshot()),
                          child: Text(i18n.tr('retry')),
                        ),
                      ],
                    ),
                  ),
                );
              }
              if (isEmpty) {
                return Padding(
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
                );
              }
              final node = editTree[index - (snapshotError ? 2 : 1)];
              return _LibraryEditTreeNodeWidget(
                key: ValueKey(node.pathValue),
                libraryPath: widget.libraryPath,
                node: node,
                initiallyExpanded: _searchQuery.isNotEmpty,
              );
            },
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
              leading: IconButton(
                tooltip: i18n.tr('close'),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              trailing: IconButton(
                tooltip: i18n.tr('remove_library'),
                onPressed: () => _confirmRemoveLibrary(context),
                icon: Icon(Icons.delete_outline_rounded, color: cs.error),
              ),
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
      height: 34,
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
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 7,
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

  bool get _hasAuthoritativeDiskSnapshot => _diskSnapshotLoaded;

  Set<String> _buildLiveDiskFolderPathSet({
    required Set<String> scannedTrackPaths,
    Iterable<String> scannedFolderPaths = const <String>[],
  }) {
    final rootPath = PathMatcher.normalize(widget.libraryPath);
    final liveFolders = <String>{};

    void addFolderAndAncestors(String folderPath) {
      var current = PathMatcher.normalize(folderPath);
      while (!PathMatcher.equalsNormalized(current, rootPath) &&
          PathMatcher.isWithinOrEqualNormalized(current, rootPath)) {
        liveFolders.add(current);
        final parent = _parentFolderPath(current, rootPath);
        if (parent == null ||
            parent == current ||
            parent == '.' ||
            parent.isEmpty) {
          break;
        }
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

  List<String> _collectLibraryEditTrackPaths(
    LibraryFacade libraryService,
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
    final searchableText = _trackSearchTextCache.putIfAbsent(trackPath, () {
      final track = ref.read(libraryFacadeProvider).trackByPath(trackPath);
      return <String>[
        path.basenameWithoutExtension(trackPath),
        trackPath,
        if (track != null) ...[
          track.displayName,
          track.groupTitle,
          track.groupSubtitle,
        ],
      ].join('\u0000').toLowerCase();
    });
    return searchableText.contains(normalizedQuery);
  }

  int _includedEditTrackCount(
    _LibraryEditFolderTreeNode folder,
    LibraryFacade libraryService,
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
    ref.watch(
      libraryStateProvider.select(
        (value) => value.value?.structureRevision ?? 0,
      ),
    );
    if (node is _LibraryEditFolderTreeNode) {
      return _LibraryEditFolderTreeTile(
        libraryPath: libraryPath,
        folder: node as _LibraryEditFolderTreeNode,
        initiallyExpanded: initiallyExpanded,
      );
    }
    if (node is _LibraryEditTrackTreeNode) {
      final track = node as _LibraryEditTrackTreeNode;
      return _LibraryEditTrackTile(
        libraryPath: libraryPath,
        trackPath: track.trackPath,
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
    ref.watch(
      libraryStateProvider.select((value) => value.value?.contentRevision ?? 0),
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final libraryService = ref.read(libraryFacadeProvider);
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
        expansionAnimationStyle: appExpansionAnimationStyle(context),
        key: PageStorageKey<String>(
          'library-edit-folder:${widget.libraryPath}:$folderPath',
        ),
        controller: _expansionController,
        initiallyExpanded: widget.initiallyExpanded,
        onExpansionChanged: (expanded) {
          if (_expanded == expanded) return;
          setState(() => _expanded = expanded);
        },
        tilePadding: EdgeInsets.fromLTRB(isRootFolder ? 14 : 6, 3, 6, 3),
        childrenPadding: EdgeInsets.fromLTRB(isRootFolder ? 8 : 4, 0, 0, 6),
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
            color: muted
                ? cs.onSurfaceVariant
                : (_expanded ? cs.primary : cs.onSurface),
            fontWeight: isRootFolder ? FontWeight.w800 : FontWeight.w700,
          ),
        ),
        subtitle: Text(
          i18n.tr('audio_count', {'count': includedCount}),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButtonTheme(
              data: TextButtonThemeData(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              child: TextButton.icon(
                onPressed: inheritedExcluded
                    ? null
                    : () {
                        if (widget.folder.children.isNotEmpty) {
                          editState?.rememberFolderStructureSnapshot(
                            folderPath,
                            widget.folder,
                          );
                        }
                        libraryService.setLibraryFolderExcluded(
                          widget.libraryPath,
                          folderPath,
                          !explicitExcluded,
                        );
                      },
                style: explicitExcluded
                    ? null
                    : TextButton.styleFrom(
                        foregroundColor: cs.error,
                      ),
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
                  color: muted
                      ? cs.onSurfaceVariant
                      : (_expanded ? cs.primary : cs.onSurfaceVariant),
                  size: 20,
                ),
              ),
            ),
          ],
        ),
        children: _expanded || widget.initiallyExpanded
            ? [
                for (final child in widget.folder.children)
                  _LibraryEditTreeNodeWidget(
                    key: ValueKey(child.pathValue),
                    libraryPath: widget.libraryPath,
                    node: child,
                    initiallyExpanded: widget.initiallyExpanded,
                  ),
              ]
            : const <Widget>[],
      ),
    );

    if (!isRootFolder) {
      return Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 2),
        child: content,
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: muted
          ? cs.surfaceContainerHighest.withValues(alpha: 0.46)
          : cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: content,
    );
  }
}

class _LibraryEditTrackTile extends ConsumerWidget {
  const _LibraryEditTrackTile({
    required this.libraryPath,
    required this.trackPath,
  });

  final String libraryPath;
  final String trackPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final viewState = ref.watch(
      _libraryEditTrackViewStateProvider(
        _LibraryEditTrackKey(libraryPath, trackPath),
      ),
    );
    final libraryFacade = ref.read(libraryFacadeProvider);
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 1, 6, 1),
      child: Material(
        key: ValueKey('library-edit-track-surface:$trackPath'),
        color: cs.surfaceContainerHigh.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          dense: true,
          minVerticalPadding: 2,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 2,
          ),
          leading: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: viewState.muted
                  ? cs.onSurfaceVariant.withValues(alpha: 0.12)
                  : cs.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              viewState.muted
                  ? Icons.music_off_rounded
                  : Icons.audio_file_rounded,
              color: viewState.muted
                  ? cs.onSurfaceVariant
                  : cs.primary,
              size: 16,
            ),
          ),
          title: Text(
            viewState.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: viewState.muted ? cs.onSurfaceVariant : cs.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          trailing: TextButtonTheme(
            data: TextButtonThemeData(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            child: TextButton.icon(
              onPressed: viewState.inheritedExcluded
                  ? null
                  : () {
                      libraryFacade.setLibraryTrackExcluded(
                        libraryPath,
                        trackPath,
                        !viewState.explicitExcluded,
                      );
                    },
              style: viewState.explicitExcluded
                  ? null
                  : TextButton.styleFrom(
                      foregroundColor: cs.error,
                    ),
              icon: Icon(
                viewState.explicitExcluded
                    ? Icons.restore_rounded
                    : Icons.block_rounded,
                size: 14,
              ),
              label: Text(
                viewState.explicitExcluded
                    ? i18n.tr('restore')
                    : i18n.tr('exclude'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
