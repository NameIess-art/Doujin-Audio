import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/state/audio_provider_riverpod.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';
import 'package:nameless_audio/features/data_support/presentation/data_support_page.dart';
import 'package:provider/provider.dart' as legacy_provider;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cardKeys = <ValueKey<String>>[
    ValueKey('data-support-export-backup'),
    ValueKey('data-support-restore-backup'),
    ValueKey('data-support-export-diagnostics'),
    ValueKey('data-support-privacy-summary'),
  ];
  final operationService = UiOperationService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    operationService.clear(UiOperationScope.dataSupportBackupExport);
    operationService.clear(UiOperationScope.dataSupportBackupRestore);
    operationService.clear(UiOperationScope.dataSupportDiagnosticsExport);
  });

  tearDown(() {
    operationService.clear(UiOperationScope.dataSupportBackupExport);
    operationService.clear(UiOperationScope.dataSupportBackupRestore);
    operationService.clear(UiOperationScope.dataSupportDiagnosticsExport);
  });

  testWidgets(
    'busy progress keeps every data-support card and Ink response in place',
    (tester) async {
      final languageProvider = AppLanguageProvider();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(
              languageProvider,
            ),
          ],
          child:
              legacy_provider.ChangeNotifierProvider<AppLanguageProvider>.value(
                value: languageProvider,
                child: const MaterialApp(home: DataSupportPage()),
              ),
        ),
      );
      await tester.pump();

      final cardElements = <Key, Element>{};
      final inkElements = <Key, Element>{};
      final cardOffsets = <Key, Offset>{};
      for (final key in cardKeys) {
        final card = find.byKey(key);
        cardElements[key] = tester.element(card);
        inkElements[key] = tester.element(
          find.descendant(of: card, matching: find.byType(InkWell)),
        );
        cardOffsets[key] = tester.getTopLeft(card);
      }

      const operations = <(UiOperationScope, ValueKey<String>, String)>[
        (
          UiOperationScope.dataSupportBackupRestore,
          ValueKey('data-support-restore-backup'),
          'restore_backup',
        ),
        (
          UiOperationScope.dataSupportDiagnosticsExport,
          ValueKey('data-support-export-diagnostics'),
          'export_diagnostics',
        ),
      ];
      for (final (scope, busyCardKey, labelKey) in operations) {
        final pending = Completer<void>();
        final operation = operationService.run<void>(
          scope: scope,
          labelKey: labelKey,
          task: (_) => pending.future,
          cancelPrevious: false,
        );
        expect(operationService.operationFor(scope).isBusy, isTrue);
        await tester.pump();
        await tester.pump();

        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        for (final key in cardKeys) {
          final card = find.byKey(key);
          expect(tester.element(card), same(cardElements[key]));
          expect(
            tester.element(
              find.descendant(of: card, matching: find.byType(InkWell)),
            ),
            same(inkElements[key]),
          );
          expect(tester.getTopLeft(card), cardOffsets[key]);
          expect(
            find.descendant(
              of: card,
              matching: find.byType(CircularProgressIndicator),
            ),
            key == busyCardKey ? findsOneWidget : findsNothing,
          );
        }

        pending.complete();
        await operation;
        await tester.pump();
        await tester.pump();
      }
    },
  );
}
