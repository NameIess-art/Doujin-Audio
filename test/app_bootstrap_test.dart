import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/app_bootstrap_controller.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/app_bootstrap_host.dart';
import 'package:doujin_audio/app/presentation/onboarding_page.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/widgets/app_brand_icon.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
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
    expect(find.text('Doujin Audio 启动失败'), findsOneWidget);
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

  testWidgets('a preinitialized bootstrap gate does not restart its work', (
    tester,
  ) async {
    var attempts = 0;
    final controller = AppBootstrapController(
      initializer: () async {
        attempts++;
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AppBootstrapGate(
          controller: controller,
          disposeController: false,
          readyBuilder: (_) => const Text('ready'),
          loadingBuilder: (_) => const Text('loading'),
          failureBuilder: (_, _) => const Text('failure'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('ready'), findsOneWidget);
    expect(attempts, 1);
  });

  testWidgets(
    'fresh-install snapshot releases onboarding before pending runtime',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      final showOnboarding = AppPreferences.shouldShowOnboardingSync();
      await AppPreferences.completeOnboarding();
      expect(AppPreferences.shouldShowOnboardingSync(), isFalse);

      final runtimeInitialization = Completer<void>();
      var runtimeAttempts = 0;
      final runtimeController = AppBootstrapController(
        initializer: () {
          runtimeAttempts++;
          return runtimeInitialization.future;
        },
      );
      addTearDown(runtimeController.dispose);
      final language = AppLanguageProvider();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
          ],
          child: MaterialApp(
            home: OnboardingRuntimeGate(
              showOnboarding: showOnboarding,
              runtimeController: runtimeController,
              child: AppBootstrapGate(
                controller: runtimeController,
                disposeController: false,
                readyBuilder: (_) => const Text('runtime ready'),
                loadingBuilder: (_) => const Text('runtime loading'),
                failureBuilder: (_, _) => const Text('runtime failed'),
              ),
            ),
          ),
        ),
      );

      expect(find.text(language.tr('onboarding_title')), findsOneWidget);
      expect(find.text('runtime loading'), findsNothing);
      expect(runtimeAttempts, 0);
      await tester.pump();
      expect(runtimeAttempts, 1);
    },
  );

  testWidgets('existing install waits for the runtime settlement', (
    tester,
  ) async {
    final runtimeInitialization = Completer<void>();
    final runtimeController = AppBootstrapController(
      initializer: () => runtimeInitialization.future,
    );
    addTearDown(runtimeController.dispose);
    var runtimeSettledCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingRuntimeGate(
          showOnboarding: false,
          runtimeController: runtimeController,
          child: AppBootstrapGate(
            controller: runtimeController,
            disposeController: false,
            onBootstrapSettled: () => runtimeSettledCalls++,
            readyBuilder: (_) => const Text('runtime ready'),
            loadingBuilder: (_) => const Text('runtime loading'),
            failureBuilder: (_, _) => const Text('runtime failed'),
          ),
        ),
      ),
    );

    expect(find.text('runtime loading'), findsOneWidget);
    expect(runtimeSettledCalls, 0);

    runtimeInitialization.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('runtime ready'), findsOneWidget);
    expect(runtimeSettledCalls, 1);
  });

  testWidgets('runtime failure settles and exposes recovery UI', (
    tester,
  ) async {
    final runtimeController = AppBootstrapController(
      initializer: () async => throw StateError('runtime failed'),
    );
    addTearDown(runtimeController.dispose);
    var runtimeSettledCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingRuntimeGate(
          showOnboarding: false,
          runtimeController: runtimeController,
          child: AppBootstrapGate(
            controller: runtimeController,
            disposeController: false,
            onBootstrapSettled: () => runtimeSettledCalls++,
            readyBuilder: (_) => const Text('runtime ready'),
            loadingBuilder: (_) => const Text('runtime loading'),
            failureBuilder: (_, _) => const Text('runtime failed'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('runtime failed'), findsOneWidget);
    expect(runtimeSettledCalls, 1);
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
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).color,
      const Color(0xFF211A1B),
    );
    expect(find.byType(AppBrandIcon), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Starting Doujin Audio…'), findsNothing);
  });

  testWidgets('blank startup shell follows the persisted background color', (
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

    expect(find.byType(AppBrandIcon), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final context = tester.element(
      find.byKey(const ValueKey<String>('app_bootstrap_loading')),
    );
    expect(Theme.of(context).scaffoldBackgroundColor, const Color(0xFF12201C));
  });

  testWidgets('startup shell honors light appearance over dark system mode', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    SharedPreferences.setMockInitialValues(const <String, Object>{
      'appThemeColor': 'mint',
      'themeMode': 'light',
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

    final context = tester.element(
      find.byKey(const ValueKey<String>('app_bootstrap_loading')),
    );
    final theme = Theme.of(context);
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, const Color(0xFFF5FFF9));
  });
}
