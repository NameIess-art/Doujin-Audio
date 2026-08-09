import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/search_highlight.dart';

void main() {
  Future<void> pumpHighlight(
    WidgetTester tester, {
    required String text,
    String? scopeQuery,
    List<String>? terms,
  }) async {
    final child = SearchHighlightedText(
      text: text,
      terms: terms,
      style: const TextStyle(fontSize: 12),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: scopeQuery == null
              ? child
              : SearchHighlightScope(query: scopeQuery, child: child),
        ),
      ),
    );
  }

  List<String> highlightedRuns(WidgetTester tester) {
    final runs = <String>[];
    for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
      richText.text.visitChildren((span) {
        if (span is TextSpan && span.style?.fontWeight == FontWeight.w900) {
          runs.add(span.text ?? '');
        }
        return true;
      });
    }
    return runs;
  }

  testWidgets('renders plain text when there is nothing to highlight', (
    tester,
  ) async {
    await pumpHighlight(tester, text: 'Ocean Waves');
    expect(find.byType(Text), findsOneWidget);
    expect(find.text('Ocean Waves'), findsOneWidget);
    expect(highlightedRuns(tester), isEmpty);

    await pumpHighlight(tester, text: 'Ocean Waves', scopeQuery: 'rain');
    expect(find.byType(Text), findsOneWidget);
    expect(highlightedRuns(tester), isEmpty);
  });

  testWidgets('highlights every term supplied by the enclosing scope', (
    tester,
  ) async {
    await pumpHighlight(
      tester,
      text: 'Soft Rain and Ocean Rain',
      scopeQuery: 'rain,ocean',
    );
    expect(highlightedRuns(tester), <String>['Rain', 'Ocean', 'Rain']);
  });

  testWidgets('explicit terms win over the scope and match case-insensitively', (
    tester,
  ) async {
    await pumpHighlight(
      tester,
      text: 'Ocean Waves',
      scopeQuery: 'rain',
      terms: const <String>['OCEAN'],
    );
    expect(highlightedRuns(tester), <String>['Ocean']);
  });

  testWidgets('merges overlapping term matches into one run', (tester) async {
    await pumpHighlight(
      tester,
      text: 'Rainfall',
      scopeQuery: 'rain,ainfall',
    );
    expect(highlightedRuns(tester), <String>['Rainfall']);
  });

  testWidgets('static library-like card text highlights the scope terms', (
    tester,
  ) async {
    const title = 'Ocean Rain Collection';
    const circle = 'Rain Circle';
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SearchHighlightScope(
            query: 'rain',
            child: SizedBox(
              width: 260,
              child: LibraryLikeWorkCardContent(
                title: title,
                lines: const [LibraryLikeInfoLineData('Circle', circle)],
                coverBuilder: (_) => const SizedBox(width: 120),
                onPlay: () {},
                playTooltip: 'Play',
                enableMarquee: false,
                enableTitleMarquee: false,
              ),
            ),
          ),
        ),
      ),
    );

    expect(highlightedRuns(tester), contains('Rain'));
    expect(find.text(title, findRichText: true), findsOneWidget);
    expect(find.text(circle, findRichText: true), findsOneWidget);
  });
}
