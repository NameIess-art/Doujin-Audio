import 'dart:async';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';
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
  Future<BuildContext> mount(
    WidgetTester tester, {
    SettingsRepository? settings,
  }) async {
    late BuildContext context;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
          uiOperationServiceProvider.overrideWithValue(operations),
          if (settings != null)
            settingsRepositoryProvider.overrideWithValue(settings),
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

  testWidgets('search history undo survives leaving its requesting page', (
    tester,
  ) async {
    final settings = SettingsRepository()..syncSlice(isInitialized: true);
    addTearDown(() => unawaited(settings.dispose()));
    await settings.recordSearchQuery('Saved', online: false);
    final home = await mount(tester, settings: settings);
    late BuildContext searchContext;
    unawaited(
      Navigator.of(home).push(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, _, _) {
            searchContext = context;
            return const Scaffold();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await clearSearchHistoryWithFeedback(searchContext, online: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(language.tr('search_history_cleared')), findsOneWidget);
    Navigator.of(home).pop();
    await tester.pump();
    expect(searchContext.mounted, isFalse);
    await tester.tap(find.text('${language.tr('undo')} (5s)'));
    await tester.pumpAndSettle();
    expect(settings.slice.state.librarySearchHistory, ['Saved']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final online in [false, true]) {
    testWidgets(
      'search history undo counts down for 5 seconds (online: $online)',
      (tester) async {
        final settings = SettingsRepository()..syncSlice(isInitialized: true);
        addTearDown(() => unawaited(settings.dispose()));
        await settings.recordSearchQuery('Saved', online: online);
        final context = await mount(tester, settings: settings);
        await clearSearchHistoryWithFeedback(context, online: online);
        await tester.pump();
        expect(
          find.text(language.tr('search_history_cleared')),
          findsOneWidget,
        );
        for (var seconds = 5; seconds >= 1; seconds--) {
          expect(
            find.text('${language.tr('undo')} (${seconds}s)'),
            findsOneWidget,
          );
          await tester.pump(const Duration(seconds: 1));
        }
        // The deadline disables the action before the exit fade completes.
        await tester.tap(
          find.text('${language.tr('undo')} (1s)'),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('${language.tr('undo')} ('), findsNothing);
        expect(
          online
              ? settings.slice.state.asmrSearchHistory
              : settings.slice.state.librarySearchHistory,
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

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
