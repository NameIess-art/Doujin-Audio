import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/app_bootstrap_controller.dart';
import 'package:nameless_audio/app/presentation/app_bootstrap_host.dart';
import 'package:nameless_audio/core/ui/app_icon_color_group.dart';
import 'package:nameless_audio/core/widgets/app_brand_icon.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('bootstrap attempts are single-flight', () async {
    final completer = Completer<void>();
    var attempts = 0;
    final controller = AppBootstrapController(
      initializer: () {
        attempts++;
        return completer.future;
      },
    );
    addTearDown(controller.dispose);

    final first = controller.initialize();
    final second = controller.retry();

    expect(attempts, 1);
    expect(controller.state.phase, AppBootstrapPhase.initializing);
    completer.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(controller.state.phase, AppBootstrapPhase.ready);
  });

  testWidgets('failed startup shows recovery shell and retry enters app', (
    tester,
  ) async {
    var attempts = 0;
    var appBuilds = 0;
    var bootstrapSettledCalls = 0;
    final controller = AppBootstrapController(
      initializer: () async {
        attempts++;
        if (attempts == 1) throw StateError('preferences unavailable');
      },
    );

    await tester.pumpWidget(
      AppBootstrapHost(
        controller: controller,
        locale: const Locale('zh'),
        onBootstrapSettled: () => bootstrapSettledCalls++,
        appBuilder: () {
          appBuilds++;
          return const MaterialApp(home: Text('ready app'));
        },
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('app_error_view')),
      findsOneWidget,
    );
    expect(find.text('Nameless Audio 启动失败'), findsOneWidget);
    expect(appBuilds, 0);
    expect(bootstrapSettledCalls, 1);

    await tester.tap(
      find.byKey(const ValueKey<String>('startup_retry_button')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('ready app'), findsOneWidget);
    expect(attempts, 2);
    expect(appBuilds, 1);
    expect(bootstrapSettledCalls, 1);
  });

  testWidgets('successful startup releases the native splash once', (
    tester,
  ) async {
    final initialization = Completer<void>();
    var bootstrapSettledCalls = 0;
    final controller = AppBootstrapController(
      initializer: () => initialization.future,
    );

    await tester.pumpWidget(
      AppBootstrapHost(
        controller: controller,
        locale: const Locale('en'),
        onBootstrapSettled: () => bootstrapSettledCalls++,
        appBuilder: () => const MaterialApp(home: Text('ready app')),
      ),
    );
    expect(bootstrapSettledCalls, 0);

    initialization.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('ready app'), findsOneWidget);
    expect(bootstrapSettledCalls, 1);
    await tester.pump();
    expect(bootstrapSettledCalls, 1);
  });

  testWidgets('startup diagnostics export failures stay in the error shell', (
    tester,
  ) async {
    var exportAttempts = 0;
    final controller = AppBootstrapController(
      initializer: () async => throw StateError('audio session unavailable'),
    );

    await tester.pumpWidget(
      AppBootstrapHost(
        controller: controller,
        locale: const Locale('en'),
        appBuilder: () => const SizedBox(),
        exportDiagnostics: () async {
          exportAttempts++;
          throw StateError('picker unavailable');
        },
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('error_export_diagnostics_button')),
    );
    await tester.pump();
    await tester.pump();

    expect(exportAttempts, 1);
    expect(
      find.byKey(const ValueKey<String>('app_error_view')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup shell follows dark platform brightness', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final pending = Completer<void>();
    final controller = AppBootstrapController(
      initializer: () => pending.future,
    );

    await tester.pumpWidget(
      AppBootstrapHost(
        controller: controller,
        locale: const Locale('en'),
        appBuilder: () => const SizedBox(),
      ),
    );

    final context = tester.element(
      find.byKey(const ValueKey<String>('app_bootstrap_loading')),
    );
    final theme = Theme.of(context);
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, const Color(0xFF211A1B));
  });

  testWidgets('startup shell follows the persisted icon color group', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'appThemeColor': 'mint',
      'themeMode': 'dark',
    });
    await AppPreferences.init();
    final pending = Completer<void>();
    final controller = AppBootstrapController(
      initializer: () => pending.future,
    );

    await tester.pumpWidget(
      AppBootstrapHost(
        controller: controller,
        locale: const Locale('en'),
        appBuilder: () => const SizedBox(),
      ),
    );

    expect(find.byType(AppBrandIcon), findsOneWidget);
    final context = tester.element(
      find.byKey(const ValueKey<String>('app_bootstrap_loading')),
    );
    expect(Theme.of(context).scaffoldBackgroundColor, const Color(0xFF12201C));
    expect(
      Theme.of(context).extension<AppBrandIconTheme>()?.gradient.colors,
      const <Color>[Color(0xFF2DD4BF), Color(0xFFA3E635)],
    );
  });
}
