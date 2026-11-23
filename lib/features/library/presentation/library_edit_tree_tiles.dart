import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/app_buttons.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/widgets/file_tree_expansion_motion.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../../../core/widgets/shimmer_loading.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
import 'library_providers.dart';

import 'library_edit_tree_projection.dart';

const double _libraryEditRowMinHeight = 64;

final _libraryEditTrackViewStateProvider = Provider.autoDispose
    .family<_LibraryEditTrackViewState, _LibraryEditTrackKey>((ref, key) {
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

class LibraryEditTreeList extends ConsumerStatefulWidget {
  const LibraryEditTreeList({
    super.key,
    required this.libraryPath,
    required this.nodes,
    required this.initiallyExpanded,
    required this.onRememberFolder,
    this.padding,
    this.leading,
    this.empty,
  });

  final String libraryPath;
  final List<LibraryEditTreeNode> nodes;
  final bool initiallyExpanded;
  final void Function(String, LibraryEditFolderTreeNode) onRememberFolder;
  final EdgeInsetsGeometry? padding;
  final Widget? leading;
  final Widget? empty;

  @override
  ConsumerState<LibraryEditTreeList> createState() =>
      _LibraryEditTreeListState();
}

typedef _LibraryEditTreeRow = ({LibraryEditTreeNode node, int depth});

class _LibraryEditTreeListState extends ConsumerState<LibraryEditTreeList>
    with SingleTickerProviderStateMixin {
  final _expandedPaths = <String>{};
  final _searchExpandedPaths = <String>{};
  final _searchCollapsedPaths = <String>{};
  final _rowIndices = <String, int>{};
  List<_LibraryEditTreeRow> _rows = [];
  late final FileTreeExpansionMotion<String, _LibraryEditTreeRow> _motion;
  List<LibraryEditTreeNode>? _countedNodes;
  int? _countedContentRevision;
  Map<String, int> _includedTrackCounts = const {};

  bool _isFolderExpanded(String pathValue) => widget.initiallyExpanded
      ? _searchExpandedPaths.contains(pathValue) &&
            !_searchCollapsedPaths.contains(pathValue)
      : _expandedPaths.contains(pathValue);

  @override
  void initState() {
    super.initState();
    _motion = FileTreeExpansionMotion(this, () {
      if (mounted) setState(_motion.finish);
    });
    _restoreExpansion();
    _updateNodes();
  }

  @override
  void didUpdateWidget(covariant LibraryEditTreeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryPath != widget.libraryPath) {
      _restoreExpansion();
      _searchExpandedPaths.clear();
      _searchCollapsedPaths.clear();
      _countedNodes = null;
    }
    if (oldWidget.libraryPath != widget.libraryPath ||
        !identical(oldWidget.nodes, widget.nodes) ||
        oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      if (widget.initiallyExpanded && !oldWidget.initiallyExpanded) {
        _searchCollapsedPaths.clear();
      }
      _updateNodes();
    }
  }

  String get _storageKey => 'library-edit-expanded:${widget.libraryPath}';

  void _restoreExpansion() {
    final stored =
        PageStorage.maybeOf(
              context,
            )?.readState(context, identifier: _storageKey)
            as Set<String>?;
    _expandedPaths
      ..clear()
      ..addAll(stored ?? const <String>{});
  }

  void _storeExpansion() {
    PageStorage.maybeOf(context)?.writeState(
      context,
      Set<String>.of(_expandedPaths),
      identifier: _storageKey,
    );
  }

  void _updateNodes() {
    _motion.finish();
    if (widget.initiallyExpanded) {
      _searchExpandedPaths.clear();
      void expand(Iterable<LibraryEditTreeNode> nodes) {
        for (final folder in nodes.whereType<LibraryEditFolderTreeNode>()) {
          _searchExpandedPaths.add(folder.pathValue);
          expand(folder.children);
        }
      }

      expand(widget.nodes);
      _searchCollapsedPaths.retainWhere(_searchExpandedPaths.contains);
    } else {
      _searchExpandedPaths.clear();
      _searchCollapsedPaths.clear();
    }
    _projectRows();
  }

  void _projectRows() {
    final rows = <_LibraryEditTreeRow>[];
    void visit(LibraryEditTreeNode node, int depth) {
      _rowIndices[node.pathValue] = rows.length;
      rows.add((node: node, depth: depth));
      if (node is LibraryEditFolderTreeNode &&
          _isFolderExpanded(node.pathValue)) {
        for (final child in node.children) {
          visit(child, node.depth + 1);
        }
      }
    }

    _rowIndices.clear();
    for (final node in widget.nodes) {
      visit(node, node is LibraryEditFolderTreeNode ? node.depth : 0);
    }
    _rows = rows;
  }

  void _toggleFolder(LibraryEditFolderTreeNode folder) {
    setState(() {
      final key = folder.pathValue;
      final progress = _motion.progressFor(key);
      _motion.finish();
      final bool expanding;
      if (widget.initiallyExpanded) {
        expanding = _searchCollapsedPaths.remove(key);
        if (!expanding) {
          _searchCollapsedPaths.add(key);
        } else {
          _searchExpandedPaths.add(key);
        }
      } else {
        expanding = !_expandedPaths.remove(key);
        if (expanding) _expandedPaths.add(key);
        _storeExpansion();
      }
      final outgoing = expanding ? null : _rows;
      _projectRows();
      if (!MediaQuery.disableAnimationsOf(context)) {
        _motion.start(key, outgoing: outgoing, from: progress);
      }
    });
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final contentRevision = ref.watch(
      libraryStateProvider.select(
        (value) =>
            value.value?.contentRevision ?? library.state.contentRevision,
      ),
    );
    // Folder expansion only changes visible rows. Count each track once per
    // projection or exclusion change, including the filtered search projection.
    if (!identical(_countedNodes, widget.nodes) ||
        _countedContentRevision != contentRevision) {
      final exclusions = library.libraryExclusionMatcherForLibrary(
        widget.libraryPath,
      );
      final checkEntry = PathMatcher.isContentUri(widget.libraryPath);
      _includedTrackCounts = LibraryEditTreeProjection(widget.libraryPath)
          .includedTrackCounts(
            widget.nodes,
            exclusions.hasExclusions
                ? (trackPath) => !exclusions.isEntryExcluded(
                    checkEntry
                        ? library.libraryEntryForPath(
                            widget.libraryPath,
                            trackPath,
                          )
                        : null,
                    trackPath,
                  )
                : (_) => true,
          );
      _countedNodes = widget.nodes;
      _countedContentRevision = contentRevision;
    }
    final rows = _motion.project(
      context,
      _rows,
      parentIndex: (rows, key) {
        final index = rows.indexWhere((row) => row.node.pathValue == key);
        return index < 0 ? null : index;
      },
      depth: (row) => row.depth,
      minRowHeight: 48,
    );
    final indices = identical(rows, _rows)
        ? _rowIndices
        : {for (var i = 0; i < rows.length; i++) rows[i].node.pathValue: i};
    final offset = widget.leading == null ? 0 : 1;
    return ListView.builder(
      padding: widget.padding,
      itemCount: offset + (rows.isEmpty ? 1 : rows.length),
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        final index = indices[key.value];
        return index == null ? null : index + offset;
      },
      itemBuilder: (context, index) {
        if (index < offset) return widget.leading!;
        if (rows.isEmpty) return widget.empty ?? const SizedBox.shrink();
        final rowIndex = index - offset;
        final row = rows[rowIndex];
        final node = row.node;
        return _motion.wrap(
          rowIndex,
          node is LibraryEditFolderTreeNode
              ? _LibraryEditFolderTreeTile(
                  libraryPath: widget.libraryPath,
                  folder: node,
                  includedCount: _includedTrackCounts[node.folderPath]!,
                  expanded: _isFolderExpanded(node.pathValue),
                  onToggle: () => _toggleFolder(node),
                  onRememberFolder: widget.onRememberFolder,
                )
              : _LibraryEditTrackTile(
                  libraryPath: widget.libraryPath,
                  trackPath: node.pathValue,
                  depth: row.depth,
                ),
          key: ValueKey(node.pathValue),
        );
      },
    ).withWindowsSmoothScroll();
  }
}

