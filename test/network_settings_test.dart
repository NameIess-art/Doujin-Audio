import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/network/network_route_settings.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_media_sources.dart';
import 'package:doujin_audio/features/settings/application/network_service_probe.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _Store extends InMemorySharedPreferencesStore {
  _Store() : super.empty();
  bool fail = false;
  @override
  Future<bool> setValue(String type, String key, Object value) =>
      fail ? Future.value(false) : super.setValue(type, key, value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPreferences.init();
  });

  test(
    'obsolete source priority is ignored and removed when settings save',
    () async {
      await AppPreferences.writeJson('playback_settings_v1', {
        'preferredAsmrSource': 'japaneseAsmr',
      });
      final settings = SettingsRepository();
      addTearDown(settings.dispose);
      await settings.loadPersistedState(enforceCacheLimit: false);
      await settings.setAsmrApiDomain(asmrApiDomains[1]);
      final snapshot = await AppPreferences.snapshot();
      expect(jsonEncode(snapshot), isNot(contains('preferredAsmrSource')));
    },
  );

  test(
    'applying the same saved route retries a failed native synchronization',
    () async {
      var calls = 0;
      final settings = SettingsRepository(
        onNetworkRouteChanged: (_, _) async {
          if (++calls == 1) throw StateError('native unavailable');
        },
      );
      addTearDown(settings.dispose);
      const route = NetworkRouteSettings(
        proxyMode: AppProxyMode.http,
        proxyHost: '127.0.0.1',
        proxyPort: 8080,
      );
      await expectLater(
        settings.setNetworkRouteSettings(route),
        throwsStateError,
      );
      expect(settings.slice.state.networkRouteSettings, route);
      await settings.setNetworkRouteSettings(route);
      expect(calls, 2);
    },
  );

  test(
    'bracketed IPv6 proxy and DNS inputs are persisted in socket form',
    () async {
      final settings = SettingsRepository();
      addTearDown(settings.dispose);
      await settings.setNetworkRouteSettings(
        const NetworkRouteSettings(
          proxyMode: AppProxyMode.http,
          proxyHost: '[::1]',
          proxyPort: 8080,
          customDnsServer: '[2001:4860:4860::8888]',
        ),
      );
      expect(settings.networkRouteSettings.proxyHost, '::1');
      expect(
        settings.networkRouteSettings.customDnsServer,
        '2001:4860:4860::8888',
      );
    },
  );

  test(
    'route secrets stay out of preferences and restore before route callback',
    () async {
      String? secret;
      final applied = <(NetworkRouteSettings, String?)>[];
      final settings = SettingsRepository(
        readProxyPassword: () async => secret,
        writeProxyPassword: (value) async => secret = value,
        onNetworkRouteChanged: (route, password) async =>
            applied.add((route, password)),
      );
      addTearDown(settings.dispose);
      const route = NetworkRouteSettings(
        proxyMode: AppProxyMode.socks5,
        proxyHost: '127.0.0.1',
        proxyPort: 1080,
        proxyAuthenticationEnabled: true,
        proxyUsername: 'user',
      );
      await settings.setNetworkRouteSettings(route, password: 'secret-value');
      expect(applied.single.$2, 'secret-value');
      final snapshot = await AppPreferences.snapshot();
      expect(jsonEncode(snapshot), isNot(contains('secret-value')));
      expect(
        settings.slice.state.networkRouteSettings.proxyPasswordConfigured,
        isTrue,
      );
      await settings.setNetworkRouteSettings(
        settings.networkRouteSettings.copyWith(
          customDnsServer: '2001:4860:4860::8888',
        ),
        password: '',
      );
      expect(secret, 'secret-value');
      await settings.setAsmrApiDomain(asmrApiDomains[1]);

      final restarted = SettingsRepository(
        readProxyPassword: () async => secret,
        onNetworkRouteChanged: (route, password) async =>
            applied.add((route, password)),
      );
      addTearDown(restarted.dispose);
      await restarted.loadPersistedState(enforceCacheLimit: false);
      expect(restarted.networkRouteSettings, settings.networkRouteSettings);
      expect(restarted.asmrApiDomain, asmrApiDomains[1]);
      expect(applied.last.$2, 'secret-value');
    },
  );

  test(
    'restored proxy without a device secret stays selected and requires a new password',
    () async {
      final settings = SettingsRepository(readProxyPassword: () async => null);
      addTearDown(settings.dispose);
      await AppPreferences.writeJson('playback_settings_v1', {
        'networkRouteSettings': const NetworkRouteSettings(
          proxyMode: AppProxyMode.http,
          proxyHost: '127.0.0.1',
          proxyPort: 8080,
          proxyAuthenticationEnabled: true,
          proxyUsername: 'user',
          proxyPasswordConfigured: true,
        ).toJson(),
      });
      await settings.loadPersistedState(enforceCacheLimit: false);
      expect(settings.networkRouteSettings.proxyMode, AppProxyMode.http);
      expect(settings.networkRouteSettings.proxyPasswordConfigured, isFalse);
      expect(settings.networkRouteSettings.proxyAuthenticationEnabled, isTrue);
    },
  );

  test('failed preference commit restores route and secure password', () async {
    final store = _Store();
    SharedPreferencesStorePlatform.instance = store;
    String? secret = 'old';
    final settings = SettingsRepository(
      readProxyPassword: () async => secret,
      writeProxyPassword: (value) async => secret = value,
    );
    addTearDown(settings.dispose);
    const route = NetworkRouteSettings(
      proxyMode: AppProxyMode.http,
      proxyHost: 'localhost',
      proxyPort: 8080,
    );
    await settings.setNetworkRouteSettings(route, password: 'old');
    final before = settings.slice.state;
    store.fail = true;
    await expectLater(
      settings.setNetworkRouteSettings(
        route.copyWith(proxyPort: 8081),
        password: 'new',
      ),
      throwsStateError,
    );
    expect(secret, 'old');
    expect(settings.slice.state, before);
    store.fail = false;
    await settings.setNetworkRouteSettings(route.copyWith(proxyPort: 8082));
    expect(settings.networkRouteSettings.proxyPort, 8082);
  });

  test(
    'SOCKS5 credential limits count UTF-8 bytes before persisting',
    () async {
      String? secret;
      final settings = SettingsRepository(
        readProxyPassword: () async => secret,
        writeProxyPassword: (value) async => secret = value,
      );
      addTearDown(settings.dispose);
      const route = NetworkRouteSettings(
        proxyMode: AppProxyMode.socks5,
        proxyHost: '127.0.0.1',
        proxyPort: 1080,
        proxyAuthenticationEnabled: true,
        proxyUsername: '用户',
      );
      await expectLater(
        settings.setNetworkRouteSettings(route, password: '密' * 86),
        throwsFormatException,
      );
      expect(secret, isNull);
      expect(settings.networkRouteSettings, const NetworkRouteSettings());
      await expectLater(
        settings.setNetworkRouteSettings(
          route.copyWith(proxyUsername: '用' * 86),
          password: 'secret',
        ),
        throwsFormatException,
      );
      await settings.setNetworkRouteSettings(route, password: '密' * 85);
      expect(secret, '密' * 85);
    },
  );

  test('invalid proxy and DNS values never commit or apply', () async {
    var calls = 0;
    final settings = SettingsRepository(
      onNetworkRouteChanged: (_, _) async => calls++,
    );
    addTearDown(settings.dispose);
    await expectLater(
      settings.setNetworkRouteSettings(
        const NetworkRouteSettings(
          proxyMode: AppProxyMode.http,
          proxyHost: 'bad/path',
          proxyPort: 80,
        ),
      ),
      throwsFormatException,
    );
    await expectLater(
      settings.setNetworkRouteSettings(
        const NetworkRouteSettings(customDnsServer: 'dns.example'),
      ),
      throwsFormatException,
    );
    expect(calls, 0);
    expect(settings.networkRouteSettings, const NetworkRouteSettings());
  });

  test('site tests require 2xx and reset cancels stale results', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final pending = Completer<void>();
    server.listen((request) async {
      if (request.uri.path == '/pending') {
        pending.complete();
        return;
      }
      request.response.statusCode = request.uri.path == '/ok' ? 204 : 403;
      await request.response.close();
    });
    final probe = NetworkServiceProbe(
      createClient: () => _RealHttpOverrides().createHttpClient(null),
    );
    addTearDown(probe.dispose);
    Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
    await probe.test('one', uri('/ok'));
    expect(probe.result('one').status, NetworkProbeStatus.success);
    expect(probe.result('one').milliseconds, isNonNegative);
    await probe.test('two', uri('/forbidden'));
    expect(probe.result('two').status, NetworkProbeStatus.failed);
    expect(probe.result('one').status, NetworkProbeStatus.success);
    final test = probe.test('one', uri('/pending'));
    await pending.future;
    expect(probe.result('one').status, NetworkProbeStatus.testing);
    probe.reset();
    await test;
    expect(probe.result('one').status, NetworkProbeStatus.untested);
    expect(probe.result('two').status, NetworkProbeStatus.untested);
  });

  test('site test timeout reports failure and closes its connection', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((_) {});
    final probe = NetworkServiceProbe(
      createClient: () => _RealHttpOverrides().createHttpClient(null),
      timeout: const Duration(milliseconds: 50),
    );
    addTearDown(probe.dispose);
    await probe.test('slow', Uri.parse('http://127.0.0.1:${server.port}'));
    expect(probe.result('slow').status, NetworkProbeStatus.failed);
  });
}
