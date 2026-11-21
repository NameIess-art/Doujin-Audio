import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/widgets/file_tree_expansion_motion.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
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

typedef _DownloadSelectionRow = ({
  AsmrDownloadSelectionNode node,
  int depth,
  bool emptyFolder,
});

class _AsmrDownloadSelectionListState extends State<AsmrDownloadSelectionList>
    with SingleTickerProviderStateMixin {
  final Set<String> _expandedPaths = <String>{};
  Key _listKey = UniqueKey();
  List<_DownloadSelectionRow> _rows = const [];
  Map<Key, int> _rowIndices = const {};
  late final FileTreeExpansionMotion<String, _DownloadSelectionRow> _motion;

  @override
  void initState() {
    super.initState();
    _motion = FileTreeExpansionMotion(this, () {
      if (mounted) setState(_motion.finish);
    });
    _resetExpansion();
  }

  @override
  void didUpdateWidget(covariant AsmrDownloadSelectionList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection, widget.selection)) _resetExpansion();
  }

  void _resetExpansion() {
    _motion.finish();
    _listKey = UniqueKey();
    _expandedPaths
      ..clear()
      ..addAll(
        widget.selection.rootNodes.map((node) => node.track.relativePath),
      );
    _projectRows();
  }

  Key _rowKey(_DownloadSelectionRow row) {
    final path = row.node.track.relativePath;
    return row.emptyFolder ? ValueKey((path, 'empty')) : ValueKey(path);
  }

  Map<Key, int> _indicesFor(List<_DownloadSelectionRow> rows) => {
    for (var index = 0; index < rows.length; index++)
      _rowKey(rows[index]): index,
  };

  void _projectRows() {
    final rows = <_DownloadSelectionRow>[];
    void visit(AsmrDownloadSelectionNode node, int depth) {
      rows.add((node: node, depth: depth, emptyFolder: false));
      if (!_expandedPaths.contains(node.track.relativePath)) return;
      for (final child in node.children) {
        visit(child, depth + 1);
      }
      if (node.track.isFolder && node.children.isEmpty) {
        rows.add((node: node, depth: depth, emptyFolder: true));
      }
    }

    for (final root in widget.selection.rootNodes) {
      visit(root, 0);
    }
    _rows = rows;
    _rowIndices = _indicesFor(rows);
  }

  void _toggleExpansion(String path) {
    setState(() {
      final progress = _motion.progressFor(path);
      _motion.finish();
      final opening = !_expandedPaths.remove(path);
      if (opening) _expandedPaths.add(path);
      final outgoing = opening ? null : _rows;
      _projectRows();
      if (!MediaQuery.disableAnimationsOf(context)) {
        _motion.start(path, outgoing: outgoing, from: progress);
      }
    });
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _motion.project(
      context,
      _rows,
      parentIndex: (_, path) => _rowIndices[ValueKey<String>(path)],
      // The empty notice is visually aligned with the folder title.
      depth: (row) => row.depth + (row.emptyFolder ? 1 : 0),
      minRowHeight: 28,
    );
    final indices = identical(rows, _rows) ? _rowIndices : _indicesFor(rows);
    return ListView.builder(
      key: _listKey,
      padding: widget.padding,
      itemCount: rows.length,
      findChildIndexCallback: (key) => indices[key],
      itemBuilder: (context, index) {
        final row = rows[index];
        final path = row.node.track.relativePath;
        final tile = row.emptyFolder
            ? Consumer(
                builder: (context, ref, _) {
                  ref.watch(appLanguageStateProvider);
                  final i18n = ref.read(appLanguageProviderInstanceProvider);
                  return FileTreeRow(
                    title: i18n.tr('asmr_download_empty_folder'),
                    depth: row.depth,
                    minHeight: 28,
                    leading: const SizedBox(width: 56),
                    titleColor: Theme.of(context).colorScheme.onSurfaceVariant,
                  );
                },
              )
            : AsmrDownloadNodeTile(
                key: ValueKey<String>('asmr_download_node_$path'),
                node: row.node,
                depth: row.depth,
                selection: widget.selection,
                expanded: _expandedPaths.contains(path),
                onToggleExpansion: () => _toggleExpansion(path),
                onSelectionChanged: widget.onSelectionChanged,
              );
        return _motion.wrap(index, tile, key: _rowKey(row));
      },
    ).withWindowsSmoothScroll();
  }
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
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final value = selection.stateForPath(node.track.relativePath);
    final isFolder = node.track.isFolder;
    final hasChildren = node.children.isNotEmpty;
    final row = FileTreeRow(
      title: node.track.title,
      titleMaxLines: 2,
      depth: depth,
      horizontalPadding: 2,
      trailingSpacing: 4,
      isFolder: isFolder,
      selectionControl: _CompactNodeCheckbox(
        value: value,
        onChanged: _toggleSelection,
      ),
      leading: asmrDownloadFileLeading(context, node.track, expanded: expanded),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              node.hasUnknownSize
                  ? i18n.tr('asmr_download_size_unknown')
                  : formatMediaFileSize(node.totalSizeBytes),
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
    return Semantics(expanded: expanded, child: row);
  }
}

class _CompactNodeCheckbox extends StatelessWidget {
  const _CompactNodeCheckbox({required this.value, required this.onChanged});

  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    return SizedBox.square(
      dimension: 36,
      child: Checkbox(
        tristate: true,
        value: value,
        onChanged: onChanged,
        activeColor: primaryColor,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