class _LibraryEditFolderTreeTile extends ConsumerWidget {
  const _LibraryEditFolderTreeTile({
    required this.libraryPath,
    required this.folder,
    required this.includedCount,
    required this.expanded,
    required this.onToggle,
    required this.onRememberFolder,
  });

  final String libraryPath;
  final LibraryEditFolderTreeNode folder;
  final int includedCount;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(String, LibraryEditFolderTreeNode) onRememberFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    ref.watch(
      libraryStateProvider.select((value) => value.value?.contentRevision ?? 0),
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final libraryService = ref.read(libraryFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final folderPath = folder.folderPath;
    final isRoot = folder.depth == 0;
    final explicitExcluded = libraryService.isLibraryFolderExplicitlyExcluded(
      libraryPath,
      folderPath,
    );
    final inheritedExcluded = libraryService.isLibraryPathInheritedExcluded(
      libraryPath,
      folderPath,
    );
    final muted = libraryService.isLibraryPathExcluded(libraryPath, folderPath);
    return Semantics(
      expanded: expanded,
      child: FileTreeRow(
        title: folder.name,
        subtitle: i18n.tr('audio_count', {'count': includedCount}),
        depth: folder.depth,
        minHeight: isRoot ? _libraryEditRowMinHeight : 48,
        titleMaxLines: isRoot ? 2 : 1,
        reserveSubtitleSpace: true,
        verticalPadding: isRoot ? 4 : 2,
        isFolder: true,
        titleColor: muted
            ? cs.onSurfaceVariant
            : (expanded ? cs.primary : cs.onSurface),
        surfaceKey: ValueKey('library-edit-folder-surface:$folderPath'),
        onTap: onToggle,
        leading: Icon(
          muted
              ? Icons.folder_off_rounded
              : (expanded
                    ? AppDesignTokens.openFolderIcon
                    : AppDesignTokens.folderIcon),
          size: AppDesignTokens.fileEntryIconSize,
          color: muted
              ? cs.onSurfaceVariant
              : AppDesignTokens.of(context).folderColor,
        ),
        trailingSpacing: AppSpacing.xxs,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: _LibraryEditExclusionButton(
                excluded: explicitExcluded,
                inheritedExcluded: inheritedExcluded,
                onPressed: inheritedExcluded
                    ? null
                    : () {
                        if (folder.children.isNotEmpty) {
                          onRememberFolder(folderPath, folder);
                        }
                        libraryService.setLibraryFolderExcluded(
                          libraryPath,
                          folderPath,
                          !explicitExcluded,
                        );
                      },
              ),
            ),
            const SizedBox(width: 2),
            FileTreeExpansionArrow(
              expanded: expanded,
              color: muted
                  ? cs.onSurfaceVariant
                  : (expanded ? cs.primary : cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryEditTrackTile extends ConsumerWidget {
  const _LibraryEditTrackTile({
    required this.libraryPath,
    required this.trackPath,
    required this.depth,
  });

  final int depth;
  final String libraryPath;
  final String trackPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(
      _libraryEditTrackViewStateProvider(
        _LibraryEditTrackKey(libraryPath, trackPath),
      ),
    );
    final libraryFacade = ref.read(libraryFacadeProvider);
    final cs = Theme.of(context).colorScheme;

    return FileTreeRow(
      title: viewState.title,
      depth: depth,
      minHeight: 48,
      titleMaxLines: 2,
      verticalPadding: 2,
      titleColor: viewState.muted ? cs.onSurfaceVariant : cs.onSurface,
      surfaceKey: ValueKey('library-edit-track-surface:$trackPath'),
      leading: Icon(
        viewState.muted
            ? Icons.music_off_rounded
            : AppDesignTokens.audioFileIcon,
        color: viewState.muted ? cs.onSurfaceVariant : cs.primary,
        size: AppDesignTokens.fileEntryIconSize,
      ),
      trailingSpacing: AppSpacing.xxs,
      trailing: _LibraryEditExclusionButton(
        excluded: viewState.explicitExcluded,
        inheritedExcluded: viewState.inheritedExcluded,
        onPressed: viewState.inheritedExcluded
            ? null
            : () => libraryFacade.setLibraryTrackExcluded(
                libraryPath,
                trackPath,
                !viewState.explicitExcluded,
              ),
      ),
    );
  }
}

class _LibraryEditExclusionButton extends ConsumerWidget {
  const _LibraryEditExclusionButton({
    required this.excluded,
    required this.onPressed,
    this.inheritedExcluded = false,
  });

  final bool excluded;
  final VoidCallback? onPressed;
  final bool inheritedExcluded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return IconButton(
      tooltip: i18n.tr(
        inheritedExcluded
            ? 'excluded_by_parent'
            : (excluded ? 'restore' : 'exclude'),
      ),
      onPressed: onPressed,
      style: appIconButtonStyle(
        IconButton.styleFrom(
          foregroundColor: excluded
              ? null
              : Theme.of(context).colorScheme.error,
          minimumSize: const Size.square(44),
          maximumSize: const Size.square(44),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      icon: Icon(
        excluded ? Icons.restore_rounded : Icons.block_rounded,
        size: 22,
      ),
    );
  }
}

class LibraryEditTreeSkeleton extends StatelessWidget {
  const LibraryEditTreeSkeleton({super.key, required this.viewportHeight});

  final double viewportHeight;

  static const List<double> _titleFractions = [
    0.48,
    0.62,
    0.40,
    0.55,
    0.36,
    0.50,
  ];

  @override
  Widget build(BuildContext context) {
    final rowHeight = FileTreeRow.layoutHeight(
      context,
      minHeight: _libraryEditRowMinHeight,
      titleMaxLines: 2,
      reserveSubtitleSpace: true,
    );
    final itemCount = (viewportHeight / rowHeight).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < itemCount; i++)
          SizedBox(
            height: rowHeight,
            child: ShimmerLoader(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  children: [
                    const ShimmerContainer(
                      width: AppDesignTokens.fileEntryIconSize,
                      height: AppDesignTokens.fileEntryIconSize,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FractionallySizedBox(
                            widthFactor:
                                _titleFractions[i % _titleFractions.length],
                            child: const ShimmerContainer(
                              height: 14,
                              borderRadius: 7,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const ShimmerContainer(
                            height: 11,
                            width: 60,
                            borderRadius: 5.5,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xxs),
                    const SizedBox(
                      width: 44,
                      child: Center(
                        child: ShimmerContainer(
                          width: 22,
                          height: 22,
                          borderRadius: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const ShimmerContainer(
                      width: 18,
                      height: 18,
                      borderRadius: 9,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
