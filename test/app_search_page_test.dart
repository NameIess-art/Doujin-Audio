import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/core/widgets/app_glass_surface.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';

void main() {
  testWidgets('search selection fades controls while keeping its mask steady', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'query');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    late StateSetter update;
    var selecting = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AppSearchPageScaffold<int>(
              controller: controller,
              focusNode: focusNode,
              hintText: 'Search',
              categories: const [AppSearchCategory(value: 0, label: 'All')],
              selectedCategory: 0,
              onCategorySelected: (_) {},
              onChanged: (_) {},
              onSubmitted: (_) {},
              onCloseOrClear: () {},
              controlsOverlay: selecting
                  ? const TopPageHeader(topCapsuleTitle: 'Selected 1')
                  : null,
              body: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
    final mask = find.byKey(const ValueKey('app_search_top_fade_mask'));
    final maskElement = tester.element(mask);
    update(() => selecting = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(mask, findsOneWidget);
    expect(tester.element(mask), same(maskElement));
    for (final switcher in tester.widgetList<AnimatedSwitcher>(find.byType(AnimatedSwitcher))) {
      expect(switcher.duration, const Duration(milliseconds: 300));
    }
    final fades = find.descendant(
      of: find.byType(AppHeaderTransition),
      matching: find.byWidgetPredicate(
        (widget) => widget is FadeTransition &&
            widget.opacity.value > 0 && widget.opacity.value < 1,
      ),
    );
    expect(fades, findsNWidgets(2));
    for (final fade in tester.widgetList<FadeTransition>(fades)) {
      expect(
        fade.opacity.value,
        closeTo(kAppFadeCurve.transform(0.5), 0.001),
      );
    }
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    update(() => selecting = false);
    await tester.pumpAndSettle();
    expect(controller.text, 'query');
    expect(find.byType(TextField), findsOneWidget);
    expect(mask, findsOneWidget);
    expect(tester.element(mask), same(maskElement));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fading search requests focus once after entrance completes', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
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
    var selectedCategory = 0;
    final route = buildAppPageRoute<void>(
      context: routeContext,
      slide: false,
      child: StatefulBuilder(
        builder: (context, setState) => AppSearchPageScaffold<int>(
          controller: controller,
          focusNode: focusNode,
          hintText: 'Search',
          categories: const [
            AppSearchCategory(value: 0, label: 'All'),
            AppSearchCategory(value: 1, label: 'Tags'),
          ],
          selectedCategory: selectedCategory,
          onCategorySelected: (category) {
            focusNode.unfocus();
            setState(() => selectedCategory = category);
          },
          onChanged: (_) {},
          onSubmitted: (_) {},
          onCloseOrClear: () {},
          body: const SizedBox.expand(),
        ),
      ),
    );
    unawaited(Navigator.of(routeContext).push(route));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 150));
    expect(route.animation!.value, closeTo(0.5, 0.01));
    expect(focusNode.hasFocus, isFalse);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('app_search_category_1')));
    await tester.pumpAndSettle();
    expect(selectedCategory, 1);
    expect(focusNode.hasFocus, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('search safe area, side margins and row gap block result input', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var bodyTaps = 0;
    var closes = 0;
    var categories = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            padding: EdgeInsets.only(top: 24),
          ),
          child: AppSearchPageScaffold<int>(
            controller: controller,
            focusNode: focusNode,
            hintText: 'Search',
            categories: const [AppSearchCategory(value: 0, label: 'All')],
            selectedCategory: 0,
            onCategorySelected: (_) => categories++,
            onChanged: (_) {},
            onSubmitted: (_) {},
            onCloseOrClear: () => closes++,
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => bodyTaps++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.getRect(
      find.byKey(const ValueKey('app_search_field_shell')),
    );
    for (final point in [
      const Offset(4, 8),
      Offset(4, field.center.dy),
      Offset(400, field.bottom + 3),
    ]) {
      await tester.tapAt(point);
    }
    expect(bodyTaps, 0);
    await tester.tap(find.byKey(const ValueKey('app_search_close')));
    await tester.tap(find.byKey(const ValueKey('app_search_category_0')));
    expect(closes, 1);
    expect(categories, 1);
    await tester.enterText(find.byType(TextField), 'query');
    expect(controller.text, 'query');
    await tester.tapAt(const Offset(400, 200));
    expect(bodyTaps, 1);
  });

  testWidgets('keyboard animation does not rebuild search result content', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    addTearDown(tester.view.resetViewInsets);
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppSearchPageScaffold<int>(
          controller: controller,
          focusNode: focusNode,
          hintText: 'Search audio',
          categories: const [AppSearchCategory(value: 0, label: 'All')],
          selectedCategory: 0,
          onCategorySelected: (_) {},
          onChanged: (_) {},
          onSubmitted: (_) {},
          onCloseOrClear: () {},
          body: Builder(
            builder: (context) {
              builds++;
              // ASMR results use the full MediaQuery to configure their list.
              MediaQuery.of(context);
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initialBuilds = builds;
    for (final bottom in [80.0, 160.0, 240.0, 320.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: bottom);
      await tester.pump();
    }
    expect(builds, initialBuilds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search route opens and closes without page animation', (
    tester,
  ) async {
    late BuildContext routeContext;
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
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

    final route = buildAppPageRoute<void>(
      context: routeContext,
      duration: Duration.zero,
      child: AppSearchPageScaffold<int>(
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
        onCloseOrClear: () => Navigator.of(routeContext).pop(),

        body: const SizedBox.expand(
          key: ValueKey<String>('instant_search_body'),
        ),
      ),
    );
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);

    unawaited(Navigator.of(routeContext).push(route));
    await tester.pump();

    final page = find.byType(AppSearchPageScaffold<int>);
    expect(page, findsOneWidget);
    expect(route.animation!.status, AnimationStatus.completed);
    expect(
      tester.getTopLeft(
        find.byKey(const ValueKey<String>('instant_search_body')),
      ),
      Offset.zero,
    );
    expect(
      tester.getTopLeft(
        find.byKey(const ValueKey<String>('app_search_field_shell')),
      ),
      const Offset(16, 6),
    );
    for (final transitionType in [
      SlideTransition,
      FadeTransition,
      ShaderMask,
    ]) {
      expect(
        find.ancestor(of: page, matching: find.byType(transitionType)),
        findsNothing,
      );
    }
    expect(find.byType(ShaderMask), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('app_search_close')));
    await tester.pump();
    expect(page, findsNothing);
    expect(tester.takeException(), isNull);
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
        tester
            .getSize(
              find.byKey(const ValueKey<String>('app_search_category_0')),
            )
            .height,
        32,
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
      expect(fadeMask.opacity, 1);
      expect(fadeGradient.colors.first.a, closeTo(0.82 * 0.9, 1e-6));
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

  testWidgets('search blurs only its three control capsules', (
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

          body: const SizedBox.expand(),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('app_search_controls_overlay')),
        matching: find.byType(BackdropFilter),
      ),
      findsNWidgets(3),
    );
    expect(find.byType(AppGlassSurface), findsNWidgets(3));
    final filters = tester.renderObjectList<RenderBackdropFilter>(
      find.byType(BackdropFilter),
    ).toList();
    expect(filters.first.backdropKey, isNotNull);
    expect(filters.every((filter) =>
        identical(filter.backdropKey, filters.first.backdropKey)), isTrue);
    final surfaces = find.byType(AppGlassSurface).evaluate().map(
      (element) => tester.getRect(find.byWidget(element.widget)),
    ).toList();
    for (var i = 0; i < surfaces.length; i++) {
      for (var j = i + 1; j < surfaces.length; j++) {
        expect(surfaces[i].overlaps(surfaces[j]), isFalse);
      }
    }
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('app_search_body_layer')),
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
      final lastItemBottom = tester.getBottomLeft(lastItemFinder).dy;
      expect(lastItemBottom, lessThanOrEqualTo(480));
    },
  );

  testWidgets(
    'search category selection capsule uses ClampingScrollPhysics',
    (tester) async {
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
              AppSearchCategory(value: 0, label: 'Cat 0'),
              AppSearchCategory(value: 1, label: 'Cat 1'),
              AppSearchCategory(value: 2, label: 'Cat 2'),
            ],
            selectedCategory: 0,
            onCategorySelected: (_) {},
            onChanged: (_) {},
            onSubmitted: (_) {},
            onCloseOrClear: () {},
            body: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();

      final categoryList = tester.widget<ListView>(
        find.byKey(const ValueKey<String>('app_search_categories')),
      );
      expect(categoryList.physics, isA<ClampingScrollPhysics>());
    },
  );
}
