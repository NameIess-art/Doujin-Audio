import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/path_display.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../../../core/widgets/shimmer_loading.dart';
import '../application/library_facade.dart';
import 'library_providers.dart';

import 'library_edit_tree_projection.dart';

const Size _libraryEditActionMinimumSize = Size(0, 36);
const double _libraryEditRowMinHeight = 64;

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

int _includedEditTrackCount(
  LibraryEditFolderTreeNode folder,
  LibraryFacade libraryService,
  String libraryPath,
) {
  var count = 0;
  for (final child in folder.children) {
    if (child is LibraryEditTrackTreeNode) {
      if (!libraryService.isLibraryPathExcluded(libraryPath, child.trackPath)) {
        count++;
      }
    } else if (child is LibraryEditFolderTreeNode) {
      count += _includedEditTrackCount(child, libraryService, libraryPath);
    }
  }
  return count;
}

class LibraryEditTreeList extends StatefulWidget {
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
  State<LibraryEditTreeList> createState() => _LibraryEditTreeListState();
}

class _LibraryEditTreeListState extends State<LibraryEditTreeList>
    with SingleTickerProviderStateMixin {
  final _expandedPaths = <String>{};
  final _rowIndices = <String, int>{};
  List<({LibraryEditTreeNode node, int depth})> _rows = [];
  late final AnimationController _animationController;
  late final Animation<double> _opacity;
  late final Animation<double> _sizeFactor;
  String? _animatingPath;
  int _animationStart = 0;
  int _animationCount = 0;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: kAppMotionStandard,
      value: 1,
    )..addStatusListener(_onAnimationStatus);
    _opacity = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOutCubic,
    );
    // Nonzero incoming heights let the sliver stop at its cache extent.
    _sizeFactor = Tween<double>(begin: 0.2, end: 1).animate(_opacity);
    _restoreExpansion();
    _updateNodes();
  }

  @override
  void didUpdateWidget(covariant LibraryEditTreeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryPath != widget.libraryPath) _restoreExpansion();
    if (oldWidget.libraryPath != widget.libraryPath ||
        !identical(oldWidget.nodes, widget.nodes) ||
        oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _updateNodes();
    }
  }

  String get _storageKey => 'library-edit-expanded:${widget.libraryPath}';

  void _restoreExpansion() {
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: _storageKey,
    ) as Set<String>?;
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
    _animationController.stop();
    _animatingPath = null;
    if (widget.initiallyExpanded) {
      void expand(Iterable<LibraryEditTreeNode> nodes) {
        for (final folder in nodes.whereType<LibraryEditFolderTreeNode>()) {
          _expandedPaths.add(folder.pathValue);
          expand(folder.children);
        }
      }

      expand(widget.nodes);
      _storeExpansion();
    }
    _projectRows();
  }

  void _projectRows() {
    final rows = <({LibraryEditTreeNode node, int depth})>[];
    void visit(LibraryEditTreeNode node, int depth) {
      _rowIndices[node.pathValue] = rows.length;
      rows.add((node: node, depth: depth));
      if (node is LibraryEditFolderTreeNode &&
          _expandedPaths.contains(node.pathValue)) {
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

  void _finishAnimation() {
    _animationController.stop();
    _animatingPath = null;
    _projectRows();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (_animatingPath != null &&
        (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed)) {
      setState(_finishAnimation);
    }
  }

  void _toggleFolder(LibraryEditFolderTreeNode folder) {
    setState(() {
      final key = folder.pathValue;
      if (_animatingPath != null && _animatingPath != key) {
        _finishAnimation();
      }
      final expanding = !_expandedPaths.remove(key);
      if (expanding) _expandedPaths.add(key);
      _storeExpansion();
      if (MediaQuery.disableAnimationsOf(context)) {
        _finishAnimation();
        return;
      }
      if (_animatingPath != key) {
        _animationStart = _rowIndices[key]! + 1;
        final previousCount = _rows.length;
        if (expanding) {
          _projectRows();
          _animationCount = _rows.length - previousCount;
        } else {
          var end = _animationStart;
          while (end < _rows.length && _rows[end].depth > folder.depth) {
            end++;
          }
          _animationCount = end - _animationStart;
        }
        if (_animationCount == 0) return;
        _animationController.value = expanding ? 0 : 1;
        _animatingPath = key;
      }
      if (expanding) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offset = widget.leading == null ? 0 : 1;
    return ListView.builder(
      padding: widget.padding,
      itemCount: _rows.isEmpty ? 1 : offset + _rows.length,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        final index = _rowIndices[key.value];
        return index == null ? null : index + offset;
      },
      itemBuilder: (context, index) {
        if (index < offset) return widget.leading!;
        if (_rows.isEmpty) return widget.empty ?? const SizedBox.shrink();
        final rowIndex = index - offset;
        final row = _rows[rowIndex];
        final node = row.node;
        final animating =
            _animatingPath != null &&
            rowIndex >= _animationStart &&
            rowIndex < _animationStart + _animationCount;
        final collapsing =
            animating && !_expandedPaths.contains(_animatingPath);
        return SizeTransition(
          key: ValueKey(node.pathValue),
          sizeFactor: animating ? _sizeFactor : const AlwaysStoppedAnimation(1),
          axisAlignment: -1,
          child: FadeTransition(
            opacity: animating ? _opacity : const AlwaysStoppedAnimation(1),
            child: IgnorePointer(
              ignoring: collapsing,
              child: ExcludeSemantics(
                excluding: collapsing,
                child: node is LibraryEditFolderTreeNode
                    ? _LibraryEditFolderTreeTile(
                        libraryPath: widget.libraryPath,
                        folder: node,
                        expanded: _expandedPaths.contains(node.pathValue),
                        onToggle: () => _toggleFolder(node),
                        onRememberFolder: widget.onRememberFolder,
                      )
                    : _LibraryEditTrackTile(
                        libraryPath: widget.libraryPath,
                        trackPath: node.pathValue,
                        depth: row.depth,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LibraryEditFolderTreeTile extends ConsumerWidget {
  const _LibraryEditFolderTreeTile({
    required this.libraryPath,
    required this.folder,
    required this.expanded,
    required this.onToggle,
    required this.onRememberFolder,
  });

  final String libraryPath;
  final LibraryEditFolderTreeNode folder;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(String, LibraryEditFolderTreeNode) onRememberFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final includedCount = _includedEditTrackCount(
      folder,
      libraryService,
      libraryPath,
    );
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
          color: muted ? cs.onSurfaceVariant : AppDesignTokens.folderIconColor,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: TextButtonTheme(
                data: TextButtonThemeData(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    minimumSize: _libraryEditActionMinimumSize,
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                ),
                child: TextButton.icon(
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
                  style: explicitExcluded
                      ? null
                      : TextButton.styleFrom(foregroundColor: cs.error),
                  icon: Icon(
                    explicitExcluded
                        ? Icons.restore_rounded
                        : Icons.block_rounded,
                    size: 16,
                  ),
                  label: Text(
                    explicitExcluded ? i18n.tr('restore') : i18n.tr('exclude'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
      trailing: TextButtonTheme(
        data: TextButtonThemeData(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            minimumSize: _libraryEditActionMinimumSize,
            tapTargetSize: MaterialTapTargetSize.padded,
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
              : TextButton.styleFrom(foregroundColor: cs.error),
          icon: Icon(
            viewState.explicitExcluded
                ? Icons.restore_rounded
                : Icons.block_rounded,
            size: 16,
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
                    const SizedBox(width: 12),
                    const ShimmerContainer(
                      width: 60,
                      height: 32,
                      borderRadius: 8,
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
