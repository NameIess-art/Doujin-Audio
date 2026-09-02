import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/player/presentation/timer_tab.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  testWidgets('timer tab loads reliability status without async setState', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build(const TimerTab(showHeader: false)));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('compact timer panels share a centered full-height layout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(
      fixture.build(
        const TimerTab(
          showHeader: false,
          useSafeArea: false,
          compactOnly: true,
        ),
      ),
    );
    await tester.pump();

    final panel = find.byKey(const ValueKey('timer_compact_panel'));
    final title = find.byKey(const ValueKey('timer_compact_title'));
    final setupPanelRect = tester.getRect(panel);
    final setupTitleRect = tester.getRect(title);
    expect(setupPanelRect.height, kTimerCompactPanelHeight);
    expect(
      tester.getRect(find.text('确认并立即开始')).bottom,
      lessThanOrEqualTo(setupPanelRect.bottom),
    );

    await tester.tap(find.text('确认并立即开始'));
    await tester.pump();
    await tester.pump();

    expect(find.text('倒计时进行中'), findsOneWidget);
    final detailPanelRect = tester.getRect(panel);
    final detailTitleRect = tester.getRect(title);
    expect(detailPanelRect.size, setupPanelRect.size);
    expect(detailTitleRect.left, setupTitleRect.left);

    fixture.timer.cancelTimer();
    await tester.pump();
  });
}
