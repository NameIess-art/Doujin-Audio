import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/widgets/operation_feedback.dart';

void main() {
  testWidgets('status banner exposes a full-size cancel action', (
    tester,
  ) async {
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OperationStatusBanner(
            label: 'Scanning folder',
            semanticLabel: 'Scanning Music',
            cancelTooltip: 'Cancel scan',
            onCancel: () => cancelled = true,
          ),
        ),
      ),
    );

    final cancel = find.byTooltip('Cancel scan');
    expect(cancel, findsOneWidget);
    expect(tester.getSize(cancel).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));

    await tester.tap(cancel);
    expect(cancelled, isTrue);
  });

  testWidgets('empty state remains usable with large text', (tester) async {
    var actionCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: AppEmptyState(
              icon: Icons.search_off_rounded,
              title: 'No matching results',
              message: 'Try another search term or clear this search.',
              actionLabel: 'Clear search',
              actionIcon: Icons.clear_rounded,
              onAction: () => actionCount++,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Clear search'));
    expect(actionCount, 1);
  });
}
