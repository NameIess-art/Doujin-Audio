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
  Timer? _searchDebounceTimer;
  String _searchQuery = '';

  // Edit-tree cache (memoized per build inputs).
  Object? _editTreeCacheKey;
  List<_LibraryEditTreeNode>? _cachedEditTree;

  @override
  void initState() {
    super.initState();
    _loadDiskLibrarySnapshot();
  }

  Future<void> _loadDiskLibrarySnapshot() async {
    final directory = Directory(widget.libraryPath);
    if (!await directory.exists()) return;
    final audioFiles = <String>{};
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
          final normalizedPath = path.normalize(entity.path);
          if (entity is Directory) {
            pendingDirs.add(entity);
            continue;
          }
          if (entity is File && _isSupportedLibraryAudioFile(normalizedPath)) {
            audioFiles.add(normalizedPath);
          }
        }
      }
    } catch (_) {}

    final sortedAudioFiles = audioFiles.toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (!mounted) return;
    setState(() {
      _diskAudioFilePaths = sortedAudioFiles;
    });
  }

  bool _isSupportedLibraryAudioFile(String filePath) {
    final lowerPath = filePath.toLowerCase();
    if (lowerPath.endsWith('.flac') ||
        lowerPath.endsWith('.wav') ||
        lowerPath.endsWith('.mp3') ||
        lowerPath.endsWith('.m4a') ||
        lowerPath.endsWith('.aac') ||
        lowerPath.endsWith('.ogg') ||
        lowerPath.endsWith('.opus')) {
      return true;
    }
    final mimeType = lookupMimeType(filePath);
    if (mimeType == null) return false;
    return mimeType.startsWith('audio/') || mimeType == 'application/ogg';
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
        'name': path.basename(widget.libraryPath),
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
    final excludedTracks = libraryService.excludedTracksForLibrary(
      widget.libraryPath,
    );
    final cacheKey = Object.hash(
      libraryService.library,
      _diskAudioFilePaths,
      excludedTracks,
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
          ),
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
                path.basename(widget.libraryPath),
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

  List<String> _collectLibraryEditTrackPaths(
    LibraryService libraryService,
    List<String> diskAudioFilePaths,
    List<String> excludedTracks,
  ) {
    final tracks = <String>{
      for (final track in libraryService.library)
        if (_trackBelongsToLibrary(track.path)) path.normalize(track.path),
      for (final trackPath in diskAudioFilePaths)
        if (_trackBelongsToLibrary(trackPath)) path.normalize(trackPath),
      for (final trackPath in excludedTracks)
        if (_trackBelongsToLibrary(trackPath)) path.normalize(trackPath),
    }.toList(growable: false);

    tracks.sort(
      (a, b) => path
          .basenameWithoutExtension(a)
          .toLowerCase()
          .compareTo(path.basenameWithoutExtension(b).toLowerCase()),
    );
    return tracks;
  }

  List<_LibraryEditTreeNode> _buildEditTree(List<String> trackPaths) {
    final rootPath = path.normalize(widget.libraryPath);
    final folderByPath = <String, _LibraryEditFolderTreeNode>{};
    final roots = <_LibraryEditTreeNode>[];

    _LibraryEditFolderTreeNode? ensureFolder(String folderPath) {
      final normalizedFolderPath = path.normalize(folderPath);
      if (path.equals(normalizedFolderPath, rootPath) ||
          !path.isWithin(rootPath, normalizedFolderPath)) {
        return null;
      }

      final existing = folderByPath[normalizedFolderPath];
      if (existing != null) return existing;

      final parent = ensureFolder(path.dirname(normalizedFolderPath));
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

    for (final trackPath in trackPaths) {
      final normalizedTrackPath = path.normalize(trackPath);
      if (!_trackBelongsToLibrary(normalizedTrackPath)) continue;
      final trackNode = _LibraryEditTrackTreeNode(normalizedTrackPath);
      final folder = ensureFolder(path.dirname(normalizedTrackPath));
      if (folder == null) {
        roots.add(trackNode);
      } else {
        folder.children.add(trackNode);
      }
    }

    _sortEditTree(roots);
    return roots;
  }

  int _relativeFolderDepth(String folderPath) {
    final relative = path.relative(
      path.normalize(folderPath),
      from: path.normalize(widget.libraryPath),
    );
    if (relative == '.' || relative.isEmpty) return 0;
    return relative
            .split(RegExp(r'[\\/]+'))
            .where((segment) => segment.isNotEmpty)
            .length -
        1;
  }

  void _sortEditTree(List<_LibraryEditTreeNode> nodes) {
    nodes.sort((a, b) {
      if (a is _LibraryEditFolderTreeNode && b is _LibraryEditTrackTreeNode) {
        return -1;
      }
      if (a is _LibraryEditTrackTreeNode && b is _LibraryEditFolderTreeNode) {
        return 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
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
    final normalizedLibraryPath = path.normalize(widget.libraryPath);
    final normalizedTrackPath = path.normalize(trackPath);
    return path.equals(normalizedTrackPath, normalizedLibraryPath) ||
        path.isWithin(normalizedLibraryPath, normalizedTrackPath);
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
  String get name => path.basename(folderPath);

  @override
  String get pathValue => folderPath;
}

class _LibraryEditTrackTreeNode extends _LibraryEditTreeNode {
  _LibraryEditTrackTreeNode(this.trackPath);

  final String trackPath;

  @override
  String get name => path.basenameWithoutExtension(trackPath);

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
                  onPressed: () {
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
    final title =
        track?.displayName ?? path.basenameWithoutExtension(trackPath);
    final isMuted =
        muted ?? libraryService.isLibraryPathExcluded(libraryPath, trackPath);

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
        onPressed: () {
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
