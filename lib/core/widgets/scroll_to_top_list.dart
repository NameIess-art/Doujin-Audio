import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A list whose distant return to the first two screens skips intermediate rows.
class ScrollToTopListView extends ListView {
  ScrollToTopListView.builder({
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
    required super.itemBuilder,
  }) : super.builder();

  @override
  Widget buildChildLayout(BuildContext context) =>
      itemExtent == null && itemExtentBuilder == null
      ? ScrollToTopSliverList(delegate: childrenDelegate)
      : super.buildChildLayout(context);
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
