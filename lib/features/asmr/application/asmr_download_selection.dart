import 'dart:collection';

import '../../../core/immutable_collections.dart';
import '../domain/asmr_models.dart';

enum AsmrDownloadFileGroup { all, image, mp3, wav, txt, pdf }

class AsmrDownloadSelectionModel {
  AsmrDownloadSelectionModel(List<AsmrTrackFile> roots)
    : rootNodes = immutableList(
        roots.map(AsmrDownloadSelectionNode.fromTrack),
      ) {
    for (final root in rootNodes) {
      _index(root);
    }
  }

  final List<AsmrDownloadSelectionNode> rootNodes;
  final Map<String, AsmrDownloadSelectionNode> _nodesByPath =
      <String, AsmrDownloadSelectionNode>{};
  final _filesByGroup =
      <AsmrDownloadFileGroup, Set<AsmrDownloadSelectionNode>>{};
  ({int leafCount, int totalSizeBytes, bool hasUnknownSize})? _cachedSummary;

  bool? stateForPath(String path) => _nodesByPath[path]?.checkboxValue;

  void togglePath(String path, bool? nextValue) {
    final node = _nodesByPath[path];
    if (node == null) return;
    final shouldSelect = nextValue ?? !node.selected;
    _cachedSummary = null;
    _setSubtree(node, shouldSelect);
    _rebuildAncestorState(node.parent);
  }

  /// Returns null when the group has no files to select.
  bool? groupSelection(AsmrDownloadFileGroup group) {
    if (group == AsmrDownloadFileGroup.all) {
      if (!rootNodes.any((node) => node.totalLeafCount > 0)) return null;
      return rootNodes.every((node) => node.selected);
    }
    return _filesByGroup[group]?.every((node) => node.selected);
  }

  void toggleGroup(AsmrDownloadFileGroup group) {
    if (group == AsmrDownloadFileGroup.all) {
      final selected = groupSelection(group);
      if (selected == true) clearAll();
      if (selected == false) selectAll();
      return;
    }
    final files = _filesByGroup[group];
    if (files == null) return;
    final shouldSelect = files.any((node) => !node.selected);
    _cachedSummary = null;
    for (final root in rootNodes) {
      _setGroupSelection(root, files, shouldSelect);
    }
  }

  List<AsmrTrackFile> selectedDownloadRoots() {
    final result = <AsmrTrackFile>[];
    for (final node in rootNodes) {
      _collectSelectedRoots(node, result);
    }
    return List<AsmrTrackFile>.unmodifiable(result);
  }

  ({int leafCount, int totalSizeBytes, bool hasUnknownSize}) selectedSummary() {
    final cached = _cachedSummary;
    if (cached != null) return cached;
    var leafCount = 0;
    var totalSizeBytes = 0;
    var hasUnknownSize = false;
    void visit(AsmrDownloadSelectionNode node) {
      if (node.selected) {
        leafCount += node.totalLeafCount;
        totalSizeBytes += node.totalSizeBytes;
        if (node.hasUnknownSize) hasUnknownSize = true;
        return;
      }
      if (!node.indeterminate) return;
      for (final child in node.children) {
        visit(child);
      }
    }

    for (final node in rootNodes) {
      visit(node);
    }
    return _cachedSummary = (
      leafCount: leafCount,
      totalSizeBytes: totalSizeBytes,
      hasUnknownSize: hasUnknownSize,
    );
  }

  int selectedLeafCount() {
    var count = 0;
    for (final node in rootNodes) {
      count += _countSelectedLeaves(node);
    }
    return count;
  }

  int selectedTotalSizeBytes() {
    var bytes = 0;
    for (final node in rootNodes) {
      bytes += _selectedSizeBytes(node);
    }
    return bytes;
  }

  void selectAll() {
    _cachedSummary = null;
    for (final node in rootNodes) {
      _setSubtree(node, true);
    }
  }

