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

class _AsmrDownloadSelectionListState extends State<AsmrDownloadSelectionList>
    with SingleTickerProviderStateMixin {
  final Set<String> _expandedPaths = <String>{};
  Key _listKey = UniqueKey();
  List<({AsmrDownloadSelectionNode node, int depth})> _rows = const [];
  final Map<String, int> _rowIndices = {};
  late final AnimationController _expansionController;
  late final Animation<double> _opacity;
  late final Animation<double> _sizeFactor;
  String? _animatingPath;
  int _animationStart = 0;
  int _animationCount = 0;

  @override
  void initState() {
    super.initState();
    _expansionController = AnimationController(
      vsync: this,
      duration: kAppMotionStandard,
      value: 1,
    )..addStatusListener(_onAnimationStatus);
    _opacity = _expansionController.drive(
      CurveTween(curve: Curves.easeInOutCubic),
    );
    // A non-zero extent keeps the animated rows lazy even in large folders.
    _sizeFactor = _opacity.drive(Tween<double>(begin: 0.2, end: 1));
    _resetExpansion();
  }

  @override
  void didUpdateWidget(covariant AsmrDownloadSelectionList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection, widget.selection)) _resetExpansion();
  }

  void _resetExpansion() {
    _expansionController.stop();
    _animatingPath = null;
    _listKey = UniqueKey();
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
    _rowIndices.clear();
    for (var index = 0; index < rows.length; index++) {
      _rowIndices[rows[index].node.track.relativePath] = index;
    }
  }

  void _finishAnimation() {
    _expansionController.stop();
    _animatingPath = null;
    _projectRows();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (_animatingPath != null &&
        (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed)) {
      setState(_finishAnimation);
    }
  }

  void _toggleExpansion(String path) {
    setState(() {
      // Only the active subtree needs an animation range. Repeated clicks on
      // it reverse the same controller without remounting its rows.
      if (_animatingPath != null && _animatingPath != path) {
        _finishAnimation();
      }
      if (!_expandedPaths.remove(path)) _expandedPaths.add(path);
      if (MediaQuery.disableAnimationsOf(context)) {
        _finishAnimation();
        return;
      }
      final expanding = _expandedPaths.contains(path);
      if (_animatingPath != path) {
        final folderIndex = _rowIndices[path]!;
        final previousCount = _rows.length;
        if (expanding) _projectRows();
        _animationStart = folderIndex + 1;
        if (expanding) {
          _animationCount = _rows.length - previousCount;
        } else {
          final depth = _rows[folderIndex].depth;
          var end = _animationStart;
          while (end < _rows.length && _rows[end].depth > depth) {
            end++;
          }
          _animationCount = end - _animationStart;
        }
        if (_animationCount == 0) return;
        _expansionController.value = expanding ? 0 : 1;
        _animatingPath = path;
      }
      if (expanding) {
        _expansionController.forward();
      } else {
        _expansionController.reverse();
      }
    });
  }

  Widget _buildRow(int index) {
    final row = _rows[index];
    final path = row.node.track.relativePath;
    final animating =
        _animatingPath != null &&
        index >= _animationStart &&
        index < _animationStart + _animationCount;
    final collapsing = animating && !_expandedPaths.contains(_animatingPath);
    return SizeTransition(
      key: ValueKey<String>(path),
      sizeFactor: animating ? _sizeFactor : const AlwaysStoppedAnimation(1),
      axisAlignment: -1,
      child: FadeTransition(
        opacity: animating ? _opacity : const AlwaysStoppedAnimation(1),
        child: IgnorePointer(
          ignoring: collapsing,
          child: ExcludeSemantics(
            excluding: collapsing,
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
        ),
      ),
    );
  }

  @override
  void dispose() {
    _expansionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: _listKey,
    padding: widget.padding,
    itemCount: _rows.length,
    findChildIndexCallback: (key) =>
        _rowIndices[(key as ValueKey<String>).value],
    itemBuilder: (context, index) => _buildRow(index),
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
