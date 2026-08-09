import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/glass_refresh_indicator.dart';

void main() {
  testWidgets('pull-to-refresh indicator has no shadow decoration', (
    tester,
  ) async {
    final refresh = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassRefreshIndicator(
            onRefresh: () => refresh.future,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [SizedBox(height: 800)],
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    final indicator = find.byType(RefreshProgressIndicator);
    expect(indicator, findsOneWidget);
    final decoratedAncestors = tester.widgetList<DecoratedBox>(
      find.ancestor(of: indicator, matching: find.byType(DecoratedBox)),
    );
    expect(
      decoratedAncestors.where((widget) {
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            (decoration.boxShadow?.isNotEmpty ?? false);
      }),
      isEmpty,
    );

    refresh.complete();
    await tester.pump(const Duration(milliseconds: 300));
  });
}
