import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/app_bootstrap_controller.dart';
import 'package:nameless_audio/app/presentation/app_bootstrap_host.dart';

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

    await tester.tap(
      find.byKey(const ValueKey<String>('startup_retry_button')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('ready app'), findsOneWidget);
    expect(attempts, 2);
    expect(appBuilds, 1);
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
}
