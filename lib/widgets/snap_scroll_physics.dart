import 'package:flutter/widgets.dart';

class SnapScrollPhysics extends PageScrollPhysics {
  const SnapScrollPhysics({super.parent});

  static const double _dragThresholdFraction = 0.08;
  static const double _minPageTurnVelocity = 200.0;
  static const double _minPageTurnDistance = 20.0;

  @override
  double? get dragStartDistanceMotionThreshold => 12.0;

  @override
  double get minFlingDistance => _minPageTurnDistance;

  @override
  double get minFlingVelocity => _minPageTurnVelocity;

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

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }

    final double viewportFraction =
        (position is PageMetrics) ? position.viewportFraction : 1.0;
    final double pageExtent = position.viewportDimension * viewportFraction;

    final tolerance = toleranceFor(position);
    final page = position.pixels / pageExtent;
    final basePage = page.roundToDouble();
    final displacement = position.pixels - (basePage * pageExtent);
    final dragThreshold = pageExtent * _dragThresholdFraction;
    final distanceMet =
        displacement.abs() >= dragThreshold &&
        displacement.abs() >= _minPageTurnDistance;
    final velocityMet = velocity.abs() >= _minPageTurnVelocity;
    final sameDirection =
        displacement == 0 ||
        velocity == 0 ||
        displacement.sign == velocity.sign;

    if (!(distanceMet && velocityMet && sameDirection)) {
      final targetPixels = basePage * pageExtent;
      if ((targetPixels - position.pixels).abs() < tolerance.distance &&
          velocity.abs() < tolerance.velocity) {
        return null;
      }
      return ScrollSpringSimulation(
        spring,
        position.pixels,
        targetPixels,
        velocity,
        tolerance: tolerance,
      );
    }

    return super.createBallisticSimulation(position, velocity);
  }
}
