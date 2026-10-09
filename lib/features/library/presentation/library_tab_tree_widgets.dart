import 'library_download_actions.dart';
import 'library_providers.dart';
import 'library_removal_feedback.dart';
import '../../player/presentation/playback_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/search_query_utils.dart';
import '../domain/library_node.dart';
import '../../../core/media/path_matcher.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/search_highlight.dart';
import '../../../core/widgets/page_translation_scope.dart';
import '../../../core/translation/text_translation_service.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import 'audio_detail_sheet.dart';
import '../../../app/theme/app_styles.dart';

import 'library_card_artwork.dart';
import 'library_tab_ui_helpers.dart';

const Color _librarySelectionCheckmarkColor = Color(0xFF4CAF50);
const Duration _libraryIndicatorFadeDuration = Duration(milliseconds: 450);

class LibrarySelectionIndicator extends StatelessWidget {
  const LibrarySelectionIndicator({
    super.key,
    this.path,
    this.isSelected = true,
  });

  final String? path;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _libraryIndicatorFadeDuration;
    final surfaceBorderColor = isSelected
        ? Color.alphaBlend(
            cs.primaryContainer.withValues(alpha: 0.15),
            cs.surface,
          )
        : cs.surface;
    final normalizedPath = path == null ? null : PathMatcher.normalize(path!);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedSwitcher(
          duration: duration,
          reverseDuration: duration,
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, animation) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: isSelected
              ? Container(
                  key: normalizedPath == null
                      ? const ValueKey<String>('library_selection_indicator')
                      : ValueKey<String>(
                          'library_selection_indicator_$normalizedPath',
                        ),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _librarySelectionCheckmarkColor,
                    border: Border.all(color: surfaceBorderColor, width: 2),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                )
              : SizedBox.shrink(
                  key: normalizedPath == null
                      ? const ValueKey<String>(
                          'library_selection_indicator_hidden',
                        )
                      : ValueKey<String>(
                          'library_selection_indicator_hidden_$normalizedPath',
                        ),
                ),
        ),
      ),
    );
  }
}

class LibraryPinnedIndicator extends StatelessWidget {
  const LibraryPinnedIndicator({
    super.key,
    this.path,
    this.color,
    this.isSelected = false,
    this.isPinned = true,
  });