  bool selectedHasUnknownSize() {
    bool visit(AsmrDownloadSelectionNode node) => node.selected
        ? node.hasUnknownSize
        : node.indeterminate && node.children.any(visit);
    return rootNodes.any(visit);
  }

  void clearAll() {
    _cachedSummary = null;
    for (final node in rootNodes) {
      _setSubtree(node, false);
    }
  }

  void _index(AsmrDownloadSelectionNode node) {
    _nodesByPath[node.track.relativePath] = node;
    if (!node.track.isFolder) {
      if (node.track.isImage) {
        (_filesByGroup[AsmrDownloadFileGroup.image] ??= {}).add(node);
      }
      final group = switch (node.track.resolvedExtension) {
        '.mp3' => AsmrDownloadFileGroup.mp3,
        '.wav' => AsmrDownloadFileGroup.wav,
        '.txt' => AsmrDownloadFileGroup.txt,
        '.pdf' => AsmrDownloadFileGroup.pdf,
        _ => null,
      };
      if (group != null) (_filesByGroup[group] ??= {}).add(node);
    }
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
      _rebuildNodeState(node);
      node = node.parent;
    }
  }

  bool _setGroupSelection(
    AsmrDownloadSelectionNode node,
    Set<AsmrDownloadSelectionNode> files,
    bool selected,
  ) {
    if (node.children.isEmpty) {
      if (!files.contains(node) || node.selected == selected) return false;
      node.selected = selected;
      return true;
    }
    var changed = false;
    for (final child in node.children) {
      if (_setGroupSelection(child, files, selected)) changed = true;
    }
    // Update each affected folder once, after all its children have been updated.
    if (changed) _rebuildNodeState(node);
    return changed;
  }

  void _rebuildNodeState(AsmrDownloadSelectionNode node) {
    if (node.children.isEmpty) {
      node.indeterminate = false;
      return;
    }
    node.selected = node.children.every((child) => child.selected);
    node.indeterminate =
        !node.selected &&
        node.children.any((child) => child.selected || child.indeterminate);
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
      return node.totalLeafCount;
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

  int _selectedSizeBytes(AsmrDownloadSelectionNode node) {
    if (node.selected) {
      return node.totalSizeBytes;
    }
    if (!node.indeterminate) {
      return 0;
    }
    var bytes = 0;
    for (final child in node.children) {
      bytes += _selectedSizeBytes(child);
    }
    return bytes;
  }
}

class AsmrDownloadSelectionNode {
  AsmrDownloadSelectionNode({
    required this.track,
    required List<AsmrDownloadSelectionNode> children,
    this.parent,
    this.selected = false,
    this.indeterminate = false,
  }) : _children = children {
    this.children = UnmodifiableListView<AsmrDownloadSelectionNode>(_children);
  }

  factory AsmrDownloadSelectionNode.fromTrack(
    AsmrTrackFile track, {
    AsmrDownloadSelectionNode? parent,
  }) {
    final node = AsmrDownloadSelectionNode(
      track: track,
      parent: parent,
      children: <AsmrDownloadSelectionNode>[],
    );
    node._children.addAll(
      track.children
          .map(
            (child) => AsmrDownloadSelectionNode.fromTrack(child, parent: node),
          )
          .toList(growable: false),
    );
    return node;
  }

  final AsmrTrackFile track;
  final List<AsmrDownloadSelectionNode> _children;
  late final List<AsmrDownloadSelectionNode> children;
  late final int totalLeafCount = track.isFolder
      ? children.fold<int>(0, (count, child) => count + child.totalLeafCount)
      : 1;
  late final int totalSizeBytes = track.isFolder
      ? children.fold<int>(0, (bytes, child) => bytes + child.totalSizeBytes)
      : track.size;
  late final bool hasUnknownSize = track.isFolder
      ? children.any((child) => child.hasUnknownSize)
      : track.size <= 0;
  AsmrDownloadSelectionNode? parent;
  bool selected;
  bool indeterminate;

  bool? get checkboxValue => indeterminate ? null : selected;
}
