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

class LibraryEditTreeNodeWidget extends ConsumerWidget {
  const LibraryEditTreeNodeWidget({
    super.key,
    required this.libraryPath,
    required this.node,
    required this.initiallyExpanded,
    required this.onRememberFolder,
    this.depth = 0,
  });

  final int depth;
  final String libraryPath;
  final LibraryEditTreeNode node;
  final bool initiallyExpanded;
  final void Function(String, LibraryEditFolderTreeNode) onRememberFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      libraryStateProvider.select(
        (value) => value.value?.structureRevision ?? 0,
      ),
    );
    if (node is LibraryEditFolderTreeNode) {
      return _LibraryEditFolderTreeTile(
        libraryPath: libraryPath,
        folder: node as LibraryEditFolderTreeNode,
        initiallyExpanded: initiallyExpanded,
        onRememberFolder: onRememberFolder,
      );
    }
    if (node is LibraryEditTrackTreeNode) {
      final track = node as LibraryEditTrackTreeNode;
      return _LibraryEditTrackTile(
        libraryPath: libraryPath,
        trackPath: track.trackPath,
        depth: depth,
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
    required this.onRememberFolder,
  });

  final String libraryPath;
  final LibraryEditFolderTreeNode folder;
  final bool initiallyExpanded;
  final void Function(String, LibraryEditFolderTreeNode) onRememberFolder;

  @override
  ConsumerState<_LibraryEditFolderTreeTile> createState() =>
      _LibraryEditFolderTreeTileState();
}

class _LibraryEditFolderTreeTileState
    extends ConsumerState<_LibraryEditFolderTreeTile> {
  final ExpansibleController _expansionController = ExpansibleController();
  @override
  void initState() {
    super.initState();
    if (widget.initiallyExpanded) _expansionController.expand();
  }

  @override
  void didUpdateWidget(covariant _LibraryEditFolderTreeTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initiallyExpanded && !_expansionController.isExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expansionController.expand();
      });
    }
  }

  @override
  void dispose() {
    _expansionController.dispose();
    super.dispose();
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final folderPath = widget.folder.folderPath;
    final isRoot = widget.folder.depth == 0;
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
    final includedCount = _includedEditTrackCount(
      widget.folder,
      libraryService,
      widget.libraryPath,
    );
    return Expansible(
      key: PageStorageKey<String>(
        'library-edit-folder:${widget.libraryPath}:$folderPath',
      ),
      controller: _expansionController,
      animationStyle: appExpansionAnimationStyle(context),
      maintainState: false,
      headerBuilder: (context, animation) {
        final expanded = _expansionController.isExpanded;
        return Semantics(
          expanded: expanded,
          child: FileTreeRow(
            title: widget.folder.name,
            subtitle: i18n.tr('audio_count', {'count': includedCount}),
            depth: widget.folder.depth,
            minHeight: isRoot ? _libraryEditRowMinHeight : 48,
            titleMaxLines: isRoot ? 2 : 1,
            reserveSubtitleSpace: true,
            verticalPadding: isRoot ? 4 : 2,
            isFolder: true,
            titleColor: muted
                ? cs.onSurfaceVariant
                : (expanded ? cs.primary : cs.onSurface),
            surfaceKey: ValueKey('library-edit-folder-surface:$folderPath'),
            onTap: expanded
                ? _expansionController.collapse
                : _expansionController.expand,
            leading: Icon(
              muted
                  ? Icons.folder_off_rounded
                  : (expanded
                        ? AppDesignTokens.openFolderIcon
                        : AppDesignTokens.folderIcon),
              size: AppDesignTokens.fileEntryIconSize,
              color: muted
                  ? cs.onSurfaceVariant
                  : AppDesignTokens.folderIconColor,
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
                              if (widget.folder.children.isNotEmpty) {
                                widget.onRememberFolder(
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
                          : TextButton.styleFrom(foregroundColor: cs.error),
                      icon: Icon(
                        explicitExcluded
                            ? Icons.restore_rounded
                            : Icons.block_rounded,
                        size: 16,
                      ),
                      label: Text(
                        explicitExcluded
                            ? i18n.tr('restore')
                            : i18n.tr('exclude'),
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
      },
      bodyBuilder: (context, animation) => IgnorePointer(
        ignoring: !_expansionController.isExpanded,
        child: FadeTransition(
          opacity: animation,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final child in widget.folder.children)
                LibraryEditTreeNodeWidget(
                  key: ValueKey(child.pathValue),
                  libraryPath: widget.libraryPath,
                  node: child,
                  depth: widget.folder.depth + 1,
                  initiallyExpanded: widget.initiallyExpanded,
                  onRememberFolder: widget.onRememberFolder,
                ),
            ],
          ),
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
