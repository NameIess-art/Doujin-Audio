import 'package:flutter/material.dart';

/// Keeps the top bounce needed by pull-to-refresh while preventing content
/// from being dragged beyond the bottom edge.
class RefreshTopScrollPhysics extends BouncingScrollPhysics {
  const RefreshTopScrollPhysics({super.parent});

  @override
  RefreshTopScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return RefreshTopScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (value > position.pixels) {
      if (position.pixels >= position.maxScrollExtent) {
        return value - position.pixels;
      }
      if (value > position.maxScrollExtent) {
        return value - position.maxScrollExtent;
      }
    }
    return super.applyBoundaryConditions(position, value);
  }
}
