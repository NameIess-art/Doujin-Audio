import 'package:flutter/widgets.dart';

class SnapScrollPhysics extends PageScrollPhysics {
  const SnapScrollPhysics({super.parent});

  @override
  double? get dragStartDistanceMotionThreshold => 18.0;

  @override
  double get minFlingDistance => 18.0;

  @override
  double get minFlingVelocity => 260.0;

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
    mass: 0.34,
    stiffness: 190.0,
    ratio: 1.06,
  );

  @override
  SnapScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return SnapScrollPhysics(parent: buildParent(ancestor));
  }
}
