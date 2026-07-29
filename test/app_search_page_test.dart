import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:nameless_audio/core/widgets/app_search_page.dart';

void main() {
  testWidgets('search route uses a fade-through transition', (tester) async {
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
    expect((transition as FadeTransition).child, isA<ScaleTransition>());
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
        44,
      );
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey<String>('app_search_category_shell')),
            )
            .height,
        40,
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
      expect(tester.getSize(fadeMaskFinder).height, 324);
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
      expect(fadeGradient.stops, const <double>[0, 0.32, 0.72, 1]);
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
        32,
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
        findsNWidgets(2),
      );
      final inputDecorator = tester.widget<InputDecorator>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('app_search_field')),
          matching: find.byType(InputDecorator),
        ),
      );
      expect(inputDecorator.decoration.filled, isFalse);
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

  testWidgets('keyboard insets do not relayout the search result tree', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.view.resetViewInsets();
    });

    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var bodyBuildCount = 0;

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
          body: Builder(
            builder: (context) {
              bodyBuildCount++;
              return Text(
                '${MediaQuery.viewInsetsOf(context).bottom}',
                key: const ValueKey<String>('search_body_keyboard_inset'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('0.0'), findsOneWidget);
    final initialBuildCount = bodyBuildCount;

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();

    expect(find.text('0.0'), findsOneWidget);
    expect(bodyBuildCount, initialBuildCount);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).resizeToAvoidBottomInset,
      isFalse,
    );
  });
}
