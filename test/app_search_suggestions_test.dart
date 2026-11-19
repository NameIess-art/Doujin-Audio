import 'dart:collection';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/core/media/search_query_utils.dart';

void main() {
  testWidgets('search tabs use their full labels when the row fits', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSearchElementTabs(
            draft: '',
            matchAll: false,
            onSelected: (_) {},
            translate: (key) => switch (key) {
              'search_elements_all' => 'すべて含む',
              'search_elements_any' => 'いずれかを含む',
              'search_other_filters' => 'その他の条件',
              _ => key,
            },
            filters: emptySearchFilters,
            onFiltersChanged: (_) {},
          ),
        ),
      ),
    );
    final labels = [
      find.text('すべて含む 0'),
      find.text('いずれかを含む 0'),
      find.text('その他の条件'),
    ];
    final labelWidths = labels
        .map((label) => tester.getSize(label).width)
        .toList();
    final tabs = find.byWidgetPredicate(
      (widget) => widget is ChoiceChip || widget is FilterChip,
    );
    const horizontalPadding = 32.0;
    const gaps = 12.0;
    final width =
        horizontalPadding +
        gaps +
        tester.getSize(tabs.at(0)).width +
        tester.getSize(tabs.at(1)).width +
        tester.getSize(tabs.at(2)).width;
    await tester.binding.setSurfaceSize(Size(width.ceilToDouble(), 700));
    await tester.pumpAndSettle();
    expect(labels.map((label) => tester.getSize(label).width), labelWidths);
    expect(tester.getCenter(tabs.at(1)).dy, tester.getCenter(tabs.at(0)).dy);
    expect(tester.getCenter(tabs.at(2)).dy, tester.getCenter(tabs.at(1)).dy);

    await tester.binding.setSurfaceSize(Size(width.floorToDouble() - 8, 700));
    await tester.pumpAndSettle();
    expect(labels.map((label) => tester.getSize(label).width), labelWidths);
    expect(
      tester.getCenter(tabs.at(2)).dy,
      greaterThan(tester.getCenter(tabs.at(1)).dy),
    );
  });

  testWidgets(
    'other filters expand above history and retain their values',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var filters = emptySearchFilters;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            chipTheme: const ChipThemeData(labelStyle: TextStyle(fontSize: 12)),
          ),
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: StatefulBuilder(
                    builder: (context, setState) => AppSearchElementTabs(
                      draft: '',
                      matchAll: true,
                      onSelected: (_) {},
                      translate: (key) => switch (key) {
                        'search_elements_all' => '必须包含',
                        'search_elements_any' => '至少包含',
                        'search_other_filters' => '其他筛选',
                        'search_filter_any' => '不限',
                        'search_subtitle_filter' => '字幕',
                        'search_has_subtitle' => '有',
                        'search_has_no_subtitle' => '无',
                        'search_minimum_rating' => '最低评分',
                        'search_duration_range' => '时长区间',
                        'search_release_range' => '发售区间',
                        _ => key,
                      },
                      filters: filters,
                      onFiltersChanged: (value) =>
                          setState(() => filters = value),
                    ),
                  ),
                ),
                AppSearchSuggestionSection(
                  title: '搜索历史',
                  items: const [],
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
      final toggle = find.byKey(const ValueKey('search_other_filters'));
      Finder arrow(IconData icon) =>
          find.descendant(of: toggle, matching: find.byIcon(icon));
      final subtitle = find.byKey(const ValueKey('search_subtitle_filter'));
      final rating = find.byKey(const ValueKey('search_minimum_rating'));
      final minDuration = find.byKey(const ValueKey('search_minimum_duration'));
      final maxDuration = find.byKey(const ValueKey('search_maximum_duration'));
      final firstDate = find.byKey(const ValueKey('search_first_release'));
      final lastDate = find.byKey(const ValueKey('search_last_release'));
      final history = find.text('搜索历史');

      expect(subtitle, findsNothing);
      expect(
        tester.getTopLeft(arrow(Icons.expand_more_rounded)).dx,
        greaterThan(tester.getTopRight(find.text('其他筛选')).dx),
      );
      expect(
        tester.getCenter(toggle).dx,
        greaterThan(tester.getCenter(find.text('至少包含 0')).dx),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(arrow(Icons.expand_less_rounded), findsOneWidget);
      expect(
        tester.getCenter(rating).dy,
        lessThan(tester.getCenter(minDuration).dy),
      );
      expect(
        tester.getCenter(minDuration).dy,
        tester.getCenter(maxDuration).dy,
      );
      expect(tester.getCenter(firstDate).dy, tester.getCenter(lastDate).dy);
      expect(
        tester.getCenter(lastDate).dy,
        lessThan(tester.getCenter(history).dy),
      );

      final titleStyle = tester.widget<Text>(history).style;
      for (final title in ['字幕', '最低评分', '时长区间', '发售区间']) {
        expect(tester.widget<Text>(find.text(title)).style, titleStyle);
      }
      expect(
        tester.getTopLeft(subtitle).dx,
        greaterThan(tester.getTopRight(find.text('字幕')).dx),
      );
      expect(
        tester.getTopLeft(rating).dx,
        greaterThan(tester.getTopRight(find.text('最低评分')).dx),
      );
      expect(tester.getSize(subtitle).height, 120);
      expect(tester.getSize(rating).height, 120);
      expect(find.byType(ListWheelScrollView), findsNWidgets(2));
      expect(
        find.descendant(of: subtitle, matching: find.byType(DecoratedBox)),
        findsNothing,
      );
      expect(
        find.descendant(of: rating, matching: find.byType(DecoratedBox)),
        findsNothing,
      );
      expect(find.byType(InputChip), findsNothing);
      expect(find.text('–'), findsNWidgets(2));

      final haptics = <Object?>[];
      final previousHaptics = AppInteractionFeedback.hapticFeedbackEnabled;
      AppInteractionFeedback.hapticFeedbackEnabled = true;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      });
      addTearDown(() {
        AppInteractionFeedback.hapticFeedbackEnabled = previousHaptics;
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      Future<void> scroll(Finder wheel, double delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(wheel),
            scrollDelta: Offset(0, delta),
          ),
        );
        await tester.pumpAndSettle();
      }

      final isWindows = defaultTargetPlatform == TargetPlatform.windows;
      final delta = isWindows ? 120.0 : 42.0;
      await scroll(subtitle, delta);
      expect(filters.hasSubtitle, isFalse);
      await scroll(subtitle, delta);
      expect(filters.hasSubtitle, isTrue);
      await scroll(subtitle, delta);
      expect(filters.hasSubtitle, isTrue);
      await scroll(subtitle, -delta);
      expect(filters.hasSubtitle, isFalse);
      await scroll(subtitle, -delta);
      expect(filters.hasSubtitle, isNull);
      await scroll(rating, delta);
      expect(filters.minimumRating, 0.1);
      await scroll(rating, delta);
      expect(filters.minimumRating, 0.2);
      await scroll(rating, delta);
      expect(filters.minimumRating, 0.3);
      expect(
        haptics,
        defaultTargetPlatform == TargetPlatform.android
            ? List.filled(7, 'HapticFeedbackType.selectionClick')
            : isEmpty,
      );
      haptics.clear();
      AppInteractionFeedback.hapticFeedbackEnabled = false;
      await scroll(rating, delta);
      expect(filters.minimumRating, 0.4);
      await scroll(rating, -delta);
      expect(haptics, isEmpty);
      AppInteractionFeedback.hapticFeedbackEnabled = previousHaptics;
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(minDuration);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '30');
      await tester.tap(find.text('confirm'));
      await tester.pumpAndSettle();
      expect(filters.minimumDuration, const Duration(minutes: 30));
      expect(filters.maximumDuration, isNull);
      await tester.tap(maxDuration);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '20');
      await tester.tap(find.text('confirm'));
      await tester.pumpAndSettle();
      expect(find.text('search_invalid_duration_range'), findsOneWidget);
      await tester.tap(find.text('cancel'));
      await tester.pumpAndSettle();

      await tester.tap(lastDate);
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.byTooltip('Switch to input'));
      await tester.pumpAndSettle();
      final date = DateTime(2024, 5, 13);
      final dateLocalizations = MaterialLocalizations.of(
        tester.element(find.byType(DatePickerDialog)),
      );
      await tester.enterText(
        find.byType(TextFormField),
        dateLocalizations.formatCompactDate(date),
      );
      await tester.tap(find.text('confirm'));
      await tester.pumpAndSettle();
      expect(filters.lastReleaseDate, date);
      expect(filters.firstReleaseDate, isNull);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(rating, findsNothing);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(filters.minimumRating, 0.3);
      final ratingWheel = find.descendant(
        of: rating,
        matching: find.byType(ListWheelScrollView),
      );
      expect(
        (tester.widget<ListWheelScrollView>(ratingWheel).controller!
                as FixedExtentScrollController)
            .selectedItem,
        3,
      );
      expect(filters.minimumDuration, const Duration(minutes: 30));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('all three search sections have no background', (tester) async {
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
      expect(find.byType(AppElementChip), findsNWidgets(3));
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
      for (final chip in find.byType(AppElementChip).evaluate()) {
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
      expect(
        find.byType(AppElementChip).evaluate().length,
        lessThanOrEqualTo(30),
      );
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
      tester.widget<AppElementChip>(find.byType(AppElementChip).first).selected,
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
        tester
            .widget<AppElementChip>(find.byType(AppElementChip).first)
            .selected,
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

  testWidgets('large directories measure visible rows before the full range', (
    tester,
  ) async {
    final items = _TrackedSuggestions(5000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              AppElementChipSliver(
                items: items,
                isSelected: (_) => false,
                onToggle: (_) {},
                resolveRowCount: true,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('suggestion 0000'), findsOneWidget);
    expect(items.highestReadIndex, lessThan(500));
    await tester.pumpAndSettle();
    expect(items.readCount, items.length);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .maxScrollExtent
          .isFinite,
      isTrue,
    );
  });

  testWidgets(
    'standalone element rows track labels, scale, width and read-only state',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const items = ['automatic', 'manual', 'other'];
      var labels = {
        'automatic': 'Automatic',
        'manual': 'Manual',
        'other': 'Other',
      };
      var scale = 1.0;
      var readOnly = false;
      var toggles = 0;
      Widget buildPage() => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: AppElementChipSliver(
                    items: items,
                    labels: labels,
                    isSelected: (key) => key != 'other',
                    isEnabled: (key) => key != 'automatic',
                    mutedHint: 'Already listened',
                    readOnly: readOnly,
                    onToggle: (_) => toggles++,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.binding.setSurfaceSize(const Size(320, 600));
      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();
      final automatic = find.byKey(const ValueKey('automatic'));
      final manual = find.byKey(const ValueKey('manual'));
      expect(tester.widget<AppElementChip>(automatic).onPressed, isNull);
      expect(find.byTooltip('Already listened'), findsOneWidget);
      await tester.tap(manual);
      expect(toggles, 1);
      for (final width in [320.0, 960.0, 390.0]) {
        scale = width == 960 ? 1.0 : 1.6;
        labels = {
          'automatic': 'Automatic element with a very long display name',
          'manual': '另一个具有较长名称的手动选择元素 with English text',
          'other': 'Other',
        };
        await tester.binding.setSurfaceSize(Size(width, 600));
        await tester.pumpWidget(buildPage());
        await tester.pumpAndSettle();
        for (final item in items) {
          final rect = tester.getRect(find.byKey(ValueKey(item)));
          expect(rect.left, greaterThanOrEqualTo(16));
          expect(rect.right, lessThanOrEqualTo(width - 16));
        }
        expect(find.text('Manual'), findsNothing);
        expect(tester.takeException(), isNull);
      }
      readOnly = true;
      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();
      expect(tester.widget<AppElementChip>(manual).onPressed, isNull);
      final cs = Theme.of(tester.element(manual)).colorScheme;
      Color? background(Finder chip) => tester
          .widget<Material>(
            find.descendant(of: chip, matching: find.byType(Material)),
          )
          .color;
      expect(background(manual), cs.primary.withValues(alpha: .16));
      expect(background(automatic), cs.surfaceContainerHighest);
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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
