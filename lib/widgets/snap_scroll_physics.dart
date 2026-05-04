import 'package:flutter/widgets.dart';

class SnapScrollPhysics extends PageScrollPhysics {
  const SnapScrollPhysics({super.parent});

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
    mass: 0.3,
    stiffness: 200.0,
    ratio: 1.1,
  );

  @override
  SnapScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return SnapScrollPhysics(parent: buildParent(ancestor));
  }
}
