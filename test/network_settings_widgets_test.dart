import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/network/network_route_settings.dart';
import 'package:doujin_audio/features/library/application/lan_media_server_service.dart';
import 'package:doujin_audio/features/library/domain/remote_media_source.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('LAN copy feedback includes the URL and keeps the PIN hidden', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final clipboard = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      fixture.build(
        const SettingsTab(),
        overrides: [
          lanMediaServerServiceProvider.overrideWith(
            (ref) => _RunningLanServer(
              library: fixture.library,
              syncService: ref.watch(crossPlatformSyncServiceProvider),
            ),
          ),
        ],
      ),
    );
    await pumpAndSettleWithAsync(tester);
    final i18n = fixture.languageProvider;
    final networkSection = find.text(i18n.tr('section_network'));
    await tester.ensureVisible(networkSection);
    await tester.tap(networkSection);
    await pumpAndSettleWithAsync(tester);

    Future<void> tapCopy(Finder button) async {
      await Scrollable.ensureVisible(tester.element(button), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    const url = 'http://192.0.2.10:42871';
    await tapCopy(find.widgetWithText(ActionChip, url));
    expect(clipboard, [url]);
    expect(
      find.text(i18n.tr('copied_to_clipboard', {'value': url})),
      findsOneWidget,
    );

    await tapCopy(find.byTooltip(i18n.tr('element_copy')));
    expect(clipboard, [url, '123456']);
    expect(find.text(i18n.tr('copied')), findsOneWidget);
    expect(find.textContaining('123456'), findsNothing);
    expect(find.textContaining('{value}'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'network settings edit proxy and DNS without overflow on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = platform == TargetPlatform.windows
            ? const Size(960, 600)
            : const Size(390, 780);
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
        final statusFontSize = tester.widget<RichText>(
          find.descendant(
            of: find.text(i18n.tr('network_untested')).first,
            matching: find.byType(RichText),
          ),
        ).text.style!.fontSize;
        void expectStatusFont(Finder labels) {
          expect(labels, findsNWidgets(3));
          final renderedLabels = tester.widgetList<RichText>(
            find.descendant(of: labels, matching: find.byType(RichText)),
          );
          expect(
            renderedLabels.map((label) => label.text.style?.fontSize).toList(),
            everyElement(statusFontSize),
          );
        }
        expectStatusFont(find.text(i18n.tr('network_untested')));
        HttpOverrides.runZoned(
          () {
            for (final button in tester.widgetList<FilledButton>(
              find.widgetWithText(FilledButton, i18n.tr('network_test')),
            )) {
              button.onPressed!();
            }
          },
          createHttpClient: (_) => _ProbeClient(),
        );
        await tester.pumpAndSettle();
        expectStatusFont(find.textContaining(RegExp(r'^\d+ ms$')));
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
        await tester.pump();
        final pinnedTop = tester.getTopLeft(inlineTitles.first).dy;
        expect(
          pinnedTop - tester.getRect(find.byType(TopPageHeader)).bottom,
          closeTo(8, 0.5),
        );
        expect(find.text(i18n.tr('network_site_tests')), findsOneWidget);
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
        final proxySlot = find.byKey(
          const ValueKey<String>('settings_section_slot_network_1'),
        );
        scroll.jumpTo(
          scroll.offset + tester.getTopLeft(proxySlot).dy - pinnedTop,
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: inlineTitles[1],
            matching: find.text(i18n.tr('network_proxy')),
          ),
          findsOneWidget,
        );
        expect(tester.getTopLeft(inlineTitles[1]).dy, closeTo(pinnedTop, 0.5));
        final apply = find.text(i18n.tr('network_apply_proxy'));
        await tester.ensureVisible(apply);
        await tester.tap(apply);
        await pumpAndSettleWithAsync(tester);
        expect(
          fixture.settings.networkRouteSettings.proxyMode,
          AppProxyMode.http,
        );
        expect(fixture.settings.networkRouteSettings.proxyPort, 8080);
        Future<void> tapDnsAction(Finder action) async {
          await Scrollable.ensureVisible(tester.element(action), alignment: 0.5);
          await tester.pumpAndSettle();
          await tester.tap(action);
        }

        await tester.ensureVisible(field('network_dns_ip'));
        await tester.enterText(field('network_dns_ip'), 'invalid');
        final applyDns = find.widgetWithText(
          FilledButton,
          i18n.tr('network_apply_dns'),
        );
        final resetDns = find.widgetWithText(
          TextButton,
          i18n.tr('network_reset_dns'),
        );
        final applyBounds = tester.getRect(applyDns);
        final resetBounds = tester.getRect(resetDns);
        expect(resetBounds.right, lessThan(applyBounds.left));
        expect(applyBounds.center.dy, closeTo(resetBounds.center.dy, 0.5));
        await tapDnsAction(applyDns);
        await tester.pumpAndSettle();
        expect(find.text(i18n.tr('network_invalid_value')), findsOneWidget);
        expect(fixture.settings.networkRouteSettings.customDnsServer, isEmpty);
        await tester.enterText(field('network_dns_ip'), '1.1.1.1');
        await tapDnsAction(applyDns);
        await pumpAndSettleWithAsync(tester);
        expect(
          fixture.settings.networkRouteSettings.customDnsServer,
          '1.1.1.1',
        );
        await tapDnsAction(resetDns);
        await pumpAndSettleWithAsync(tester);
        expect(fixture.settings.networkRouteSettings.customDnsServer, isEmpty);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}

class _RunningLanServer extends LanMediaServerService {
  _RunningLanServer({required super.library, required super.syncService});

  @override
  Future<void> initialize() async {}

  @override
  LanServerSettings get settings => const LanServerSettings(enabled: true);

  @override
  bool get isRunning => true;

  @override
  List<String> get localAddresses => const ['192.0.2.10'];

  @override
  String get accessCode => '123456';
}

class _ProbeClient extends Fake implements HttpClient {
  @override
  set connectionTimeout(Duration? value) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _ProbeRequest();

  @override
  void close({bool force = false}) {}
}

class _ProbeRequest extends Fake implements HttpClientRequest {
  @override
  HttpHeaders get headers => _ProbeHeaders();

  @override
  Future<HttpClientResponse> close() async => _ProbeResponse();
}

class _ProbeHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _ProbeResponse extends Fake implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.noContent;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final body = StreamController<List<int>>(onCancel: () async {});
    unawaited(body.close());
    return body.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
