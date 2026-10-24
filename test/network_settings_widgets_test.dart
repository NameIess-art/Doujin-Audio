import 'package:doujin_audio/core/network/network_route_settings.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';
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
        final http = find.widgetWithText(ChoiceChip, 'HTTP');
        await tester.ensureVisible(http);
        await tester.tap(http);
        await tester.pumpAndSettle();
        Finder field(String key) => find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == i18n.tr(key),
        );
        await tester.enterText(field('network_proxy_host'), '127.0.0.1');
        await tester.enterText(field('network_proxy_port'), '8080');
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
