import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/media_file_support.dart' show formatMediaFileSize;
import '../../../core/media/path_matcher.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/ui/visual_settings_providers.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_entry_ink_well.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_translation_scope.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import 'library_providers.dart';
import 'work_detail_entries.dart';

class WorkDetailEntryTile extends StatefulWidget {
  const WorkDetailEntryTile({
    super.key,
    required this.item,
    required this.accentColor,
    required this.menuEntries,
    required this.moreLabel,
    required this.unknownSizeLabel,
    required this.onAction,
  });

  final WorkEntryItem item;
  final Color accentColor;
  final List<UnifiedMenuEntry<WorkEntryAction>> menuEntries;
  final String moreLabel;
  final String unknownSizeLabel;
  final ValueChanged<WorkEntryAction> onAction;

  @override
  State<WorkDetailEntryTile> createState() => _WorkDetailEntryTileState();
}

class _WorkDetailEntryTileState extends State<WorkDetailEntryTile> {
  bool _isMenuOpen = false;
  ValueNotifier<bool>? _menuDismissal;

  @override
  void dispose() {
    _menuDismissal?.value = true;
    _menuDismissal?.dispose();
    super.dispose();
  }

  Future<void> _showMenu(BuildContext context, RelativeRect position) async {
    if (!mounted || _isMenuOpen) return;
    setState(() => _isMenuOpen = true);
    try {
      final result = await showDockAwareMenu<WorkEntryAction>(
        context: context,
        position: position,
        entries: widget.menuEntries,
        dismissOn: _menuDismissal ??= ValueNotifier(false),
      );
      if (context.mounted && result != null) {
        widget.onAction(result);
      }
    } finally {
      if (mounted) {
        setState(() => _isMenuOpen = false);
      }
    }
  }

  Future<void> _showButtonMenu(BuildContext context) async {
    final button = context.findRenderObject() as RenderBox?;
    final overlay =
        MobileOverlayInset.menuOverlayOf(context) ?? Overlay.maybeOf(context);
    final box = overlay?.context.findRenderObject() as RenderBox?;
    if (button == null || !button.hasSize || box == null || !box.hasSize) {
      return;
    }
    final rect = button.localToGlobal(Offset.zero, ancestor: box) & button.size;
    await _showMenu(
      context,
      RelativeRect.fromRect(rect, Offset.zero & box.size),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = widget.item;
    final isFolder = item.type == WorkEntryType.folder;
    final nameStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
      fontSize: 13.5,
      height: 1.2,
      fontWeight: isFolder ? FontWeight.w600 : FontWeight.w500,
      color: cs.onSurface,
    );
    final infoStyle = Theme.of(context).textTheme.labelSmall!.copyWith(
      fontSize: 11,
      height: 1.2,
      color: cs.onSurfaceVariant.withValues(alpha: 0.6),
    );
    final fileSize = item.fileSizeBytes;
    final info = <String>[
      fileSize != null && fileSize > 0
          ? formatMediaFileSize(fileSize)
          : widget.unknownSizeLabel,
      if (item.type == WorkEntryType.audio && item.duration != null)
        formatDurationWithUnits(item.duration!),
      if (item.extension.isNotEmpty) item.extension.substring(1),
    ].join(' · ');
    final icon = switch (item.type) {
      WorkEntryType.folder => AppDesignTokens.folderIcon,
      WorkEntryType.audio =>
        (item.track?.isVideo ?? item.isRemoteVideo)
            ? Icons.videocam_outlined
            : AppDesignTokens.audioFileIcon,
      WorkEntryType.text => AppDesignTokens.textFileIcon,
      WorkEntryType.image => AppDesignTokens.imageFileIcon,
    };
    final color = switch (item.type) {
      WorkEntryType.folder => AppDesignTokens.folderIconColor,
      WorkEntryType.audio => widget.accentColor,
      WorkEntryType.text => AppDesignTokens.textFileIconColor,
      WorkEntryType.image => AppDesignTokens.imageFileIconColor,
    };
    final isHighlighted =
        defaultTargetPlatform == TargetPlatform.windows && _isMenuOpen;

    final opensPage =
        item.type == WorkEntryType.text || item.type == WorkEntryType.image;
    final onLongPress = defaultTargetPlatform == TargetPlatform.windows
        ? null
        : () {
            unawaited(
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.selection,
              ),
            );
            widget.onAction(WorkEntryAction.copy);
          };

    void onTap() {
      widget.onAction(
        item.type == WorkEntryType.audio
            ? WorkEntryAction.play
            : WorkEntryAction.open,
      );
    }

    final fallbackIcon = Icon(
      icon,
      color: color,
      size: AppDesignTokens.fileEntryIconSize,
    );
    final imagePath = item.type == WorkEntryType.image
        ? (item.imageItem?.path ?? item.fullPathOrUrl).trim()
        : '';
    final leading = imagePath.isNotEmpty && !PathMatcher.isContentUri(imagePath)
        ? _WorkImageEntryLeading(
            path: imagePath,
            fallbackIcon: fallbackIcon,
          )
        : fallbackIcon;

