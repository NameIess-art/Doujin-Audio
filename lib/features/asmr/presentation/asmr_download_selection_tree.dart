import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../application/asmr_download_selection.dart';
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
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
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
    _listKey = GlobalKey<AnimatedListState>();
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
    final previousRows = _rows;
    final folderIndex = _rows.indexWhere(
      (row) => row.node.track.relativePath == path,
    );
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kAppMotionStandard;
    setState(() {
      if (!_expandedPaths.remove(path)) _expandedPaths.add(path);
      _projectRows();
      final list = _listKey.currentState!;
      final count = _rows.length - previousRows.length;
      if (count > 0) {
        list.insertAllItems(folderIndex + 1, count, duration: duration);
      } else {
        for (var offset = -count; offset > 0; offset--) {
          final index = folderIndex + offset;
          final row = previousRows[index];
          list.removeItem(
            index,
            (context, animation) => IgnorePointer(
              child: ExcludeSemantics(child: _buildRow(row, animation)),
            ),
            duration: duration,
          );
        }
      }
    });
  }

  Widget _buildRow(
    ({AsmrDownloadSelectionNode node, int depth}) row,
    Animation<double> animation,
  ) {
    final path = row.node.track.relativePath;
    final opacity = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
    return SizeTransition(
      // A non-zero extent keeps insertion lazy even for very large folders.
      sizeFactor: opacity.drive(Tween<double>(begin: 0.2, end: 1)),
      axisAlignment: -1,
      child: FadeTransition(
        opacity: opacity,
        child: AsmrDownloadNodeTile(
          key: ValueKey<String>('asmr_download_node_$path'),
          node: row.node,
          depth: row.depth,
          selection: widget.selection,
          expanded: _expandedPaths.contains(path),
          onToggleExpansion: () => _toggleExpansion(path),
          onSelectionChanged: widget.onSelectionChanged,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedList(
    key: _listKey,
    padding: widget.padding,
    initialItemCount: _rows.length,
    itemBuilder: (context, index, animation) =>
        _buildRow(_rows[index], animation),
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

  void _toggleSelection(bool? next) {
    selection.togglePath(node.track.relativePath, next);
    onSelectionChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final value = selection.stateForPath(node.track.relativePath);
    final isFolder = node.track.isFolder;
    final hasChildren = node.children.isNotEmpty;
    final row = FileTreeRow(
      title: node.track.title,
      depth: depth,
      isFolder: isFolder,
      selectionControl: _CompactNodeCheckbox(
        value: value,
        onChanged: _toggleSelection,
      ),
      leading: Icon(
        isFolder
            ? expanded
                  ? AppDesignTokens.openFolderIcon
                  : AppDesignTokens.folderIcon
            : asmrDownloadFileIcon(node.track),
        size: AppDesignTokens.fileEntryIconSize,
        color: asmrDownloadFileColor(
          node.track,
          audioColor: asmrBlue,
          fallbackColor: cs.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              formatAsmrDownloadSize(node.totalSizeBytes),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (isFolder) ...[
            const SizedBox(width: 4),
            if (hasChildren)
              FileTreeExpansionArrow(expanded: expanded)
            else
              const SizedBox(width: 20),
          ],
        ],
      ),
      onTap: isFolder
          ? onToggleExpansion
          : () => _toggleSelection(value != true),
    );
    if (!isFolder) return row;
    return Semantics(
      expanded: expanded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row,
          if (!hasChildren && expanded)
            FileTreeRow(
              title: i18n.tr('asmr_download_empty_folder'),
              depth: depth,
              minHeight: 28,
              leading: const SizedBox(width: 62),
              titleColor: cs.onSurfaceVariant,
            ),
        ],
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
