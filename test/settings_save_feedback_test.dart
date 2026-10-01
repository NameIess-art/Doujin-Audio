import 'dart:async';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppLanguageProvider language;
  late UiOperationService operations;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    language = AppLanguageProvider();
    await language.initialized;
    operations = UiOperationService();
  });
  tearDown(() {
    language.dispose();
    operations.dispose();
  });
  Future<BuildContext> mount(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
          uiOperationServiceProvider.overrideWithValue(operations),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    return context;
  }

  testWidgets('save failure is caught and shown through existing feedback', (
    tester,
  ) async {
    final context = await mount(tester);
    expect(
      await saveSettingsWithFeedback(
        context,
        () async => throw StateError('write failed'),
      ),
      false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.textContaining(language.tr('operation_failed_retry')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('overlapping saves retain separate results', (tester) async {
    final context = await mount(tester);
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final scopes = <UiOperationScope>{};
    final subscription = operations.changes.listen(scopes.add);
    addTearDown(subscription.cancel);
    final first = saveSettingsWithFeedback(context, () => firstGate.future);
    final second = saveSettingsWithFeedback(context, () => secondGate.future);
    await tester.pump();
    expect(scopes, hasLength(2));
    expect(
      scopes.map(operations.operationFor).every((state) => state.isBusy),
      true,
    );
    secondGate.complete();
    await second;
    firstGate.complete();
    await first;
    expect(
      scopes.map(operations.operationFor).map((state) => state.phase),
      everyElement(UiOperationPhase.succeeded),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
