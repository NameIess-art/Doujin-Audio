import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

Widget _page(
  String name,
  ValueNotifier<int> active, {
  int tabIndex = 0,
  ValueNotifier<int>? section,
  int sectionIndex = 0,
}) => switch (name) {
  'LibraryTab' => LibraryTab(
    tabIndex: tabIndex,
    activeTabIndexListenable: active,
    activeSectionListenable: section,
    sectionIndex: sectionIndex,
  ),
  'AsmrTab' => AsmrTab(
    tabIndex: tabIndex,
    activeTabIndexListenable: active,
    activeSectionListenable: section,
    sectionIndex: sectionIndex,
  ),
  'PlaylistTab' => PlaylistTab(
    tabIndex: tabIndex,
    activeTabIndexListenable: active,
  ),
  _ => throw ArgumentError.value(name),
};

void main() {
  setUp(() {
    UiInteractionCoordinator.instance.resetForTest();
    SharedPreferences.setMockInitialValues({
      AppPreferences.onboardingCompletedKey: true,
    });
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final name in ['LibraryTab', 'AsmrTab', 'PlaylistTab']) {
      testWidgets('$name ignores switches between other tabs on $platform', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        final active = ValueNotifier<int>(1);
        addTearDown(fixture.dispose);
        addTearDown(active.dispose);
        await tester.pumpWidget(fixture.build(_page(name, active)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final page = tester.element(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == name,
          ),
        );
        var builds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (identical(element, page)) builds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);

        for (final destination in [2, 3, 1]) {
          active.value = destination;
          await tester.pump();
        }
        expect(builds, 0);
        active.value = 0;
        await tester.pump();
        expect(builds, greaterThan(0));
        active.value = 1;
        await tester.pump();
        final hiddenBuilds = builds;
        active.value = 2;
        await tester.pump();
        expect(builds, hiddenBuilds);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        debugOnRebuildDirtyWidget = previous;
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('$name rebinds activity listenables on $platform', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        final oldActive = ValueNotifier<int>(1);
        final active = ValueNotifier<int>(2);
        addTearDown(fixture.dispose);
        addTearDown(oldActive.dispose);
        addTearDown(active.dispose);
        await tester.pumpWidget(fixture.build(_page(name, oldActive)));
        await tester.pump();
        final page = tester.element(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == name,
          ),
        );
        await tester.pumpWidget(fixture.build(_page(name, active)));
        await tester.pump();
        expect(tester.element(find.byWidget(page.widget)), same(page));

        oldActive.value = 0;
        expect(page.dirty, isFalse);
        active.value = 0;
        expect(page.dirty, isTrue);
        await tester.pump();
        await tester.pumpWidget(
          fixture.build(_page(name, active, tabIndex: 1)),
        );
        await tester.pump();
        active.value = 2;
        expect(page.dirty, isFalse);
        active.value = 1;
        expect(page.dirty, isTrue);
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  for (final name in ['LibraryTab', 'AsmrTab']) {
    testWidgets('$name rebinds sections and ignores other hidden sections', (
      tester,
    ) async {
      final fixture = AppRuntimeWidgetTestFixture();
      final active = ValueNotifier<int>(0);
      final oldSection = ValueNotifier<int>(1);
      final section = ValueNotifier<int>(2);
      addTearDown(fixture.dispose);
      addTearDown(active.dispose);
      addTearDown(oldSection.dispose);
      addTearDown(section.dispose);
      await tester.pumpWidget(
        fixture.build(_page(name, active, section: oldSection)),
      );
      await tester.pump();
      final page = tester.element(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == name,
        ),
      );
      oldSection.value = 2;
      expect(page.dirty, isFalse);
      await tester.pumpWidget(
        fixture.build(_page(name, active, section: section)),
      );
      await tester.pump();
      oldSection.value = 0;
      expect(page.dirty, isFalse);
      section.value = 0;
      expect(page.dirty, isTrue);
      await tester.pump();
      await tester.pumpWidget(
        fixture.build(_page(name, active, section: section, sectionIndex: 1)),
      );
      await tester.pump();
      section.value = 2;
      expect(page.dirty, isFalse);
      section.value = 1;
      expect(page.dirty, isTrue);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });
  }
}
