import 'dart:async';

import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = UndoableRemovalKey('test', 'row');

Widget _buildRow() => Consumer(
  builder: (context, ref, _) => UndoableRemovalTransition(
    hidden: ref.watch(isUndoableRemovalHiddenProvider(_key)),
    child: const SizedBox(height: 60, child: Text('Removed row')),
  ),
);

void main() {
  for (final platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    testWidgets('$platform countdown never restores a stale removed row', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final service = UndoableRemovalService();
      addTearDown(service.dispose);
      final sourceHasRow = ValueNotifier(true);
      addTearDown(sourceHasRow.dispose);
      var committed = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            undoableRemovalServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: sourceHasRow,
                      builder: (context, present, _) =>
                          present ? _buildRow() : const SizedBox.shrink(),
                    ),
                    TextButton(
                      onPressed: () => showUndoableRemovalFeedback(
                        context,
                        service: service,
                        action: UndoableRemovalAction(
                          key: _key,
                          commit: () => committed = true,
                          undo: () {},
                        ),
                        message: 'Removed',
                        batchMessage: (count) => '$count removed',
                        undoLabel: 'Undo',
                        failureMessage: 'Failed',
                      ),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Removed row'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Removed row'), findsNothing);
      expect(find.text('Undo (5s)'), findsOneWidget);

      await tester.pump(kUndoableRemovalFeedbackDuration);
      // The backing list still holds its previous snapshot after commit.
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('Removed row'), findsNothing);
      }
      expect(committed, isTrue);
      expect(service.state.hiddenKeys, isEmpty);
      expect(service.state.committingCount, 0);

      sourceHasRow.value = false;
      await tester.pump();
      await tester.pump();
      // A later import of the same key must not inherit the deleted row's state.
      sourceHasRow.value = true;
      await tester.pump();
      await tester.pump();
      expect(find.text('Removed row'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final outcome in <String>[
    'undo',
    'commit failure',
    'prepare failure',
    'prepare exception',
  ]) {
    testWidgets('$outcome restores the collapsed row', (tester) async {
      final service = UndoableRemovalService();
      addTearDown(service.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            undoableRemovalServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(home: Scaffold(body: _buildRow())),
        ),
      );
      await tester.pump();
      final releasePrepare = Completer<void>();
      final stage = service.stage(
        UndoableRemovalAction(
          key: _key,
          prepare: () async {
            await releasePrepare.future;
            if (outcome == 'prepare exception') {
              throw StateError('Prepare failed');
            }
            return outcome != 'prepare failure';
          },
          commit: () => throw StateError('Commit failed'),
          undo: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Removed row'), findsNothing);
      releasePrepare.complete();
      final staged = await stage;
      if (staged) {
        await tester.pumpAndSettle();
        expect(find.text('Removed row'), findsNothing);
        if (outcome == 'undo') {
          expect(await service.undoPending(), 0);
        } else {
          expect(await service.commitPending(), 1);
        }
      }
      await tester.pumpAndSettle();
      expect(find.text('Removed row'), findsOneWidget);
    });
  }
}
