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
}
