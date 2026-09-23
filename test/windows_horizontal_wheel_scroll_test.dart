import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/windows_horizontal_wheel_scroll.dart';

void main() {
  testWidgets('Windows wheel scrolls a horizontal strip, then its parent', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final horizontal = ScrollController();
    final vertical = ScrollController();
    addTearDown(horizontal.dispose);
    addTearDown(vertical.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: vertical,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  key: const ValueKey('horizontal_region'),
                  width: 150,
                  height: 48,
                  child: WindowsHorizontalWheelScroll(
                    controller: horizontal,
                    builder: (controller) => ListView(
                      controller: controller,
                      scrollDirection: Axis.horizontal,
                      children: List.generate(
                        8,
                        (index) => SizedBox(width: 100, child: Text('$index')),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 1500),
            ],
          ),
        ),
      ),
    );

    final position = tester.getCenter(
      find.byKey(const ValueKey('horizontal_region')),
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();
    expect(horizontal.offset, greaterThan(0));
    expect(vertical.offset, 0);

    horizontal.jumpTo(horizontal.position.maxScrollExtent);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();
    expect(vertical.offset, greaterThan(0));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android wheel leaves the horizontal strip unchanged', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final horizontal = ScrollController();
    addTearDown(horizontal.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 150,
          height: 48,
          child: WindowsHorizontalWheelScroll(
            controller: horizontal,
            builder: (controller) => ListView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              children: List.generate(
                8,
                (index) => SizedBox(width: 100, child: Text('$index')),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(WindowsHorizontalWheelScroll)),
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pump();
    expect(horizontal.offset, 0);
    debugDefaultTargetPlatformOverride = null;
  });
}
