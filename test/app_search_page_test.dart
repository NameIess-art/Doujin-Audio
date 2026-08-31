import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';

void main() {
  testWidgets('search route uses a fade transition without scaling', (tester) async {
    late BuildContext routeContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            routeContext = context;
            return const SizedBox.expand();
          },
        ),
      ),
    );

    final route = buildAppSearchPageRoute<void>(
      context: routeContext,
      child: const SizedBox.expand(),
    );
    final transition = route.transitionsBuilder(
      routeContext,
      const AlwaysStoppedAnimation<double>(0.5),
      const AlwaysStoppedAnimation<double>(0),
      const SizedBox.expand(),
    );

    expect(transition, isA<FadeTransition>());
    expect((transition as FadeTransition).child, isNot(isA<ScaleTransition>()));
  });

  testWidgets(
    'search page stays usable in small landscape with keyboard and large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 360);
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        tester.view.resetViewInsets();
      });

      final controller = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      var closeCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData.fromView(tester.view).copyWith(
              padding: const EdgeInsets.only(top: 24),
              textScaler: const TextScaler.linear(2),
            ),
            child: AppSearchPageScaffold<int>(
              controller: controller,
              focusNode: focusNode,
              hintText: 'Search audio',
              categories: const <AppSearchCategory<int>>[
                AppSearchCategory(value: 0, label: 'All'),
                AppSearchCategory(value: 1, label: 'Tags'),
                AppSearchCategory(value: 2, label: 'Voice actors'),
                AppSearchCategory(value: 3, label: 'Circles'),
                AppSearchCategory(value: 4, label: 'Recommendations'),
              ],
              selectedCategory: 0,
              onCategorySelected: (_) {},
              onChanged: (_) {},
              onSubmitted: (_) {},
              onCloseOrClear: () => closeCount++,
              blurEnabled: true,
              body: const Center(
                child: Text(
                  'Direct content',
                  key: ValueKey<String>('direct_search_content'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(find.byKey(const ValueKey<String>('app_search_field')), findsOne);
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey<String>('app_search_field_shell')),
            )
            .height,
        38,
      );
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey<String>('app_search_category_shell')),
            )
            .height,
        38,
      );
      expect(
        find.byKey(const ValueKey<String>('direct_search_content')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('app_search_stack')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('app_search_body_layer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('app_search_controls_overlay')),
        findsOneWidget,
      );
      final fadeMaskFinder = find.byKey(
        const ValueKey<String>('app_search_top_fade_mask'),
      );
      final fadeMask = tester.widget<AppEdgeFadeMask>(fadeMaskFinder);
      expect(fadeMask.direction, AppEdgeFadeDirection.towardTop);
      expect(tester.getSize(fadeMaskFinder).height, 128);
      final fadeDecoration = tester.widget<DecoratedBox>(
        find.descendant(
          of: fadeMaskFinder,
          matching: find.byType(DecoratedBox),
        ),
      );
      final fadeGradient =
          (fadeDecoration.decoration as BoxDecoration).gradient!
              as LinearGradient;
      expect(fadeGradient.begin, Alignment.topCenter);
      expect(fadeGradient.end, Alignment.bottomCenter);
      expect(fadeGradient.stops, const <double>[0, 0.35, 0.58, 0.82, 1]);
      expect(fadeGradient.colors.first.a, 0.82);
      expect(fadeGradient.colors.last.a, 0);
      expect(
        tester
            .widget<IgnorePointer>(
              find.descendant(
                of: fadeMaskFinder,
                matching: find.byType(IgnorePointer),
              ),
            )
            .ignoring,
        isTrue,
      );
      final stack = tester.widget<Stack>(
        find.byKey(const ValueKey<String>('app_search_stack')),
      );
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey<String>('app_search_stack')))
            .dy,
        0,
      );
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('app_search_field_shell')),
            )
            .dy,
        30,
      );
      expect(
        stack.children.first.key,
        const ValueKey<String>('app_search_body_layer'),
      );
      expect(
        stack.children.last.key,
        const ValueKey<String>('app_search_controls_overlay'),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('app_search_controls_overlay')),
          matching: find.byType(BackdropFilter),
        ),
        findsNWidgets(3),
      );
      final inputDecorator = tester.widget<InputDecorator>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('app_search_field')),
          matching: find.byType(InputDecorator),
        ),
      );
      expect(inputDecorator.decoration.filled, isFalse);
      final searchField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('app_search_field')),
      );
      expect(searchField.textAlignVertical, TextAlignVertical.center);
      expect(
        searchField.decoration?.contentPadding,
        const EdgeInsets.only(right: 10),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey<String>('app_search_close')));
      expect(closeCount, 1);
    },
  );

  testWidgets('search capsules remove backdrop blur when disabled', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppSearchPageScaffold<int>(
          controller: controller,
          focusNode: focusNode,
          hintText: 'Search audio',
          categories: const <AppSearchCategory<int>>[
            AppSearchCategory(value: 0, label: 'All'),
          ],
          selectedCategory: 0,
          onCategorySelected: (_) {},
          onChanged: (_) {},
          onSubmitted: (_) {},
          onCloseOrClear: () {},
          blurEnabled: false,
          body: const SizedBox.expand(),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('app_search_controls_overlay')),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'search body layer adjusts for keyboard insets allowing results to scroll above keyboard',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        tester.view.resetViewInsets();
      });

      final controller = TextEditingController();
      final focusNode = FocusNode();
      final scrollController = ScrollController();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: AppSearchPageScaffold<int>(
            controller: controller,
            focusNode: focusNode,
            hintText: 'Search audio',
            categories: const <AppSearchCategory<int>>[
              AppSearchCategory(value: 0, label: 'All'),
            ],
            selectedCategory: 0,
            onCategorySelected: (_) {},
            onChanged: (_) {},
            onSubmitted: (_) {},
            onCloseOrClear: () {},
            blurEnabled: true,
            body: ListView.builder(
              controller: scrollController,
              itemCount: 20,
              itemBuilder: (context, index) => SizedBox(
                height: 60,
                child: Text(
                  'Item $index',
                  key: ValueKey<String>('search_result_item_$index'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester
            .getSize(
              find.byKey(const ValueKey<String>('app_search_body_layer')),
            )
            .height,
        800,
      );

      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();

      expect(
        tester
            .getSize(
              find.byKey(const ValueKey<String>('app_search_body_layer')),
            )
            .height,
        480,
      );
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).resizeToAvoidBottomInset,
        isFalse,
      );

      // Scroll to bottom item and verify it is placed above the keyboard (within the 480px visible body area)
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();

      final lastItemFinder = find.byKey(
        const ValueKey<String>('search_result_item_19'),
      );
      expect(lastItemFinder, findsOneWidget);
      final lastItemBottom =
          tester.getBottomLeft(lastItemFinder).dy;
      expect(lastItemBottom, lessThanOrEqualTo(480));
    },
  );
}
