import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import 'work_detail_entries.dart';
import '../../../core/widgets/page_translation_scope.dart';

class WorkDetailEntryTile extends StatefulWidget {
  const WorkDetailEntryTile({
    super.key,
    required this.item,
    required this.accentColor,
    required this.menuEntries,
    required this.moreLabel,
    required this.onAction,
  });

  final WorkEntryItem item;
  final Color accentColor;
  final List<UnifiedMenuEntry<WorkEntryAction>> menuEntries;
  final String moreLabel;
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
    final icon = switch (item.type) {
      WorkEntryType.folder => AppDesignTokens.folderIcon,
      WorkEntryType.audio =>
        (item.track?.isVideo ?? item.asmrNode?.isVideo ?? false)
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
        child: ListTile(
          dense: true,
          minTileHeight: FileTreeRow.layoutHeight(context),
          minVerticalPadding: 0,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          splashColor: color.withValues(alpha: 0.16),
          hoverColor: color.withValues(alpha: 0.08),
          selected: isHighlighted,
          selectedTileColor: widget.accentColor.withValues(alpha: 0.16),
          selectedColor: widget.accentColor,
          leading: Icon(
            icon,
            color: color,
            size: AppDesignTokens.fileEntryIconSize,
          ),
          title: WorkPageTranslationText(
            item.name,
            fileName: !isFolder,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: isFolder ? FontWeight.w600 : FontWeight.w500,
              color: cs.onSurface,
            ),
          ),
          trailing: SizedBox.square(
            dimension: 44,
            child: Builder(
              builder: (buttonContext) => IconButton(
                key: ValueKey<String>('work_entry_more_${item.relativePath}'),
                padding: EdgeInsets.zero,
                iconSize: 20,
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                icon: const Icon(Icons.more_vert_rounded),
                tooltip: widget.moreLabel,
                onPressed: () => _showButtonMenu(buttonContext),
              ),
            ),
          ),
          onLongPress: () {
            unawaited(
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.selection,
                context: context,
              ),
            );
            widget.onAction(WorkEntryAction.copy);
          },
          onTap: () {
            unawaited(
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.tap,
                context: context,
              ),
            );
            widget.onAction(
              item.type == WorkEntryType.audio
                  ? WorkEntryAction.play
                  : WorkEntryAction.open,
            );
          },
        ),
      ),
    );
  }
}
