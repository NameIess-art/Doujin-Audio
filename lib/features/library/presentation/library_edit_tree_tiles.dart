import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/path_display.dart';
import '../../../core/widgets/app_transitions.dart';
import '../application/library_facade.dart';
import 'library_providers.dart';

import 'library_edit_tree_projection.dart';

const Size _libraryEditActionMinimumSize = Size(0, 36);
const double _libraryEditChildFolderTileHeight = 48;
const _libraryEditRootFolderShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(10)),
);

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
  });

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
    final isRootFolder = widget.folder.depth == 0;

    final content = Theme(
      data: theme.copyWith(
        dividerColor: Colors.transparent,
        listTileTheme: isRootFolder
            ? theme.listTileTheme.copyWith(shape: _libraryEditRootFolderShape)
            : theme.listTileTheme.copyWith(minVerticalPadding: 0),
      ),
      child: ExpansionTile(
        expansionAnimationStyle: appExpansionAnimationStyle(context),
        key: PageStorageKey<String>(
          'library-edit-folder:${widget.libraryPath}:$folderPath',
        ),
        controller: _expansionController,
        initiallyExpanded: widget.initiallyExpanded,
        dense: !isRootFolder,
        visualDensity: isRootFolder ? null : const VisualDensity(vertical: -4),
        minTileHeight: isRootFolder ? null : _libraryEditChildFolderTileHeight,
        onExpansionChanged: (expanded) {
          if (_expanded == expanded) return;
          setState(() => _expanded = expanded);
        },
        tilePadding: EdgeInsets.fromLTRB(
          isRootFolder ? 14 : 6,
          isRootFolder ? 3 : 0,
          6,
          isRootFolder ? 3 : 0,
        ),
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
                  minimumSize: _libraryEditActionMinimumSize,
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
              ),
              child: TextButton.icon(
                onPressed: inheritedExcluded
                    ? null
                    : () {
                        if (widget.folder.children.isNotEmpty) {
                          widget.onRememberFolder(folderPath, widget.folder);
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
                  LibraryEditTreeNodeWidget(
                    key: ValueKey(child.pathValue),
                    libraryPath: widget.libraryPath,
                    node: child,
                    initiallyExpanded: widget.initiallyExpanded,
                    onRememberFolder: widget.onRememberFolder,
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
      shape: _libraryEditRootFolderShape,
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
              color: viewState.muted ? cs.onSurfaceVariant : cs.primary,
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
