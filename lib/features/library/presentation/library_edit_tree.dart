import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/search_highlight.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/library_entry_editor_service.dart';
import 'library_providers.dart';

import 'library_edit_tree_projection.dart';
import 'library_edit_tree_tiles.dart';

class LibraryEditTree extends ConsumerStatefulWidget {
  const LibraryEditTree({
    super.key,
    required this.libraryPath,
    required this.headerBuilder,
    this.entryEditorService,
    this.projectTree,
  });

  final String libraryPath;
  final Widget Function(BuildContext, Widget) headerBuilder;
  final LibraryEntryEditorService? entryEditorService;
  @visibleForTesting
  final Future<LibraryEditTreeSnapshot> Function(LibraryEditTreeRequest)?
  projectTree;

  @override
  ConsumerState<LibraryEditTree> createState() => _LibraryEditTreeState();
}

class _LibraryEditTreeState extends ConsumerState<LibraryEditTree>
    with WidgetsBindingObserver {
  late final LibraryEntryEditorService _entryEditorService;
  final TextEditingController _searchController = TextEditingController();
  List<String> _diskAudioFilePaths = const <String>[];
  Set<String> _diskAudioFilePathSet = const <String>{};
  Map<String, String> _diskTrackParentPaths = const <String, String>{};
  Set<String> _diskLiveFolderPaths = const <String>{};
  bool _diskSnapshotLoaded = false;
  bool _initialLoadPending = true;
  bool _diskSnapshotError = false;
  int _diskSnapshotGeneration = 0;
  int _diskSnapshotRevision = 0;
  bool _diskRefreshNeeded = true;
  ModalRoute<dynamic>? _route;
  late final _diskLoadKey = 'library_edit_load_${identityHashCode(this)}';
  late final _diskResultKey = 'library_edit_result_${identityHashCode(this)}';
  Timer? _searchDebounceTimer;
  String _searchQuery = '';
  final Map<String, LibraryEditFolderTreeNode> _folderStructureSnapshots =
      <String, LibraryEditFolderTreeNode>{};
  int _folderStructureSnapshotRevision = 0;

  (Object, String)? _requestedTreeKey;
  Object? _projectedBaseKey;
  LibraryEditTreeSnapshot? _treeSnapshot;
  List<LibraryEditTreeNode> _editTree = const [];
  bool _treeUpdateRunning = false;
  bool _treeUpdateScheduled = false;
  bool _treeReady = false;
  bool _treeProjectionError = false;

  @override
  void initState() {
    super.initState();
    _entryEditorService =
        widget.entryEditorService ?? LibraryEntryEditorService();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant LibraryEditTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryPath == widget.libraryPath) return;
    _diskSnapshotGeneration++;
    _diskAudioFilePaths = const [];
    _diskAudioFilePathSet = const {};
    _diskTrackParentPaths = const {};
    _diskLiveFolderPaths = const {};
    _folderStructureSnapshots.clear();
    _diskSnapshotLoaded = false;
    _initialLoadPending = true;
    _diskSnapshotError = false;
    _treeProjectionError = false;
    _treeReady = false;
    _editTree = const [];
    _requestedTreeKey = null;
    _projectedBaseKey = null;
    _treeSnapshot = null;
    _diskRefreshNeeded = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _requestDiskSnapshotRefresh();
    }
  }

  void _requestDiskSnapshotRefresh() {
    _diskRefreshNeeded = true;
    void load() {
      if (!mounted || _route?.isCurrent == false) return;
      _diskRefreshNeeded = false;
      unawaited(_loadDiskLibrarySnapshot());
    }

    final coordinator = UiInteractionCoordinator.instance;
    if (coordinator.isInteracting) {
      coordinator.scheduleCommit(key: _diskLoadKey, commit: load);
    } else {
      load();
    }
  }

  void _commitDiskSnapshot(int generation, VoidCallback commit) {
    if (!mounted || generation != _diskSnapshotGeneration) return;
    void apply() {
      if (mounted && generation == _diskSnapshotGeneration) commit();
    }

    final coordinator = UiInteractionCoordinator.instance;
    if (coordinator.isInteracting) {
      coordinator.scheduleCommit(key: _diskResultKey, commit: apply);
    } else {
      apply();
    }
  }

  Future<void> _loadDiskLibrarySnapshot() async {
    final requestGeneration = ++_diskSnapshotGeneration;
    late final LibraryEntryDiskSnapshot snapshot;
    try {
      snapshot = await _entryEditorService.loadDiskSnapshot(widget.libraryPath);
    } catch (_) {
      if (!mounted || requestGeneration != _diskSnapshotGeneration) return;
      _commitDiskSnapshot(
        requestGeneration,
        () => _showDiskSnapshotFailure(requestGeneration),
      );
      return;
    }
    if (!mounted || requestGeneration != _diskSnapshotGeneration) return;
    if (!snapshot.authoritative) {
      _commitDiskSnapshot(
        requestGeneration,
        () => _showDiskSnapshotFailure(requestGeneration),
      );
      return;
    }

    _commitDiskSnapshot(requestGeneration, () => _applyDiskSnapshot(snapshot));
  }

  void _applyDiskSnapshot(LibraryEntryDiskSnapshot snapshot) {
    final audioFilePaths = snapshot.audioFilePathSet;
    final library = ref.read(libraryFacadeProvider);
    final liveFolderPaths = library.reconcileLibraryDiskSnapshot(
      widget.libraryPath,
      snapshot,
    );
    setState(() {
      // A complete disk scan supersedes exclusion-time copies of the tree.
      // Reusing those copies would bring deleted descendants back.
      _folderStructureSnapshots.clear();
      _folderStructureSnapshotRevision++;
      _diskAudioFilePaths = snapshot.audioFilePaths;
      _diskAudioFilePathSet = audioFilePaths;
      _diskTrackParentPaths = snapshot.trackParentPaths;
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
      onAction: _requestDiskSnapshotRefresh,
    );
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_diskLoadKey);
    UiInteractionCoordinator.instance.cancelCommit(_diskResultKey);
    WidgetsBinding.instance.removeObserver(this);
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    ref.listen(
      libraryStateProvider.select((state) => state.value?.isScanning ?? false),
      (wasScanning, isScanning) async {
        if (wasScanning != true || isScanning) return;
        await ref.read(libraryFacadeProvider).scanIdle;
        if (mounted) _requestDiskSnapshotRefresh();
      },
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    ref.watch(
      libraryStateProvider.select(
        (state) => state.value?.structureRevision ?? 0,
      ),
    );
    _scheduleTreeUpdate(_treeBaseKey);
    final localSnapshotPending = _initialLoadPending || !_treeReady;
    final editTree = _editTree;
    final snapshotError = _diskSnapshotError || _treeProjectionError;

    final headerTopInset = AppPageHeaderMetrics.contentTopInset(
      context,
      additionalHeight: 6 + AppPageHeaderMetrics.buttonSize,
    );
    final content = SearchHighlightScope(
      query: _searchQuery,
      child: PageHeaderInset(
        topInset: headerTopInset,
        child: Stack(
          children: [
            AppPageContentTransition(
              child: PlaceholderContentTransition(
                showPlaceholder: localSnapshotPending,
                placeholder: LayoutBuilder(
                  builder: (context, constraints) => ListView(
                    // Both lists mount during the fade; content owns primary.
                    primary: false,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(16, headerTopInset, 16, 24),
                    children: [
                      LibraryEditTreeSkeleton(
                        key: const ValueKey('library_edit_entries_skeleton'),
                        viewportHeight:
                            (constraints.maxHeight - headerTopInset - 24).clamp(
                              0.0,
                              double.infinity,
                            ),
                      ),
                    ],
                  ),
                ),
                content: LibraryEditTreeList(
                  libraryPath: widget.libraryPath,
                  nodes: editTree,
                  initiallyExpanded: _searchQuery.isNotEmpty,
                  onRememberFolder: rememberFolderStructureSnapshot,
                  padding: EdgeInsets.fromLTRB(16, headerTopInset, 16, 24),
                  leading: snapshotError
                      ? Padding(
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
                                  onPressed: _requestDiskSnapshotRefresh,
                                  child: Text(i18n.tr('retry')),
                                ),
                              ],
                            ),
                          ),
                        )
                      : null,
                  empty: Padding(
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
                  ),
                ),
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
      ),
    );
    // Covering a route must not rebuild an unchanged editor tree.
    return Builder(
      builder: (context) {
        _route = ModalRoute.of(context);
        if (_diskRefreshNeeded && _route?.isCurrent != false) {
          _requestDiskSnapshotRefresh();
        }
        return content;
      },
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

  void _scheduleTreeUpdate(Object baseKey) {
    if (_initialLoadPending) return;
    final key = (baseKey, _searchQuery);
    if (_requestedTreeKey == key) return;
    _requestedTreeKey = key;
    if (_treeUpdateRunning || _treeUpdateScheduled) return;
    _treeUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _treeUpdateScheduled = false;
      if (mounted) unawaited(_updateTree());
    });
  }

  Object get _treeBaseKey => (
    widget.libraryPath,
    ref.read(libraryFacadeProvider).structureRevision,
    _diskSnapshotRevision,
    _folderStructureSnapshotRevision,
    _initialLoadPending,
    _diskSnapshotError,
  );

  void _refreshTreeRequest() {
    // State may change after a worker finishes but before the next build.
    _requestedTreeKey = _initialLoadPending
        ? null
        : (_treeBaseKey, _searchQuery);
  }

  Future<void> _updateTree() async {
    _treeUpdateRunning = true;
    try {
      // Keep at most one worker alive. Changes during its run are coalesced
      // into the latest revision and an old result never replaces new input.
      while (mounted && _requestedTreeKey != null) {
        final key = _requestedTreeKey!;
        final (baseKey, query) = key;
        try {
          if (_projectedBaseKey != baseKey) {
            final library = ref.read(libraryFacadeProvider);
            final request = LibraryEditTreeRequest(
              libraryPath: widget.libraryPath,
              tracks: library.library,
              diskTrackPaths: _diskAudioFilePaths,
              diskTrackPathSet: _diskAudioFilePathSet,
              diskTrackParents: _diskTrackParentPaths,
              liveFolders: _diskLiveFolderPaths,
              authoritative: _diskSnapshotLoaded,
              excludedTracks: library.excludedTracksForLibrary(
                widget.libraryPath,
              ),
              excludedFolders: library.excludedFoldersForLibrary(
                widget.libraryPath,
              ),
              entries: library.libraryEntriesForLibrary(widget.libraryPath),
              childFolders: library.watchedFolders,
              restoringFolders: _folderStructureSnapshots.values.toList(
                growable: false,
              ),
            );
            final snapshot =
                await (widget.projectTree?.call(request) ?? request.project());
            if (!mounted) return;
            _refreshTreeRequest();
            if (_requestedTreeKey == null) return;
            if (_requestedTreeKey!.$1 != baseKey) continue;
            _treeSnapshot = snapshot;
            _projectedBaseKey = baseKey;
          }
          if (_requestedTreeKey != key) continue;
          final nodes = await _treeSnapshot!.filter(query);
          if (!mounted) return;
          _refreshTreeRequest();
          if (_requestedTreeKey != key) continue;
          setState(() {
            _editTree = nodes;
            _treeReady = true;
            _treeProjectionError = false;
          });
          break;
        } catch (error, stack) {
          if (!mounted) return;
          _refreshTreeRequest();
          if (_requestedTreeKey != key) continue;
          AppLogService.warning(
            'library_edit_tree_projection_failed',
            error: error,
            stackTrace: stack,
          );
          setState(() {
            _treeProjectionError = true;
            _treeReady = true;
          });
          break;
        }
      }
    } finally {
      _treeUpdateRunning = false;
    }
  }

  void rememberFolderStructureSnapshot(
    String folderPath,
    LibraryEditFolderTreeNode folder,
  ) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    setState(() {
      _folderStructureSnapshots[normalizedFolderPath] = folder;
      _folderStructureSnapshotRevision++;
    });
  }
}
