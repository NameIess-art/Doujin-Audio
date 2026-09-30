import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../application/asmr_download_selection.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_transitions.dart';

import 'asmr_download_format.dart';

class AsmrDownloadNodeTile extends ConsumerStatefulWidget {
  const AsmrDownloadNodeTile({
    super.key,
    required this.node,
    required this.depth,
    required this.selection,
    required this.onSelectionChanged,
  });

  final AsmrDownloadSelectionNode node;
  final int depth;
  final AsmrDownloadSelectionModel selection;
  final VoidCallback onSelectionChanged;

  @override
  ConsumerState<AsmrDownloadNodeTile> createState() =>
      AsmrDownloadNodeTileState();
}

class AsmrDownloadNodeTileState extends ConsumerState<AsmrDownloadNodeTile> {
  static const double _indentWidth = 14;
  static const double _folderRowHeight = 44;
  static const double _fileRowHeight = 46;

  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.depth == 0;
  }

  void _toggleSelection(bool? next) {
    widget.selection.togglePath(widget.node.track.relativePath, next);
    widget.onSelectionChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    final folderRadius = BorderRadius.circular(tokens.radiusSmall);
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final value = widget.selection.stateForPath(widget.node.track.relativePath);
    final indent = _indentWidth * widget.depth;

    if (widget.node.track.isFolder) {
      final hasChildren = widget.node.children.isNotEmpty;
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          expansionAnimationStyle: appExpansionAnimationStyle(context),
          initiallyExpanded: _expanded,
          minTileHeight: _folderRowHeight,
          shape: RoundedRectangleBorder(borderRadius: folderRadius),
          collapsedShape: RoundedRectangleBorder(borderRadius: folderRadius),
          tilePadding: EdgeInsetsDirectional.only(start: indent, end: 2),
          childrenPadding: EdgeInsets.zero,
          onExpansionChanged: (expanded) {
            setState(() {
              _expanded = expanded;
            });
          },
          title: Row(
            children: [
              _CompactNodeCheckbox(value: value, onChanged: _toggleSelection),
              const SizedBox(width: 4),
              Icon(
                _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                size: 20,
                color: asmrBlue.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.node.track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    height: 1.06,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ],
          ),
          trailing: hasChildren
              ? AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.expand_more_rounded,
                    color: cs.onSurfaceVariant,
                    size: 20,
                  ),
                )
              : const SizedBox(width: 20),
          children: hasChildren && _expanded
              ? [
                  for (final child in widget.node.children)
                    AsmrDownloadNodeTile(
                      node: child,
                      depth: widget.depth + 1,
                      selection: widget.selection,
                      onSelectionChanged: widget.onSelectionChanged,
                    ),
                ]
              : hasChildren
              ? const <Widget>[]
              : [
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: indent + _indentWidth + 40,
                      end: 8,
                      bottom: 4,
                    ),
                    child: Text(
                      i18n.tr('asmr_download_empty_folder'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
        ),
      );
    }

    return InkWell(
      onTap: () => _toggleSelection(value == true ? false : true),
      borderRadius: folderRadius,
      child: SizedBox(
        height: _fileRowHeight,
        child: Padding(
          padding: EdgeInsetsDirectional.only(start: indent, end: 4),
          child: Row(
            children: [
              _CompactNodeCheckbox(value: value, onChanged: _toggleSelection),
              const SizedBox(width: 4),
              Icon(
                asmrDownloadFileIcon(widget.node.track),
                size: 18,
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.node.track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                formatAsmrDownloadSize(widget.node.track.size),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactNodeCheckbox extends StatelessWidget {
  const _CompactNodeCheckbox({required this.value, required this.onChanged});

  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    return SizedBox(
      width: 28,
      height: 28,
      child: Checkbox(
        tristate: true,
        value: value,
        onChanged: onChanged,
        activeColor: asmrBlue,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
