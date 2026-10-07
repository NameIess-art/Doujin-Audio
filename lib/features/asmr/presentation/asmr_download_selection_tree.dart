import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../application/asmr_download_selection.dart';
import '../../../app/theme/app_design_tokens.dart';

import 'asmr_download_format.dart';

class AsmrDownloadSelectionList extends StatefulWidget {
  const AsmrDownloadSelectionList({
    super.key,
    required this.selection,
    required this.onSelectionChanged,
    this.padding = EdgeInsets.zero,
  });

  final AsmrDownloadSelectionModel selection;
  final VoidCallback onSelectionChanged;
  final EdgeInsetsGeometry padding;

  @override
  State<AsmrDownloadSelectionList> createState() =>
      _AsmrDownloadSelectionListState();
}

class _AsmrDownloadSelectionListState extends State<AsmrDownloadSelectionList> {
  final Set<String> _expandedPaths = <String>{};
  List<({AsmrDownloadSelectionNode node, int depth})> _rows = const [];

  @override
  void initState() {
    super.initState();
    _resetExpansion();
  }

  @override
  void didUpdateWidget(covariant AsmrDownloadSelectionList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection, widget.selection)) _resetExpansion();
  }

  void _resetExpansion() {
    _expandedPaths
      ..clear()
      ..addAll(
        widget.selection.rootNodes.map((node) => node.track.relativePath),
      );
    _projectRows();
  }

  void _projectRows() {
    final rows = <({AsmrDownloadSelectionNode node, int depth})>[];
    void visit(AsmrDownloadSelectionNode node, int depth) {
      rows.add((node: node, depth: depth));
      if (_expandedPaths.contains(node.track.relativePath)) {
        for (final child in node.children) {
          visit(child, depth + 1);
        }
      }
    }

    for (final root in widget.selection.rootNodes) {
      visit(root, 0);
    }
    _rows = rows;
  }

  void _toggleExpansion(String path) {
    setState(() {
      if (!_expandedPaths.remove(path)) _expandedPaths.add(path);
      _projectRows();
    });
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: widget.padding,
    itemCount: _rows.length,
    itemBuilder: (context, index) {
      final row = _rows[index];
      final path = row.node.track.relativePath;
      return AsmrDownloadNodeTile(
        key: ValueKey<String>('asmr_download_node_$path'),
        node: row.node,
        depth: row.depth,
        selection: widget.selection,
        expanded: _expandedPaths.contains(path),
        onToggleExpansion: () => _toggleExpansion(path),
        onSelectionChanged: widget.onSelectionChanged,
      );
    },
  );
}

class AsmrDownloadNodeTile extends ConsumerWidget {
  const AsmrDownloadNodeTile({
    super.key,
    required this.node,
    required this.depth,
    required this.selection,
    required this.expanded,
    required this.onToggleExpansion,
    required this.onSelectionChanged,
  });

  final AsmrDownloadSelectionNode node;
  final int depth;
  final AsmrDownloadSelectionModel selection;
  final bool expanded;
  final VoidCallback onToggleExpansion;
  final VoidCallback onSelectionChanged;

  static const double _indentWidth = 14;
  static const double _folderRowHeight = 44;
  static const double _fileRowHeight = 46;

  void _toggleSelection(bool? next) {
    selection.togglePath(node.track.relativePath, next);
    onSelectionChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    final folderRadius = BorderRadius.circular(tokens.radiusSmall);
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final value = selection.stateForPath(node.track.relativePath);
    final indent = _indentWidth * depth;

    if (node.track.isFolder) {
      final hasChildren = node.children.isNotEmpty;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: expanded,
            child: InkWell(
              onTap: onToggleExpansion,
              borderRadius: folderRadius,
              child: SizedBox(
                height: _folderRowHeight,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(start: indent, end: 2),
                  child: Row(
                    children: [
                      _CompactNodeCheckbox(
                        value: value,
                        onChanged: _toggleSelection,
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        expanded
                            ? Icons.folder_open_rounded
                            : Icons.folder_rounded,
                        size: 20,
                        color: asmrBlue.withValues(alpha: 0.8),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          node.track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                height: 1.06,
                                color: cs.onSurface.withValues(alpha: 0.9),
                              ),
                        ),
                      ),
                      if (hasChildren)
                        AnimatedRotation(
                          turns: expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            Icons.expand_more_rounded,
                            color: cs.onSurfaceVariant,
                            size: 20,
                          ),
                        )
                      else
                        const SizedBox(width: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (!hasChildren && expanded)
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: indent + _indentWidth + 40,
                end: 8,
                bottom: 4,
              ),
              child: Text(
                i18n.tr('asmr_download_empty_folder'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
        ],
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
                asmrDownloadFileIcon(node.track),
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
                      node.track.title,
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
                formatAsmrDownloadSize(node.track.size),
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
