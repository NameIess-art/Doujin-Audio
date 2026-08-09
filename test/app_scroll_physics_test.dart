import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_scroll_physics.dart';

FixedScrollMetrics _metrics(double pixels) {
  return FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 100,
    pixels: pixels,
    viewportDimension: 400,
    axisDirection: AxisDirection.down,
    devicePixelRatio: 1,
  );
}

void main() {
  test('refresh physics keeps top pull but clamps bottom overscroll', () {
    const physics = RefreshTopScrollPhysics();

    expect(physics.applyBoundaryConditions(_metrics(0), -24), 0);
    expect(physics.applyBoundaryConditions(_metrics(50), 64), 0);
    expect(physics.applyBoundaryConditions(_metrics(90), 112), 12);
    expect(physics.applyBoundaryConditions(_metrics(108), 120), 12);
  });
}
