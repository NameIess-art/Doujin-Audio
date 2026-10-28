import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';

void main() {
  testWidgets('all three search sections have no background', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      final theme = ThemeData(brightness: brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                for (final title in ['History', 'Voices', 'Tags'])
                  AppSearchSuggestionSection(
                    title: title,
                    items: [title],
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
      expect(find.byType(DecoratedSliver), findsNothing);
      expect(find.byType(AppSearchSuggestionSection), findsNWidgets(3));
      expect(find.byType(InputChip), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    }
  });

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
      expect(tester.getSize(expandButtons.first), const Size(32, 32));
      expect(tester.getTopRight(expandButtons.first).dx, 320 - 16);
      final firstChip = tester.widget<InputChip>(find.byType(InputChip).first);
      expect(
        firstChip.padding,
        const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      );
      expect(firstChip.labelPadding, const EdgeInsets.symmetric(horizontal: 4));
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

  testWidgets(
    'clear icon precedes expansion and is disabled for empty history',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var items = List.generate(6, (i) => 'History suggestion $i');
      var clears = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => CustomScrollView(
                slivers: [
                  AppSearchSuggestionSection(
                    title: 'History',
                    items: items,
                    isSelected: (_) => false,
                    onToggle: (_) {},
                    emptyText: 'Empty',
                    expandLabel: 'Expand',
                    collapseLabel: 'Collapse',
                    clearLabel: 'Clear history',
                    onClear: () => setState(() {
                      clears++;
                      items = [];
                    }),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final clear = find.byTooltip('Clear history');
      final expand = find.byTooltip('Expand');
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      expect(
        tester.getTopRight(clear).dx,
        lessThan(tester.getTopLeft(expand).dx),
      );
      expect(tester.getCenter(clear).dy, tester.getCenter(expand).dy);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(clears, 1);
      expect(find.text('Empty'), findsOneWidget);
      expect(expand, findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.delete_outline_rounded),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(clear);
      expect(clears, 1);
    },
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

  testWidgets(
    'bounded sections never traverse or reveal the full directory',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final items = _TrackedSuggestions(5000);
      Widget buildPage() => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: scroll,
            slivers: [
              AppSearchSuggestionSection(
                title: 'Voices',
                items: items,
                maxExpandedItems: 30,
                isSelected: (_) => false,
                onToggle: (_) {},
                emptyText: 'Empty',
                expandLabel: 'Expand',
                collapseLabel: 'Collapse',
              ),
            ],
          ),
        ),
      );

      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();
      expect(find.text('suggestion 0002'), findsOneWidget);
      expect(find.text('suggestion 0003'), findsNothing);
      expect(items.highestReadIndex, 3);
      expect(items.readCount, 4);
      await tester.tap(find.byTooltip('Expand'));
      await tester.pumpAndSettle();
      expect(find.text('suggestion 0003'), findsOneWidget);
      expect(find.byType(InputChip).evaluate().length, lessThanOrEqualTo(30));
      await tester.scrollUntilVisible(
        find.text('suggestion 0029'),
        600,
        scrollable: find.byType(Scrollable).first,
      );
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('suggestion 0029'), findsOneWidget);
      expect(find.text('suggestion 0030'), findsNothing);
      expect(find.text('suggestion 4999'), findsNothing);
      expect(items.highestReadIndex, 29);
      expect(items.readCount, 30);

      // Neither a selection rebuild nor cached scrolling rereads the directory.
      items.readCount = 0;
      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();
      expect(items.highestReadIndex, 29);
      expect(items.readCount, 0);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('large local directories only lay out rows when needed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final items = _TrackedSuggestions(5000);
    var selected = false;
    Widget buildPage() => MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSearchSuggestionSection(
              title: 'Voices',
              items: items,
              isSelected: (_) => selected,
              onToggle: (_) {},
              emptyText: 'Empty',
              expandLabel: 'Expand',
              collapseLabel: 'Collapse',
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    final initialReads = items.readCount;
    items.readCount = 0;
    selected = true;
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    final selectionReads = items.readCount;
    items.readCount = 0;
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    final expansionReads = items.readCount;
    debugPrint(
      'Suggestion source reads: initial=$initialReads, '
      'selection=$selectionReads, expand=$expansionReads',
    );
    expect(initialReads, lessThan(10));
    expect(selectionReads, 0);
    expect(expansionReads, lessThan(100));
    expect(find.text('suggestion 4999'), findsNothing);
    expect(
      tester.widget<InputChip>(find.byType(InputChip).first).selected,
      isTrue,
    );

    items.readCount = 0;
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(items.readCount, 0);
    await tester.binding.setSurfaceSize(const Size(500, 800));
    await tester.pumpAndSettle();
    expect(items.readCount, greaterThan(0));
    expect(items.readCount, lessThan(100));
    // Unlimited local sections remain fully accessible after lazy expansion.
    await tester.scrollUntilVisible(
      find.text('suggestion 4999'),
      10000,
      maxScrolls: 30,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('suggestion 4999'), findsOneWidget);
    expect(items.highestReadIndex, 4999);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scrolling reuses unchanged suggestion rows instead of rebuilding chips',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final items = _TrackedSuggestions(5000);
      var selectionChecks = 0;
      var selected = false;
      Widget buildPage() => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: scroll,
            slivers: [
              AppSearchSuggestionSection(
                title: 'Voices',
                items: items,
                isSelected: (_) {
                  selectionChecks++;
                  return selected;
                },
                onToggle: (_) {},
                emptyText: 'Empty',
                expandLabel: 'Expand',
                collapseLabel: 'Collapse',
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand'));
      await tester.pumpAndSettle();
      selectionChecks = 0;
      final reads = items.readCount;
      for (var i = 1; i <= 20; i++) {
        scroll.jumpTo(i.toDouble());
        await tester.pump();
      }
      debugPrint(
        'Suggestion scroll: chip builds=$selectionChecks, '
        'source reads=${items.readCount - reads}',
      );
      expect(selectionChecks, lessThan(10));
      selected = true;
      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();
      expect(
        tester.widget<InputChip>(find.byType(InputChip).first).selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('row caches refresh with source, limit, and text geometry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var items = _TrackedSuggestions(50);
    var limit = 3;
    var scale = 1.0;
    var fontSize = 14.0;
    Widget buildPage() => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: ChipTheme(
          data: ChipThemeData(labelStyle: TextStyle(fontSize: fontSize)),
          child: Scaffold(
            body: CustomScrollView(
              slivers: [
                AppSearchSuggestionSection(
                  title: 'Voices',
                  items: items,
                  maxExpandedItems: limit,
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
      ),
    );
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(items.readCount, 3);
    expect(find.byTooltip('Expand'), findsNothing);
    limit = 30;
    items.readCount = 0;
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(items.readCount, greaterThan(0));
    expect(items.highestReadIndex, lessThan(30));
    expect(find.byTooltip('Expand'), findsOneWidget);

    for (final geometry in ['scale', 'style', 'source']) {
      if (geometry == 'scale') scale = 1.5;
      if (geometry == 'style') fontSize = 18;
      if (geometry == 'source') items = _TrackedSuggestions(50, prefix: 'new');
      items.readCount = 0;
      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();
      expect(items.readCount, greaterThan(0), reason: geometry);
      expect(items.readCount, lessThan(30), reason: geometry);
    }
    expect(find.text('new 0000'), findsOneWidget);
    expect(find.text('suggestion 0000'), findsNothing);
    expect(tester.takeException(), isNull);
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

class _TrackedSuggestions extends ListBase<String> {
  _TrackedSuggestions(this.length, {this.prefix = 'suggestion'});

  @override
  final int length;
  final String prefix;
  int highestReadIndex = -1;
  int readCount = 0;

  @override
  set length(int value) => throw UnsupportedError('Read-only suggestions');

  @override
  String operator [](int index) {
    readCount++;
    if (index > highestReadIndex) highestReadIndex = index;
    return '$prefix ${index.toString().padLeft(4, '0')}';
  }

  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('Read-only suggestions');
}
