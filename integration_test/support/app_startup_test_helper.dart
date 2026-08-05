import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/presentation/main_screen.dart';
import 'package:nameless_audio/app/presentation/onboarding_page.dart';

/// Starts the app while preserving Flutter test's process-wide error widget.
///
/// The production entry point installs its crash-safe [ErrorWidget.builder].
/// Flutter's test binding correctly treats that process-wide change as test
/// pollution unless the integration test restores its own builder at teardown.
Future<void> startAppForTest(
  Future<void> Function() start,
) async {
  final errorWidgetBuilder = ErrorWidget.builder;
  addTearDown(() {
    ErrorWidget.builder = errorWidgetBuilder;
  });
  await start();
}

Future<void> enterMainScreen(WidgetTester tester) async {
  await _waitForStartupWidget(tester);
  if (find.byType(OnboardingPage).evaluate().isNotEmpty) {
    await tester.tap(find.byType(FilledButton).first);
    await tester.pump();
  }
  await _waitForMainScreen(tester);
}

Future<void> _waitForStartupWidget(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (find.byType(OnboardingPage).evaluate().isEmpty &&
      find.byType(MainScreen).evaluate().isEmpty &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (find.byType(OnboardingPage).evaluate().isEmpty &&
      find.byType(MainScreen).evaluate().isEmpty) {
    throw TestFailure('app did not render onboarding or the main screen');
  }
}

Future<void> _waitForMainScreen(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (find.byType(MainScreen).evaluate().isEmpty &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    find.byType(MainScreen),
    findsOneWidget,
    reason: 'runtime startup did not reach the main screen within 45 seconds',
  );
}
