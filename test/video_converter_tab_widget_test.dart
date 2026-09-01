import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/video_converter/presentation/video_converter_tab.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  testWidgets('video converter fixes its primary action above the safe area', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.build(const VideoConverterTab()));
    await tester.pumpAndSettle();

    final start = find.widgetWithText(
      FilledButton,
      fixture.languageProvider.tr('start_conversion'),
    );
    expect(start, findsOneWidget);
    final pageScaffold = find
        .ancestor(of: start, matching: find.byType(Scaffold))
        .first;
    expect(
      tester.getRect(start).bottom,
      closeTo(tester.getSize(pageScaffold).height - 16, 0.1),
    );
    final list = tester.widget<ListView>(
      find.descendant(of: pageScaffold, matching: find.byType(ListView)),
    );
    expect((list.padding! as EdgeInsets).bottom, greaterThanOrEqualTo(88));
  });
}
