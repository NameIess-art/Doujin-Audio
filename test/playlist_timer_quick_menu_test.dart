import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  testWidgets(
    'opening timer settings waits for the quick menu to finish closing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      var openedTimerSettings = 0;

      await tester.pumpWidget(
        fixture.build(PlaylistTab(onTimerTap: () => openedTimerSettings++)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final quickMenuTrigger = find.ancestor(
        of: find.byTooltip(fixture.languageProvider.tr('timer')),
        matching: find.byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.onLongPress != null,
        ),
      );
      expect(quickMenuTrigger, findsOneWidget);
      tester.widget<GestureDetector>(quickMenuTrigger).onLongPress!();
      await tester.pump(const Duration(milliseconds: 400));
      final setCountdown = tester.widget<ActionChip>(
        find.widgetWithText(
          ActionChip,
          fixture.languageProvider.tr('set_countdown'),
        ),
      );
      setCountdown.onPressed!();
      await tester.pump();

      expect(openedTimerSettings, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(openedTimerSettings, 0);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(openedTimerSettings, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
