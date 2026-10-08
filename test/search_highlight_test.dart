import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  testWidgets(
    'explicit terms win over the scope and match case-insensitively',
    (tester) async {
      await pumpHighlight(
        tester,
        text: 'Ocean Waves',
        scopeQuery: 'rain',
        terms: const <String>['OCEAN'],
      );
      expect(highlightedRuns(tester), <String>['Ocean']);
    },
  );

  testWidgets('merges overlapping term matches into one run', (tester) async {
    await pumpHighlight(tester, text: 'Rainfall', scopeQuery: 'rain,ainfall');
    expect(highlightedRuns(tester), <String>['Rainfall']);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('highlight keeps all corners within a tight line at $scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Center(
              child: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: const SearchHighlightedText(
                  text: 'Rain',
                  terms: ['Rain'],
                  maxLines: 1,
                  style: TextStyle(fontSize: 20, height: 0.7),
                  strutStyle: StrutStyle(
                    fontSize: 20,
                    height: 0.7,
                    forceStrutHeight: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(SearchHighlightedText),
          matching: find.byType(RichText),
        ),
      );
      final box = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 4),
          )
          .single;
      expect(box.top, lessThan(0));
      expect(box.bottom, greaterThan(paragraph.size.height));
      expect(
        find.byType(SearchHighlightedText),
        paints..rrect(
          rrect: RRect.fromRectAndRadius(
            Rect.fromLTRB(box.left, 0, box.right, paragraph.size.height),
            const Radius.circular(4),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'rounded highlights wrap and scale at $scale in $brightness',
        (tester) async {
          const text = '中文音频中文音频中文音频';
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: Material(
                child: Center(
                  child: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: const SizedBox(
                      width: 120,
                      child: SearchHighlightedText(
                        text: text,
                        terms: [text],
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byType(SearchHighlightedText),
              matching: find.byType(RichText),
            ),
          );
          expect(paragraph.textScaler.scale(14), 14 * scale);
          final boxes = paragraph.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: text.length),
          );
          expect(boxes.length, greaterThan(1));
          final pattern = paints..clipRect(rect: Offset.zero & paragraph.size);
          for (final box in boxes) {
            pattern.rrect(
              rrect: RRect.fromRectAndRadius(
                box.toRect().intersect(Offset.zero & paragraph.size),
                const Radius.circular(4),
              ),
              color: Theme.of(
                tester.element(find.byType(SearchHighlightedText)),
              ).colorScheme.primary.withValues(alpha: 0.18),
            );
          }
          expect(find.byType(SearchHighlightedText), pattern);
          expect(find.text(text, findRichText: true), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

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
                lines: const [
                  LibraryLikeInfoLineData(
                    'Circle',
                    circle,
                    icon: Icons.groups_rounded,
                  ),
                ],
                coverBuilder: (_) => const SizedBox(width: 120),
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
