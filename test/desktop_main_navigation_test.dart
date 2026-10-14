import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/desktop_main_navigation.dart';
import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'landscape rail motion leaves ${platform.name} content constraints stable',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await AppPreferences.init();
        final i18n = AppLanguageProvider();
        final activePage = ValueNotifier(0);
        final iconKeys = List.generate(4, (_) => GlobalKey());
        final iconLinks = List.generate(4, (_) => LayerLink());
        final destinations = resolveMainDestinations(
          showLocalLibrary: true,
          showAsmrOne: true,
        );
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          i18n.dispose();
          activePage.dispose();
        });
        var collapsed = false;
        var contentLayouts = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: Row(
                  children: [
                    DesktopMainNavigation(
                      i18n: i18n,
                      overlaySessions: const [],
                      destinations: destinations,
                      isMenuCollapsed: collapsed,
                      activePageIndex: activePage,
                      menuIconKeys: iconKeys,
                      menuIconLinks: iconLinks,
                      collapseOffset: (_, _) => Offset.zero,
                      onSwitchPage: (index) => activePage.value = index,
                      onToggleMenu: () => setState(() {
                        collapsed = !collapsed;
                      }),
                      playbackGeometryKey: GlobalKey(),
                      onReportPlaybackRect:
                          ({
                            required dockCollapsed,
                            required dockAreaWidth,
                            required expandedDockWidth,
                          }) {},
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          contentLayouts++;
                          return const ColoredBox(
                            key: ValueKey('content'),
                            color: Colors.white,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final target = find.byKey(iconKeys[MainDestinationType.library.index]);
        final toggle = find.widgetWithIcon(IconButton, Icons.menu_open_rounded);
        expect(tester.getSize(target), tester.getSize(toggle));
        final center = tester.getCenter(target);
        for (final offset in [
          const Offset(25, 0),
          const Offset(-25, 0),
          const Offset(0, 25),
          const Offset(0, -25),
        ]) {
          await tester.tapAt(center + offset);
          await tester.pumpAndSettle();
          expect(activePage.value, 0);
        }
        await tester.tapAt(center + const Offset(23, 23));
        await tester.pumpAndSettle();
        expect(activePage.value, 1);

        for (final icon in [Icons.menu_open_rounded, Icons.menu_rounded]) {
          await tester.tap(find.byIcon(icon));
          await tester.pump();
          final transitionLayouts = contentLayouts;
          final contentWidth = tester
              .getSize(find.byKey(const ValueKey('content')))
              .width;
          expect(contentWidth, collapsed ? 1200 : 1020);
          expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
          for (var frame = 0; frame < 5; frame++) {
            await tester.pump(const Duration(milliseconds: 30));
            expect(contentLayouts, transitionLayouts);
            expect(
              tester.getSize(find.byKey(const ValueKey('content'))).width,
              contentWidth,
            );
          }
          await tester.pumpAndSettle();
          final otherTarget = find.byKey(
            iconKeys[MainDestinationType.settings.index],
          );
          final otherCenter = tester.getCenter(otherTarget);
          for (final offset in [
            const Offset(25, 0),
            const Offset(-25, 0),
            const Offset(0, 25),
            const Offset(0, -25),
          ]) {
            await tester.tapAt(otherCenter + offset);
            await tester.pumpAndSettle();
            expect(activePage.value, 1);
          }
          if (!collapsed) {
            final rail = tester.widget<NavigationRail>(
              find.byType(NavigationRail),
            );
            await tester.tap(find.byWidget(rail.destinations.last.label));
            await tester.pumpAndSettle();
            expect(activePage.value, destinations.length - 1);
            activePage.value = 1;
            await tester.pumpAndSettle();
          }
          final nextToggle = find.widgetWithIcon(
            IconButton,
            collapsed ? Icons.menu_rounded : Icons.menu_open_rounded,
          );
          expect(tester.getSize(target), tester.getSize(nextToggle));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
        expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
