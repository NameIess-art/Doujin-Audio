import '../models/asmr_models.dart';

class AsmrDownloadSelectionModel {
  AsmrDownloadSelectionModel(List<AsmrTrackFile> roots)
    : rootNodes = roots.map(AsmrDownloadSelectionNode.fromTrack).toList(
        growable: false,
      ) {
    for (final root in rootNodes) {
      _index(root);
    }
  }

  final List<AsmrDownloadSelectionNode> rootNodes;
  final Map<String, AsmrDownloadSelectionNode> _nodesByPath =
      <String, AsmrDownloadSelectionNode>{};

  bool? stateForPath(String path) => _nodesByPath[path]?.checkboxValue;

  void togglePath(String path, bool? nextValue) {
    final node = _nodesByPath[path];
    if (node == null) return;
    final shouldSelect = nextValue ?? !node.selected;
    _setSubtree(node, shouldSelect);
    _rebuildAncestorState(node.parent);
  }

  List<AsmrTrackFile> selectedDownloadRoots() {
    final result = <AsmrTrackFile>[];
    for (final node in rootNodes) {
      _collectSelectedRoots(node, result);
    }
    return List<AsmrTrackFile>.unmodifiable(result);
  }

  int selectedLeafCount() {
    var count = 0;
    for (final node in rootNodes) {
      count += _countSelectedLeaves(node);
    }
    return count;
  }

  void selectAll() {
    for (final node in rootNodes) {
      _setSubtree(node, true);
    }
  }

  void clearAll() {
    for (final node in rootNodes) {
      _setSubtree(node, false);
    }
  }

  void _index(AsmrDownloadSelectionNode node) {
    _nodesByPath[node.track.relativePath] = node;
    for (final child in node.children) {
      _index(child);
    }
  }

  void _setSubtree(AsmrDownloadSelectionNode node, bool selected) {
    node.selected = selected;
    node.indeterminate = false;
    for (final child in node.children) {
      _setSubtree(child, selected);
    }
  }

  void _rebuildAncestorState(AsmrDownloadSelectionNode? node) {
    while (node != null) {
      if (node.children.isEmpty) {
        node.indeterminate = false;
      } else {
        final allSelected = node.children.every((child) => child.selected);
        final anySelected = node.children.any(
          (child) => child.selected || child.indeterminate,
        );
        node.selected = allSelected;
        node.indeterminate = !allSelected && anySelected;
      }
      node = node.parent;
    }
  }

  void _collectSelectedRoots(
    AsmrDownloadSelectionNode node,
    List<AsmrTrackFile> result,
  ) {
    if (node.selected) {
      result.add(node.track);
      return;
    }
    if (!node.indeterminate) {
      return;
    }
    for (final child in node.children) {
      _collectSelectedRoots(child, result);
    }
  }

  int _countSelectedLeaves(AsmrDownloadSelectionNode node) {
    if (node.selected) {
      return node.track.isFolder ? _countAllLeaves(node) : 1;
    }
    if (!node.indeterminate) {
      return 0;
    }
    var count = 0;
    for (final child in node.children) {
      count += _countSelectedLeaves(child);
    }
    return count;
  }

  int _countAllLeaves(AsmrDownloadSelectionNode node) {
    if (node.children.isEmpty) {
      return node.track.isFolder ? 0 : 1;
    }
    var count = 0;
    for (final child in node.children) {
      count += _countAllLeaves(child);
    }
    return count;
  }
}

class AsmrDownloadSelectionNode {
  AsmrDownloadSelectionNode({
    required this.track,
    required this.children,
    this.parent,
    this.selected = false,
    this.indeterminate = false,
  });

  factory AsmrDownloadSelectionNode.fromTrack(
    AsmrTrackFile track, {
    AsmrDownloadSelectionNode? parent,
  }) {
    final node = AsmrDownloadSelectionNode(
      track: track,
      parent: parent,
      children: <AsmrDownloadSelectionNode>[],
    );
    node.children.addAll(
      track.children
          .map((child) => AsmrDownloadSelectionNode.fromTrack(child, parent: node))
          .toList(growable: false),
    );
    return node;
  }

  final AsmrTrackFile track;
  final List<AsmrDownloadSelectionNode> children;
  AsmrDownloadSelectionNode? parent;
  bool selected;
  bool indeterminate;

  bool? get checkboxValue => indeterminate ? null : selected;
}