  final String? path;
  final Color? color;
  final bool isSelected;
  final bool isPinned;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _libraryIndicatorFadeDuration;
    final pinColor = color ?? cs.primary;
    final normalizedPath = path == null ? null : PathMatcher.normalize(path!);
    final surfaceBorderColor = isSelected
        ? Color.alphaBlend(
            cs.primaryContainer.withValues(alpha: 0.15),
            cs.surface,
          )
        : cs.surface;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedSwitcher(
          duration: duration,
          reverseDuration: duration,
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          child: isPinned
              ? Container(
                  key: normalizedPath == null
                      ? const ValueKey<String>('library_pinned')
                      : ValueKey<String>('library_pinned_$normalizedPath'),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: pinColor,
                    border: Border.all(color: surfaceBorderColor, width: 2),
                  ),
                  child: const Icon(
                    Icons.push_pin_rounded,
                    size: 13,
                    color: Colors.white,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

@visibleForTesting
class LibraryTreeItem extends StatelessWidget {
  const LibraryTreeItem({
    super.key,
    required this.node,
    this.initiallyExpanded = false,
    this.searchQuery = '',
    this.index,
    this.onFolderExpansionChanged,
    this.renderChildrenInline = true,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onToggleSelect,
  });

  final LibraryNode node;
  final bool initiallyExpanded;
  final String searchQuery;
  final int? index;
  final void Function(FolderNode folder, bool expanded)?
  onFolderExpansionChanged;
  final bool renderChildrenInline;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    if (node is FolderNode) {
      return LibraryFolderNodeWidget(
        folder: node as FolderNode,
        initiallyExpanded: initiallyExpanded,
        onFolderExpansionChanged: onFolderExpansionChanged,
        renderChildrenInline: renderChildrenInline,
        searchQuery: searchQuery,
        index: index,
        isSelectionMode: isSelectionMode,
        isSelected: isSelected,
        onLongPress: onLongPress,
        onToggleSelect: onToggleSelect,
      );
    } else if (node is TrackNode) {
      return _TrackNodeWidget(
        trackNode: node as TrackNode,
        searchQuery: searchQuery,
        index: index,
        isSelectionMode: isSelectionMode,
        isSelected: isSelected,
        onLongPress: onLongPress,
        onToggleSelect: onToggleSelect,
      );
    }
    return const SizedBox.shrink();
  }
}

class LibraryFolderNodeWidget extends ConsumerStatefulWidget {
  const LibraryFolderNodeWidget({
    super.key,
    required this.folder,
    required this.initiallyExpanded,
    required this.searchQuery,
    this.index,
    this.onFolderExpansionChanged,
    this.renderChildrenInline = true,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onToggleSelect,
  });

  final FolderNode folder;
  final bool initiallyExpanded;
  final String searchQuery;
  final int? index;
  final void Function(FolderNode folder, bool expanded)?
  onFolderExpansionChanged;
  final bool renderChildrenInline;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  @override
  ConsumerState<LibraryFolderNodeWidget> createState() =>
      _FolderNodeWidgetState();
}

class _FolderNodeWidgetState extends ConsumerState<LibraryFolderNodeWidget> {
  static const double _rootFolderTileHeight =
      LibraryLikeCardMetrics.rootTileHeight;
  static const double _childFolderTileHeight = 44;
  static const double _childFolderTitleBlockHeight = 36;

  final ExpansibleController _expansionController = ExpansibleController();
  late bool _expanded = widget.initiallyExpanded;
  FolderNode? _loadedFolder;
  bool _isLoadingChildren = false;
  bool _hasLoadError = false;

  @override
  void initState() {
    super.initState();
    if (widget.renderChildrenInline &&
        widget.initiallyExpanded &&
        widget.folder.children.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadChildren());
      });
    }
  }

  @override
  void didUpdateWidget(covariant LibraryFolderNodeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.folder, widget.folder)) {
      final retainLoadedChildren =
          _loadedFolder != null &&
          widget.folder.children.isEmpty &&
          PathMatcher.equalsNormalized(
            oldWidget.folder.path,
            widget.folder.path,
          );
      if (!retainLoadedChildren) {
        _loadedFolder = null;
      }
      _isLoadingChildren = false;
      _hasLoadError = false;
      if (widget.renderChildrenInline &&
          _expanded &&
          widget.folder.children.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_loadChildren(refresh: retainLoadedChildren));
          }
        });
      }
    }
    if (widget.initiallyExpanded && !_expanded) {
      _expanded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _expansionController.expand();
        if (widget.renderChildrenInline) unawaited(_loadChildren());
      });
      return;
    }
    if (!widget.initiallyExpanded && oldWidget.initiallyExpanded && _expanded) {
      _expanded = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expansionController.collapse();
      });
    }
  }

  Future<void> _loadChildren({bool refresh = false}) async {
    if ((!refresh && _loadedFolder != null) ||
        _isLoadingChildren ||
        widget.folder.children.isNotEmpty) {
      return;
    }
    final requestedCard = widget.folder;
    final requestedPath = widget.folder.path;
    final keepCurrentChildrenVisible = _loadedFolder != null;
    if (keepCurrentChildrenVisible) {
      _isLoadingChildren = true;
    } else {
      setState(() {
        _isLoadingChildren = true;
        _hasLoadError = false;
      });
    }
    try {
      final folder = await ref
          .read(libraryFacadeProvider)
          .loadLibraryFolderTree(requestedPath);
      if (!mounted ||
          !identical(widget.folder, requestedCard) ||
          !PathMatcher.equalsNormalized(widget.folder.path, requestedPath)) {
        return;
      }
      setState(() {
        _loadedFolder = folder;
        _hasLoadError = folder == null;
        _isLoadingChildren = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _hasLoadError = true;
          _isLoadingChildren = false;
        });
      }
    } finally {
      if (mounted && _isLoadingChildren) {
        setState(() => _isLoadingChildren = false);
      } else {
        _isLoadingChildren = false;
      }
    }
  }

  Future<void> _removeFolder(BuildContext context) async {
    await stageLibraryRemoval(
      context,
      ref,
      targetPath: widget.folder.path,
      target: LibraryRemovalTarget.folder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isHidden = ref.watch(
      isUndoableRemovalHiddenProvider(libraryRemovalKey(widget.folder.path)),
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final folder = _loadedFolder ?? widget.folder;
    final isRootFolder = folder.depth == 0;
    final isPinned =
        isRootFolder &&
        ref.watch(
          settingsStateProvider.select(
            (s) =>
                s.value?.pinnedLibraryPaths.contains(
                  PathMatcher.normalize(folder.path),
                ) ??
                false,
          ),
        );
    final rootDetailState = isRootFolder
        ? ref.watch(
            libraryDetailForTargetProvider(
              AudioDetailTarget.libraryRootFolder(folder.path),
            ),
          )
        : null;
    final hasChildren =
        folder.children.isNotEmpty || folder.totalTrackCount > 0;
    const cardShape = LibraryLikeCardMetrics.cardShape;
    final rootDetail = rootDetailState?.value;
    final isRootDetailLoading = rootDetailState?.isLoading ?? false;
    final tokens = AppDesignTokens.of(context);
    final folderRadius = BorderRadius.circular(tokens.radiusSmall);

    final Widget content;
    if (isRootFolder) {
      final selection = LibraryBatchSelection.fromNode(folder);
      final canPlay = !widget.isSelectionMode && selection.firstTrack != null;
      final actions = LibraryLikeCardActions(
        onAdd: canPlay
            ? () => unawaited(runLibraryCardAction(
                context: context,
                ref: ref,
                selection: selection,
                temporary: false,
              ))
            : null,
        onPlay: canPlay
            ? () => unawaited(runLibraryCardAction(
                context: context,
                ref: ref,
                selection: selection,
                temporary: true,
              ))
            : null,
        addLabel: i18n.tr('add'),
        playLabel: i18n.tr('play'),
      );
      content = ListTile(
        contentPadding: LibraryLikeCardMetrics.rootTilePadding,
        minTileHeight: _rootFolderTileHeight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            LibraryLikeCardMetrics.cardRadius,
          ),
        ),
        title: RootFolderCardContent(
          folderPath: folder.path,
          folderName: folder.name,
          folderDuration: folder.totalDuration,
          detail: rootDetail,
          detailLoading: isRootDetailLoading,
          trailingActions: actions,
          index: widget.index,
          isSelected: widget.isSelected,
          isPinned: isPinned,
        ),
      );
    } else {
      content = Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
          listTileTheme: const ListTileThemeData(
            minVerticalPadding: 0,
            visualDensity: VisualDensity(vertical: -4),
          ),
        ),
        child: ExpansionTile(
          expansionAnimationStyle: appExpansionAnimationStyle(context),
          key: PageStorageKey<String>('library-folder:${folder.path}'),
          controller: _expansionController,
          initiallyExpanded: widget.initiallyExpanded,
          minTileHeight: _childFolderTileHeight,
          visualDensity: const VisualDensity(vertical: -4),
          enabled: !widget.isSelectionMode,
          onExpansionChanged: (expanded) {
            if (_expanded == expanded) return;
            setState(() {
              _expanded = expanded;
            });
            widget.onFolderExpansionChanged?.call(widget.folder, expanded);
            if (expanded && widget.renderChildrenInline) {
              unawaited(_loadChildren());
            }
          },
          shape: RoundedRectangleBorder(borderRadius: folderRadius),
          collapsedShape: RoundedRectangleBorder(borderRadius: folderRadius),
          tilePadding: const EdgeInsets.fromLTRB(6, 0, 4, 0),
          childrenPadding: const EdgeInsets.fromLTRB(4, 0, 0, 0),
          title: SizedBox(
            height: _childFolderTileHeight,
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                  size: 20,
                  color: cs.primary.withValues(alpha: 0.8),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: SizedBox(
                    height: _childFolderTitleBlockHeight,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        WorkPageTranslationBuilder(
                          texts: [folder.name],
                          builder: (context, translate, _) =>
                              SearchHighlightedText(
                                text: translate(folder.name),
                                terms: widget.searchQuery.trim().isEmpty
                                    ? null
                                    : extractSearchTerms(widget.searchQuery),
                                style:
                                    Theme.of(
                                      context,
                                    ).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                      height: 1.06,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.9,
                                      ),
                                    ) ??
                                    const TextStyle(),
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          trailing: SizedBox(
            width: 30,
            height: _childFolderTileHeight,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (hasChildren)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: IgnorePointer(
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
                  ),
              ],
            ),
          ),
          children: !_expanded || !widget.renderChildrenInline
              ? const <Widget>[]
              : <Widget>[
                  PlaceholderContentTransition(
                    fit: StackFit.loose,
                    showPlaceholder:
                        _isLoadingChildren && _loadedFolder == null,
                    placeholder: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    content: _hasLoadError
                        ? Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            child: OperationStatusBanner(
                              key: ValueKey<String>(
                                'folder_children_error:${folder.path}',
                              ),
                              label: i18n.tr('operation_failed_retry'),
                              onRetry: () =>
                                  unawaited(_loadChildren(refresh: true)),
                              retryTooltip: i18n.tr('retry'),
                            ),
                          )
                        : Column(
                            children: folder.children
                                .map(
                                  (childNode) => Padding(
                                    padding: EdgeInsets.zero,
                                    child: RepaintBoundary(
                                      child: LibraryTreeItem(
                                        key: ValueKey(childNode.path),
                                        node: childNode,
                                        initiallyExpanded:
                                            widget.onFolderExpansionChanged ==
                                                null
                                            ? widget.initiallyExpanded
                                            : false,
                                        onFolderExpansionChanged:
                                            widget.onFolderExpansionChanged,
                                        searchQuery: widget.searchQuery,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                ],
        ),
      );
    }

    final folderShape = isRootFolder
        ? cardShape
        : RoundedRectangleBorder(borderRadius: folderRadius);
    final cardContent = isRootFolder
        ? Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            shape: cardShape,
            color: widget.isSelected
                ? cs.primaryContainer.withValues(alpha: 0.25)
                : Colors.transparent,
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            // The tap surface sits inside the card so its ink highlight and
            // ripple paint above the swipe card's closed background.
            child: InkWell(
              canRequestFocus: widget.isSelectionMode,
              onLongPress: widget.onLongPress,
              onTap: widget.isSelectionMode
                  ? widget.onToggleSelect
                  : () => unawaited(
                      showAudioDetailSheet(
                        context,
                        AudioDetailTarget.libraryRootFolder(folder.path),
                        initialDetail: rootDetail,
                        initialCoverPath: ref
                            .read(libraryFacadeProvider)
                            .resolvedCoverPathForFolder(folder.path),
                      ),
                    ),
              child: content,
            ),
          )
        : content;

    final swipeCard = SwipeRevealCard(
      shape: folderShape,
      enabled: !widget.isSelectionMode,
      closedColor: cs.surface,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio_folder'),
      secondaryActionLabel: isRootFolder ? i18n.tr('download') : null,
      secondaryActionTooltip: isRootFolder ? i18n.tr('download') : null,
      secondaryActionIcon: Icons.download_rounded,
      verticalActions: isRootFolder,
      onSecondaryAction: isRootFolder
          ? () => unawaited(
              downloadAudioTargetFromAsmr(
                context: context,
                ref: ref,
                target: AudioDetailTarget.libraryRootFolder(widget.folder.path),
              ),
            )
          : null,
      animateLeadingActionClose: true,
      onLeadingAction: isRootFolder
          ? () => unawaited(
              saveSettingsWithFeedback(
                context,
                () => ref
                    .read(settingsRepositoryProvider)
                    .toggleLibraryPathPinned(widget.folder.path),
              ),
            )
          : null,
      leadingActionLabel: isRootFolder
          ? i18n.tr(isPinned ? 'unpin_from_top' : 'pin_to_top')
          : null,
      leadingActionTooltip: isRootFolder
          ? i18n.tr(isPinned ? 'unpin_from_top' : 'pin_to_top')
          : null,
      leadingActionIcon: Icons.push_pin_rounded,
      leadingActionIconWidget: isPinned ? const PushPinOffIcon() : null,
      onRemove: () => _removeFolder(context),
      onWillReveal: _expansionController.collapse,
      child: cardContent,
    );

    // Child folder rows paint their press ink from the expansion tile material,
    // so they only need the wrapper that keeps long press and selection taps.
    final result = isRootFolder
        ? swipeCard
        : InkWell(
            canRequestFocus: widget.isSelectionMode,
            onLongPress: widget.onLongPress,
            onTap: widget.isSelectionMode ? widget.onToggleSelect : null,
            borderRadius: folderShape.borderRadius as BorderRadius?,
            child: swipeCard,
          );

    return UndoableRemovalTransition(hidden: isHidden, child: result);
  }
}

class _TrackNodeWidget extends ConsumerWidget {
  const _TrackNodeWidget({
    required this.trackNode,
    this.searchQuery = '',
    this.index,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onToggleSelect,
  });

  final TrackNode trackNode;
  final String searchQuery;
  final int? index;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  Future<void> _removeTrack(
    BuildContext context,
    WidgetRef ref,
    MusicTrack track,
  ) async {
    await stageLibraryRemoval(
      context,
      ref,
      targetPath: track.path,
      target: LibraryRemovalTarget.track,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHidden = ref.watch(
      isUndoableRemovalHiddenProvider(libraryRemovalKey(trackNode.track.path)),
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final library = ref.read(libraryFacadeProvider);
    final playback = ref.read(playbackFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final track = trackNode.track;
    final nameParts = textTranslationText(track.displayName, fileName: true);
    final isPinned =
        track.isSingle &&
        ref.watch(
          settingsStateProvider.select(
            (s) =>
                s.value?.pinnedLibraryPaths.contains(
                  PathMatcher.normalize(track.path),
                ) ??
                false,
          ),
        );
    final singleDetailState = track.isSingle
        ? ref.watch(
            libraryDetailForTargetProvider(
              AudioDetailTarget.singleAudioFile(track.path),
            ),
          )
        : null;
    final visibleCoverPath = track.isSingle && !track.isVideo
        ? ref.watch(libraryCoverForTrackProvider(track.path)).value
        : null;
    final isAlreadyPlaying = ref.watch(isTrackActiveProvider(track.path));
    const cardShape = LibraryLikeCardMetrics.cardShape;
    final singleDetail = singleDetailState?.value;
    final isSingleDetailLoading = singleDetailState?.isLoading ?? false;
    final resolvedCoverPath =
        visibleCoverPath ?? library.resolvedCoverPathForTrack(track);
    final useFeaturedSingleCard =
        track.isVideo || hasDisplayableCoverArtwork(track, resolvedCoverPath);

    Future<void> playSingleTrack() async {
      unawaited(
        AppInteractionFeedback.trigger(
          AppInteractionFeedbackType.tap,
          context: context,
        ),
      );
      final succeeded = await playback.playDirect([track]);
      if (!context.mounted) return;
      if (!succeeded) {
        showAppSnackBar(
          context,
          i18n.tr('operation_failed_retry'),
          tone: AppFeedbackTone.destructive,
          icon: Icons.error_outline_rounded,
        );
      }
    }

    final actions = LibraryLikeCardActions(
      onAdd: isSelectionMode
          ? null
          : () => unawaited(runLibraryCardAction(
              context: context,
              ref: ref,
              selection: LibraryBatchSelection.fromNode(trackNode),
              temporary: false,
            )),
      onPlay: isSelectionMode ? null : () => unawaited(playSingleTrack()),
      addLabel: i18n.tr('add'),
      playLabel: i18n.tr('play'),
    );

    Widget buildSingleTrackCard(bool useFeaturedCard) {
      return SwipeRevealCard(
        shape: cardShape,
        enabled: !isSelectionMode,
        closedColor: cs.surface,
        actionLabel: i18n.tr('remove'),
        removeTooltip: i18n.tr('remove_audio'),
        secondaryActionLabel: i18n.tr('audio_detail_edit_info'),
        secondaryActionTooltip: i18n.tr('audio_detail_edit_info'),
        secondaryActionIcon: Icons.edit_rounded,
        verticalActions: useFeaturedCard,
        onSecondaryAction: () => unawaited(
          showAudioDetailEditor(
            context,
            ref,
            AudioDetailTarget.singleAudioFile(track.path),
          ),
        ),
        animateLeadingActionClose: true,
        onLeadingAction: () => unawaited(
          saveSettingsWithFeedback(
            context,
            () => ref
                .read(settingsRepositoryProvider)
                .toggleLibraryPathPinned(track.path),
          ),
        ),
        leadingActionLabel: i18n.tr(isPinned ? 'unpin_from_top' : 'pin_to_top'),
        leadingActionTooltip: i18n.tr(
          isPinned ? 'unpin_from_top' : 'pin_to_top',
        ),
        leadingActionIcon: Icons.push_pin_rounded,
        leadingActionIconWidget: isPinned ? const PushPinOffIcon() : null,
        onRemove: () => _removeTrack(context, ref, track),
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: cardShape,
          color: isSelected
              ? cs.primaryContainer.withValues(alpha: 0.25)
              : (isAlreadyPlaying && !track.isVideo && useFeaturedCard)
              ? Color.alphaBlend(
                  cs.primaryContainer.withValues(alpha: 0.40),
                  cs.surface,
                )
              : Colors.transparent,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          // The tap surface sits inside the card so its ink highlight and
          // ripple paint above the swipe card's closed background.
          child: InkWell(
            canRequestFocus: isSelectionMode,
            onLongPress: onLongPress,
            onTap: isSelectionMode
                ? onToggleSelect
                : () => unawaited(playSingleTrack()),
            child: useFeaturedCard
                ? ListTile(
                    contentPadding: LibraryLikeCardMetrics.rootTilePadding,
                    minTileHeight: _FolderNodeWidgetState._rootFolderTileHeight,
                    title: SingleMediaFileCardContent(
                      track: track,
                      title: track.displayName,
                      detail: singleDetail,
                      detailLoading: isSingleDetailLoading,
                      trailingActions: actions,
                      index: index,
                      isSelected: isSelected,
                      isPinned: isPinned,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(
                      LibraryLikeCardMetrics.coverDistance,
                    ),
                    child: SingleAudioFileCardContent(
                      path: track.path,
                      isSelected: isSelected,
                      isPinned: isPinned,
                      title: track.displayName,
                      detail: singleDetail,
                      detailLoading: isSingleDetailLoading,
                      trailingActions: actions,
                    ),
                  ),
          ),
        ),
      );
    }

    final result = track.isSingle
        ? buildSingleTrackCard(useFeaturedSingleCard)
        : SwipeRevealCard(
            shape: cardShape,
            actionLabel: i18n.tr('remove'),
            removeTooltip: i18n.tr('remove_audio'),
            onRemove: () => _removeTrack(context, ref, track),
            child: ColoredBox(
              color: Colors.transparent,
              child: SizedBox(
                height: 38,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.audio_file_rounded,
                        size: 16,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: WorkPageTranslationBuilder(
                          texts: [nameParts.source],
                          builder: (context, translate, _) => SearchHighlightedText(
                            text:
                                '${translate(nameParts.source)}${nameParts.suffix}',
                            terms: searchQuery.trim().isEmpty
                                ? null
                                : extractSearchTerms(searchQuery),
                            maxLines: 1,
                            style:
                                Theme.of(
                                  context,
                                ).textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: isAlreadyPlaying
                                      ? cs.primary
                                      : cs.onSurface,
                                ) ??
                                const TextStyle(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

    return UndoableRemovalTransition(hidden: isHidden, child: result);
  }
}
