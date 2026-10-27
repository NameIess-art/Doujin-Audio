import 'package:doujin_audio/core/network/network_route_settings.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;
  setUpAll(
    () async => database = await AppRuntimeTestFixture.installSharedDatabase(),
  );
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'network settings edit proxy and DNS without overflow on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = platform == TargetPlatform.windows
            ? const Size(960, 600)
            : const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        await tester.pumpWidget(fixture.build(const SettingsTab()));
        await pumpAndSettleWithAsync(tester);
        final i18n = fixture.languageProvider;
        await tester.ensureVisible(find.text(i18n.tr('section_network')));
        await tester.tap(find.text(i18n.tr('section_network')));
        await pumpAndSettleWithAsync(tester);
        expect(find.text(i18n.tr('network_untested')), findsNWidgets(3));
        for (final site in ['DLsite', 'Japanese ASMR']) {
          final row = find.widgetWithText(ListTile, site);
          expect(tester.getSize(row).height, 64);
          expect(
            find.descendant(of: row, matching: find.byType(FilledButton)),
            findsOneWidget,
          );
        }
        expect(find.text('资源站点优先级'), findsNothing);
        final inlineTitles = [
          for (var index = 0; index < 3; index++)
            find.byKey(
              ValueKey<String>('settings_section_pill_network_$index'),
            ),
        ];
        for (final title in inlineTitles) {
          expect(title, findsOneWidget);
        }
        final categoryList = find.byType(ListView).last;
        final scroll = tester.widget<ListView>(categoryList).controller!;
        scroll.jumpTo(40);
        await tester.pumpAndSettle();
        final stickyTitle = find.byKey(
          const ValueKey<String>('settings_sticky_section_pill'),
        );
        expect(stickyTitle, findsOneWidget);
        expect(
          find.descendant(
            of: stickyTitle,
            matching: find.text(i18n.tr('network_site_tests')),
          ),
          findsOneWidget,
        );
        final pinnedTop = tester.getTopLeft(stickyTitle).dy;
        expect(
          pinnedTop - tester.getRect(find.byType(TopPageHeader)).bottom,
          closeTo(6, 0.5),
        );
        expect(
          tester
              .widget<Visibility>(
                find
                    .ancestor(
                      of: inlineTitles.first,
                      matching: find.byType(Visibility),
                    )
                    .first,
              )
              .visible,
          isFalse,
        );
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        final http = find.widgetWithText(ChoiceChip, 'HTTP');
        void expectPanelBackground(Finder control) {
          final card = find
              .ancestor(of: control, matching: find.byType(Card))
              .first;
          final fill = find.descendant(
            of: card,
            matching: find.byType(ColoredBox),
          );
          expect(fill, findsOneWidget);
          expect(
            tester.widget<ColoredBox>(fill).color,
            Theme.of(tester.element(card)).colorScheme.surfaceContainerLow,
          );
          expect(
            (tester.widget<Card>(card).shape! as RoundedRectangleBorder).side,
            BorderSide.none,
          );
        }
        expectPanelBackground(http);
        await tester.ensureVisible(http);
        await tester.tap(http);
        await tester.pumpAndSettle();
        Finder field(String key) => find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == i18n.tr(key),
        );
        expectPanelBackground(field('network_dns_ip'));
        await tester.enterText(field('network_proxy_host'), '127.0.0.1');
        await tester.enterText(field('network_proxy_port'), '8080');
        scroll.jumpTo(
          scroll.offset + tester.getTopLeft(inlineTitles[1]).dy - pinnedTop,
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: stickyTitle,
            matching: find.text(i18n.tr('network_proxy')),
          ),
          findsOneWidget,
        );
        expect(tester.getTopLeft(stickyTitle).dy, closeTo(pinnedTop, 0.5));
        final apply = find.text(i18n.tr('network_apply_proxy'));
        await tester.ensureVisible(apply);
        await tester.tap(apply);
        await pumpAndSettleWithAsync(tester);
        expect(
          fixture.settings.networkRouteSettings.proxyMode,
          AppProxyMode.http,
        );
        expect(fixture.settings.networkRouteSettings.proxyPort, 8080);
        await tester.ensureVisible(field('network_dns_ip'));
        await tester.enterText(field('network_dns_ip'), 'invalid');
        final applyDns = find.text(i18n.tr('network_apply_dns'));
        await tester.ensureVisible(applyDns);
        await tester.tap(applyDns);
        await tester.pumpAndSettle();
        expect(find.text(i18n.tr('network_invalid_value')), findsOneWidget);
        expect(fixture.settings.networkRouteSettings.customDnsServer, isEmpty);
        await tester.enterText(field('network_dns_ip'), '1.1.1.1');
        await tester.ensureVisible(applyDns);
        await tester.tap(applyDns);
        await pumpAndSettleWithAsync(tester);
        expect(
          fixture.settings.networkRouteSettings.customDnsServer,
          '1.1.1.1',
        );
        final reset = find.text(i18n.tr('network_reset_dns'));
        await tester.ensureVisible(reset);
        await tester.tap(reset);
        await pumpAndSettleWithAsync(tester);
        expect(fixture.settings.networkRouteSettings.customDnsServer, isEmpty);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
