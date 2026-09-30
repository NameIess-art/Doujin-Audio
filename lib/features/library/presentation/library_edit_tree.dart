import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/library_entry_editor_service.dart';
import '../application/library_facade.dart';
import '../domain/library_entry.dart';
import 'library_providers.dart';

import 'library_edit_tree_projection.dart';
import 'library_edit_tree_tiles.dart';

class LibraryEditTree extends ConsumerStatefulWidget {
  const LibraryEditTree({
    super.key,
    required this.libraryPath,
    required this.headerBuilder,
    this.entryEditorService,
  });

  final String libraryPath;
  final Widget Function(BuildContext, Widget) headerBuilder;
  final LibraryEntryEditorService? entryEditorService;

  @override
  ConsumerState<LibraryEditTree> createState() => _LibraryEditTreeState();
}

class _LibraryEditTreeState extends ConsumerState<LibraryEditTree>
    with WidgetsBindingObserver {
  late final LibraryEntryEditorService _entryEditorService;
  late final _projection = LibraryEditTreeProjection(widget.libraryPath);
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
  final Map<String, LibraryEditFolderTreeNode> _folderStructureSnapshots =
      <String, LibraryEditFolderTreeNode>{};
  int _folderStructureSnapshotRevision = 0;

  // Edit-tree caches: structural work is independent from query filtering.
  Object? _baseEditTreeCacheKey;
  List<LibraryEditTreeNode>? _cachedBaseEditTree;
  Object? _filteredEditTreeCacheKey;
  List<LibraryEditTreeNode>? _cachedEditTree;
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
                .map(_projection.folderPathForLibraryChild)
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
                .map(_projection.folderPathForLibraryChild)
                .where(_folderExistsInDiskSnapshot)
                .toList(growable: false);
      final folderStructureSnapshots = localSnapshotPending
          ? const <LibraryEditFolderTreeNode>[]
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
                        _projection.folderPathForLibraryChild(entry.path),
                  }.toList(growable: false)
            ..sort(compareNatural);
      _cachedBaseEditTree = _projection.buildEditTree(
        editTrackPaths,
        persistentFolderPaths,
        folderStructureSnapshots,
      );
    }
    final filteredCacheKey = Object.hash(baseCacheKey, _searchQuery);
    if (_filteredEditTreeCacheKey != filteredCacheKey) {
      _filteredEditTreeCacheKey = filteredCacheKey;
      _cachedEditTree = _projection.filterEditTree(
        _cachedBaseEditTree!,
        _searchQuery,
        _trackPathMatchesQuery,
      );
    }
    final editTree = _cachedEditTree!;
    final isEmpty = editTree.isEmpty;
    final snapshotError = _diskSnapshotError;

    final headerTopInset = MediaQuery.paddingOf(context).top + 98;
    return PageHeaderInset(
      topInset: headerTopInset,
      child: Stack(
        children: [
          AppPageContentTransition(
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + 98,
                16,
                24,
              ),
              itemCount: localSnapshotPending || isEmpty
                  ? 1
                  : snapshotError
                  ? editTree.length + 1
                  : editTree.length,
              itemBuilder: (context, index) {
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
                if (snapshotError && index == 0) {
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
                final node = editTree[index - (snapshotError ? 1 : 0)];
                return LibraryEditTreeNodeWidget(
                  key: ValueKey(node.pathValue),
                  libraryPath: widget.libraryPath,
                  node: node,
                  initiallyExpanded: _searchQuery.isNotEmpty,
                  onRememberFolder: rememberFolderStructureSnapshot,
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: widget.headerBuilder(context, _buildSearchBar(i18n)),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(AppLanguageProvider i18n) {
    final cs = Theme.of(context).colorScheme;
    final hasText = _searchController.text.isNotEmpty;
    return HeaderFloatingSurface(
      child: TextField(
        controller: _searchController,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13.5),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          filled: false,
          fillColor: Colors.transparent,
          prefixIcon: Icon(
            Icons.search_rounded,
            color: cs.onSurfaceVariant,
            size: 18,
          ),
          prefixIconConstraints: const BoxConstraints.tightFor(
            width: 36,
            height: 38,
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
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 38,
                  ),
                )
              : null,
          hintText: i18n.tr('search_audio_placeholder'),
          hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            fontSize: 13.5,
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.only(right: 12),
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
        final parent = _projection.parentFolderPath(current, rootPath);
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
        _projection.folderPathForLibraryChild(entry.path),
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

  bool _trackBelongsToLibrary(String trackPath) {
    return PathMatcher.isWithinOrEqual(trackPath, widget.libraryPath);
  }

  void rememberFolderStructureSnapshot(
    String folderPath,
    LibraryEditFolderTreeNode folder,
  ) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    setState(() {
      _folderStructureSnapshots[normalizedFolderPath] = _projection
          .cloneFolderNode(folder);
      _folderStructureSnapshotRevision++;
    });
  }
}
