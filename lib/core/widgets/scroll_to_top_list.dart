import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Skips intermediate rows when jumping to the top or using known offsets.
class ScrollToTopListView extends ListView {
  ScrollToTopListView.builder({
    this.rowOffsets,
    super.key,
    super.controller,
    super.physics,
    super.padding,
    super.cacheExtent,
    super.clipBehavior,
    super.keyboardDismissBehavior,
    super.itemCount,
    super.itemExtent,
    super.itemExtentBuilder,
    super.findChildIndexCallback,
    super.addRepaintBoundaries,
    required super.itemBuilder,
  }) : assert(rowOffsets == null || itemExtentBuilder != null),
       super.builder();

  /// Offsets start at zero and include the end of the last row.
  final List<double>? rowOffsets;

  @override
  Widget buildChildLayout(BuildContext context) {
    final offsets = rowOffsets;
    if (offsets != null && offsets.length > 1) {
      return _IndexedExtentSliver(
        delegate: childrenDelegate,
        itemExtentBuilder: itemExtentBuilder!,
        offsets: offsets,
      );
    }
    return itemExtent == null && itemExtentBuilder == null
        ? ScrollToTopSliverList(delegate: childrenDelegate)
        : super.buildChildLayout(context);
  }
}

class ScrollToTopSliverList extends SliverList {
  const ScrollToTopSliverList({super.key, required super.delegate});

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _ScrollToTopRenderSliverList(
        childManager: context as SliverMultiBoxAdaptorElement,
      );
}

class _ScrollToTopRenderSliverList extends RenderSliverList {
  _ScrollToTopRenderSliverList({required super.childManager});

  @override
  void performLayout() {
    final first = firstChild;
    final firstOffset = first == null ? null : childScrollOffset(first);
    if (firstOffset != null &&
        constraints.scrollOffset <= constraints.viewportMainAxisExtent * 2 &&
        firstOffset >
            constraints.scrollOffset + constraints.remainingCacheExtent) {
      // RenderSliverList otherwise walks backwards from the old first child,
      // building every skipped row. Restart near the origin for a bounded
      // return; normal garbage collection preserves requested keep-alives.
      collectGarbage(childCount, 0);
    }
    super.performLayout();
  }
}

class _IndexedExtentSliver extends SliverVariedExtentList {
  const _IndexedExtentSliver({
    required super.delegate,
    required super.itemExtentBuilder,
    required this.offsets,
  });

  final List<double> offsets;

  @override
  RenderSliverVariedExtentList createRenderObject(BuildContext context) =>
      _IndexedExtentRenderer(
        childManager: context as SliverMultiBoxAdaptorElement,
        itemExtentBuilder: itemExtentBuilder,
        offsets: offsets,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _IndexedExtentRenderer renderObject,
  ) {
    super.updateRenderObject(context, renderObject);
    renderObject.offsets = offsets;
  }
}

// Flutter's varied-extent sliver scans from row zero for every offset lookup.
// Precomputed offsets give O(1) position and O(log n) index lookups.
class _IndexedExtentRenderer extends RenderSliverVariedExtentList {
  _IndexedExtentRenderer({
    required super.childManager,
    required super.itemExtentBuilder,
    required List<double> offsets,
  }) : _offsets = offsets;

  List<double> _offsets;

  set offsets(List<double> value) {
    if (identical(value, _offsets)) return;
    _offsets = value;
    markNeedsLayout();
  }

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      _offsets[index.clamp(0, _offsets.length - 1)];

  int _indexForOffset(double scrollOffset, {required bool includeBoundary}) {
    var low = 0;
    var high = _offsets.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_offsets[middle] < scrollOffset ||
          (includeBoundary && _offsets[middle] == scrollOffset)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return (low - 1).clamp(0, _offsets.length - 2);
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _indexForOffset(scrollOffset, includeBoundary: true);

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _indexForOffset(scrollOffset, includeBoundary: false);

  @override
  double computeMaxScrollOffset(
    SliverConstraints constraints,
    double itemExtent,
  ) => _offsets.last;

  @override
  double estimateMaxScrollOffset(
    SliverConstraints constraints, {
    int? firstIndex,
    int? lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  }) => _offsets.last;
}
