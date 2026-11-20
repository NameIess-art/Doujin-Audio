import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/media_file_support.dart' show formatMediaFileSize;
import '../../../core/media/path_matcher.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_entry_ink_well.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_translation_scope.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import 'work_detail_entries.dart';
import 'work_image_entry_thumbnail.dart';

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
  static const _shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(8)),
  );
  bool _isMenuOpen = false;
  Offset? _lastPointerPosition;
  ValueNotifier<bool>? _menuDismissal;
  final _highlightOpacity = ValueNotifier(0.0);

  MenuHighlightedItem get _highlightedItem => (
    context: context,
    shape: _shape,
    onFade: (opacity) {
      if (mounted) _highlightOpacity.value = opacity;
    },
  );

  @override
  void dispose() {
    _menuDismissal?.value = true;
    _menuDismissal?.dispose();
    _highlightOpacity.dispose();
    super.dispose();
  }

  Future<void> _showMenu(BuildContext context, {Offset? globalPosition}) async {
    if (!mounted || _isMenuOpen) return;
    setState(() => _isMenuOpen = true);
    _highlightOpacity.value = 1;
    try {
      final dismissal = _menuDismissal ??= ValueNotifier(false);
      final menu = globalPosition == null
          ? _showAnchoredMenu(context, dismissal)
          : showUnifiedContextMenu<WorkEntryAction>(
              context: context,
              globalPosition: globalPosition,
              entries: widget.menuEntries,
              dismissOn: dismissal,
              highlightedItem: _highlightedItem,
            );
      final result = await menu;
      if (context.mounted && result != null) {
        widget.onAction(result);
      }
    } finally {
      if (mounted) {
        _highlightOpacity.value = 0;
        setState(() => _isMenuOpen = false);
      }
    }
  }

  Future<WorkEntryAction?> _showAnchoredMenu(
    BuildContext context,
    ValueNotifier<bool> dismissal,
  ) async {
    final anchor = context.findRenderObject() as RenderBox?;
    final overlay =
        MobileOverlayInset.menuOverlayOf(context) ?? Overlay.maybeOf(context);
    final box = overlay?.context.findRenderObject() as RenderBox?;
    if (anchor == null || !anchor.hasSize || box == null || !box.hasSize) {
      return null;
    }
    final rect = anchor.localToGlobal(Offset.zero, ancestor: box) & anchor.size;
    return showDockAwareMenu<WorkEntryAction>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & box.size),
      entries: widget.menuEntries,
      dismissOn: dismissal,
      highlightedItem: _highlightedItem,
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
    final tokens = AppDesignTokens.of(context);
    final color = switch (item.type) {
      WorkEntryType.folder => tokens.folderColor,
      WorkEntryType.audio => widget.accentColor,
      WorkEntryType.text => tokens.textFileColor,
      WorkEntryType.image => tokens.imageFileColor,
    };
    final isWindows = Theme.of(context).platform == TargetPlatform.windows;
    final isHighlighted = _isMenuOpen;

    final opensPage =
        item.type == WorkEntryType.text || item.type == WorkEntryType.image;
    final onLongPress = isWindows
        ? null
        : () {
            unawaited(
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.selection,
              ),
            );
            unawaited(_showMenu(context, globalPosition: _lastPointerPosition));
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
    const thumbnailOutset =
        (WorkImageEntryThumbnail.size - AppDesignTokens.fileEntryIconSize) / 2;
    final leading = imagePath.isNotEmpty && !PathMatcher.isContentUri(imagePath)
        ? WorkImageEntryThumbnail(path: imagePath, fallbackIcon: fallbackIcon)
        : Padding(
            padding: const EdgeInsetsDirectional.only(start: thumbnailOutset),
            child: fallbackIcon,
          );

    final tile = ValueListenableBuilder<double>(
      valueListenable: _highlightOpacity,
      builder: (context, opacity, title) => ListTile(
        dense: true,
        enableFeedback: false,
        minTileHeight: 44,
        minVerticalPadding: 4,
        titleAlignment: ListTileTitleAlignment.center,
        horizontalTitleGap: 0,
        // Make room for the wider thumbnail around the icon's center.
        minLeadingWidth: 40 + thumbnailOutset,
        contentPadding: const EdgeInsetsDirectional.only(
          start: 16 - thumbnailOutset,
        ),
        shape: _shape,
        selected: isHighlighted,
        selectedTileColor: widget.accentColor.withValues(alpha: 0.16 * opacity),
        selectedColor: widget.accentColor,
        leading: leading,
        title: title,
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
              onPressed: () => _showMenu(buttonContext),
            ),
          ),
        ),
        onLongPress: opensPage ? null : onLongPress,
        onTap: opensPage ? null : onTap,
      ),
      child: Column(
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
    );

    return Listener(
      // Long press callbacks carry no position; keep the touch point so the
      // menu opens where the user pressed.
      onPointerDown: (event) => _lastPointerPosition = event.position,
      child: GestureDetector(
        onSecondaryTapDown: isWindows
            ? (details) {
                unawaited(
                  _showMenu(context, globalPosition: details.globalPosition),
                );
              }
            : null,
        child: Material(
          color: Colors.transparent,
          shape: _shape,
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
      ),
    );
  }
}
