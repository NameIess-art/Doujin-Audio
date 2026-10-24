import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';

void main() {
  testWidgets(
    'folding reacts to width and each section retains its own state',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Widget section(String prefix) => AppSearchSuggestionSection(
        key: ValueKey(prefix),
        title: prefix,
        items: List.generate(6, (i) => '$prefix suggestion $i'),
        isSelected: (_) => false,
        onToggle: (_) {},
        emptyText: 'Empty',
        expandLabel: 'Expand',
        collapseLabel: 'Collapse',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(slivers: [section('A'), section('B')]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final expandButtons = find.byTooltip('Expand');
      expect(expandButtons, findsNWidgets(2));
      expect(find.byIcon(Icons.expand_more_rounded), findsNWidgets(2));
      expect(tester.getSize(expandButtons.first), const Size(24, 24));
      expect(tester.getTopRight(expandButtons.first).dx, 320 - 16);
      final firstChip = tester.widget<InputChip>(find.byType(InputChip).first);
      expect(firstChip.visualDensity, VisualDensity.compact);
      expect(firstChip.backgroundColor, isNull);
      for (final chip in find.byType(InputChip).evaluate()) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byWidget(chip.widget),
            matching: find.byType(RichText),
          ),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      await tester.tap(expandButtons.first);
      await tester.pumpAndSettle();
      expect(find.text('A suggestion 3'), findsOneWidget);
      expect(find.text('B suggestion 3'), findsNothing);
      expect(find.byTooltip('Collapse'), findsOneWidget);
      expect(find.byIcon(Icons.expand_less_rounded), findsOneWidget);
      await tester.tap(find.byTooltip('Collapse'));
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      await tester.pumpAndSettle();
      expect(find.text('A suggestion 5'), findsOneWidget);
      expect(find.text('B suggestion 5'), findsOneWidget);
      expect(find.byTooltip('Expand'), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('sections fold by rows, expand independently, and build lazily', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final items = List.generate(
      100,
      (i) => 'suggestion ${i.toString().padLeft(2, '0')}',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: scroll,
            slivers: [
              for (final name in ['Voices', 'Tags'])
                AppSearchSuggestionSection(
                  key: ValueKey(name),
                  title: name,
                  items: name == 'Voices' ? items : ['tag'],
                  isSelected: (_) => false,
                  onToggle: (_) {},
                  emptyText: 'Empty',
                  expandLabel: 'Expand',
                  collapseLabel: 'Collapse',
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('suggestion 02'), findsOneWidget);
    expect(find.text('suggestion 03'), findsNothing);
    expect(find.byTooltip('Expand'), findsOneWidget);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(find.text('suggestion 03'), findsOneWidget);
    expect(find.text('suggestion 99'), findsNothing);
    expect(find.byTooltip('Collapse'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('suggestion 99'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('suggestion 99'), findsOneWidget);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Collapse'));
    await tester.pumpAndSettle();
    expect(find.text('suggestion 03'), findsNothing);
    expect(find.text('tag'), findsOneWidget);
  });

  testWidgets('long suggestions stay within narrow large-text layouts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(240, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? toggled;
    const item = 'A voice actor with a very long name that cannot fit';
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: CustomScrollView(
              slivers: [
                AppSearchSuggestionSection(
                  title: 'Voices',
                  items: [item, for (var i = 1; i < 5; i++) '$item $i'],
                  isSelected: (_) => true,
                  onToggle: (value) => toggled = value,
                  emptyText: 'Empty',
                  expandLabel: 'Expand',
                  collapseLabel: 'Collapse',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Expand'), findsOneWidget);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(item));
    expect(toggled, item);
  });

  testWidgets('confirmation remains above keyboard without category header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var confirmed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 800),
            viewInsets: EdgeInsets.only(bottom: 300),
          ),
          child: AppSearchPageScaffold<int>(
            controller: controller,
            focusNode: focus,
            hintText: 'Search',
            onChanged: (_) {},
            onSubmitted: (_) {},
            onCloseOrClear: () {},
            showConfirmButton: true,
            onConfirm: () => confirmed++,
            body: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('app_search_category_shell')),
      findsNothing,
    );
    final button = find.byKey(const ValueKey('app_search_confirm'));
    expect(tester.getBottomRight(button).dy, lessThanOrEqualTo(500));
    await tester.tap(button);
    expect(confirmed, 1);
  });
}
