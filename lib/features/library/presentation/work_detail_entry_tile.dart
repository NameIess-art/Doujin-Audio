import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import 'work_detail_entries.dart';

class WorkDetailEntryTile extends StatelessWidget {
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

  Future<void> _showMenu(BuildContext context, RelativeRect position) async {
    final result = await showDockAwareMenu<WorkEntryAction>(
      context: context,
      position: position,
      entries: menuEntries,
    );
    if (context.mounted && result != null) {
      onAction(result);
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
    final isFolder = item.type == WorkEntryType.folder;
    final icon = switch (item.type) {
      WorkEntryType.folder => Icons.folder_rounded,
      WorkEntryType.audio =>
        (item.track?.isVideo ?? item.asmrNode?.isVideo ?? false)
            ? Icons.videocam_outlined
            : Icons.audiotrack_rounded,
      WorkEntryType.text => Icons.description_outlined,
      WorkEntryType.image => Icons.image_outlined,
    };
    final color = switch (item.type) {
      WorkEntryType.folder => const Color(0xFFFFA000),
      WorkEntryType.audio => accentColor,
      _ => cs.onSurfaceVariant,
    };
    return GestureDetector(
      onSecondaryTapDown: defaultTargetPlatform == TargetPlatform.windows
          ? (details) async {
              final result = await showUnifiedContextMenu<WorkEntryAction>(
                context: context,
                globalPosition: details.globalPosition,
                entries: menuEntries,
              );
              if (context.mounted && result != null) {
                onAction(result);
              }
            }
          : null,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: Icon(icon, color: color),
        title: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isFolder ? const TextStyle(fontWeight: FontWeight.w600) : null,
        ),
        trailing: SizedBox.square(
          dimension: 44,
          child: Builder(
            builder: (buttonContext) => IconButton(
              key: ValueKey<String>('work_entry_more_${item.relativePath}'),
              padding: EdgeInsets.zero,
              iconSize: 22,
              icon: const Icon(Icons.more_vert_rounded),
              tooltip: moreLabel,
              onPressed: () => _showButtonMenu(buttonContext),
            ),
          ),
        ),
        onTap: () => onAction(
          item.type == WorkEntryType.audio
              ? WorkEntryAction.play
              : WorkEntryAction.open,
        ),
      ),
    );
  }
}