    final tile = ListTile(
      dense: true,
      enableFeedback: false,
      minTileHeight: 44,
      minVerticalPadding: 4,
      titleAlignment: ListTileTitleAlignment.center,
      horizontalTitleGap: 0,
      // Preserve the name's leading offset while tightening the action gap.
      minLeadingWidth: 40,
      contentPadding: const EdgeInsets.only(left: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      selected: isHighlighted,
      selectedTileColor: widget.accentColor.withValues(alpha: 0.16),
      selectedColor: widget.accentColor,
      leading: leading,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WorkPageTranslationText(
            item.displayName,
            fileName: !isFolder,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: nameStyle,
          ),
          if (!isFolder) ...[
            const SizedBox(height: 2),
            Text(
              info,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: infoStyle,
            ),
          ],
        ],
      ),
      trailing: SizedBox.square(
        dimension: 44,
        child: Builder(
          builder: (buttonContext) => IconButton(
            key: ValueKey<String>('work_entry_more_${item.relativePath}'),
            // Match the skeleton action center without shrinking its target.
            padding: const EdgeInsets.only(left: 4),
            iconSize: 20,
            style: appIconButtonStyle(
              IconButton.styleFrom(
                foregroundColor: cs.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: widget.moreLabel,
            onPressed: () => _showButtonMenu(buttonContext),
          ),
        ),
      ),
      onLongPress: opensPage ? null : onLongPress,
      onTap: opensPage ? null : onTap,
    );

    return GestureDetector(
      onSecondaryTapDown: defaultTargetPlatform == TargetPlatform.windows
          ? (details) async {
              if (_isMenuOpen) return;
              if (mounted) {
                setState(() => _isMenuOpen = true);
              }
              try {
                final result = await showUnifiedContextMenu<WorkEntryAction>(
                  context: context,
                  globalPosition: details.globalPosition,
                  entries: widget.menuEntries,
                  dismissOn: _menuDismissal ??= ValueNotifier(false),
                );
                if (context.mounted && result != null) {
                  widget.onAction(result);
                }
              } finally {
                if (mounted) {
                  setState(() => _isMenuOpen = false);
                }
              }
            }
          : null,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: opensPage
            ? AppEntryInkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onTap,
                onLongPress: onLongPress,
                child: tile,
              )
            : tile,
      ),
    );
  }
}

class _WorkImageEntryLeading extends StatelessWidget {
  const _WorkImageEntryLeading({
    required this.path,
    required this.fallbackIcon,
  });

  static const double thumbnailSize = 32;
  static const double thumbnailRadius = 6;

  final String path;
  final Widget fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final placeholder = Align(
      alignment: AlignmentDirectional.centerStart,
      child: fallbackIcon,
    );
    Widget buildPlaceholder(BuildContext _) => placeholder;
    final isRemote = PathMatcher.isRemoteUri(path);
    return SizedBox.square(
      dimension: thumbnailSize,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(thumbnailRadius),
        child: isRemote
            ? _RemoteImageEntryThumbnail(
                url: path,
                placeholderBuilder: buildPlaceholder,
              )
            : _LocalImageEntryThumbnail(
                path: path,
                placeholderBuilder: buildPlaceholder,
              ),
      ),
    );
  }
}

class _LocalImageEntryThumbnail extends ConsumerWidget {
  const _LocalImageEntryThumbnail({
    required this.path,
    required this.placeholderBuilder,
  });

  final String path;
  final WidgetBuilder placeholderBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cacheWidth = coverThumbnailCacheWidth(
      logicalWidth: _WorkImageEntryLeading.thumbnailSize,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: ref.watch(coverImageResolutionProvider),
    );
    return RetryingFileImage(
      path: path,
      browseThumbnail: true,
      deferLoadDuringInteraction: true,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      useDefaultCacheWidth: false,
      retryDelay: const Duration(seconds: 5),
      maxRetryAttempts: 2,
      loadingBuilder: placeholderBuilder,
      fallbackBuilder: placeholderBuilder,
    );
  }
}

class _RemoteImageEntryThumbnail extends ConsumerStatefulWidget {
  const _RemoteImageEntryThumbnail({
    required this.url,
    required this.placeholderBuilder,
  });

  final String url;
  final WidgetBuilder placeholderBuilder;

  @override
  ConsumerState<_RemoteImageEntryThumbnail> createState() =>
      _RemoteImageEntryThumbnailState();
}

class _RemoteImageEntryThumbnailState
    extends ConsumerState<_RemoteImageEntryThumbnail> {
  Object? _requestKey;
  Future<String?>? _future;

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final (revision, resolved) = ref.watch(
      coverGenerationProvider.select(
        (_) => (
          library.coverArtworkCacheService.revisionForScope(widget.url),
          library.resolvedCoverPathForRemoteCover(widget.url),
        ),
      ),
    );
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    final cacheWidth = coverThumbnailCacheWidth(
      logicalWidth: _WorkImageEntryLeading.thumbnailSize,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: ref.watch(coverImageResolutionProvider),
    );
    Future<String?> loadImage() =>
        coverUi.deferredRemoteCover(widget.url, context: context);
    final requestKey = (widget.url, resolved, revision);
    if (_requestKey != requestKey) {
      _requestKey = requestKey;
      _future = resolved != null
          ? SynchronousFuture<String?>(resolved)
          : loadImage();
    }
    return AsyncRemoteCoverImage(
      browseThumbnail: true,
      deferLoadDuringInteraction: true,
      onImageError: library.coverArtworkCacheService.reportArtworkReadFailure,
      url: widget.url,
      future: _future!,
      initialPath: resolved,
      retryFutureBuilder: loadImage,
      retryDelay: const Duration(seconds: 5),
      maxRetryAttempts: 2,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      useDefaultCacheWidth: false,
      loadingBuilder: widget.placeholderBuilder,
      fallbackBuilder: widget.placeholderBuilder,
    );
  }
}
