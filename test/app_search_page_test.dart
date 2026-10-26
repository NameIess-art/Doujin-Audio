import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/core/widgets/app_glass_surface.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';

void main() {
  testWidgets(
    'confirmation is a circular header button between input and clear',
    (tester) async {
      final controller = TextEditingController(text: 'query');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var confirms = 0;
      var clears = 0;
      var enabled = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return AppSearchPageScaffold<int>(
                controller: controller,
                focusNode: focus,
                hintText: 'Search',
                showConfirmButton: true,
                confirmLabel: 'Confirm search',
                onConfirm: enabled ? () => confirms++ : null,
                onCloseOrClear: () => clears++,
                onChanged: (_) {},
                onSubmitted: (_) => confirms++,
                body: const SizedBox.expand(),
              );
            },
          ),
        ),
      );
      final confirm = find.byKey(const ValueKey('app_search_confirm'));
      final field = find.byKey(const ValueKey('app_search_field_shell'));
      final clear = find.byKey(const ValueKey('app_search_close'));
      for (final width in [280.0, 400.0, 1280.0]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpAndSettle();
        expect(tester.getSize(confirm), const Size(38, 38));
        expect(tester.getRect(field).right + 8, tester.getRect(confirm).left);
        expect(tester.getRect(confirm).right + 8, tester.getRect(clear).left);
        expect(tester.getCenter(confirm).dy, tester.getCenter(field).dy);
        expect(tester.getCenter(clear).dy, tester.getCenter(field).dy);
        expect(find.byTooltip('Confirm search'), findsOneWidget);
        final material = tester.widget<Material>(
          find.ancestor(of: confirm, matching: find.byType(Material)).first,
        );
        expect(material.shape, const CircleBorder());
        expect(tester.takeException(), isNull);
      }
      await tester.tap(confirm);
      await tester.tap(clear);
      expect(confirms, 1);
      expect(clears, 1);
      update(() => enabled = false);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(confirm).onPressed, isNull);
      await tester.tap(confirm);
      expect(confirms, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'vertical result scrolling dismisses keyboard and preserves query',
    (tester) async {
      final controller = TextEditingController(text: 'query');
      final focusNode = FocusNode();
      final scroll = ScrollController();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      addTearDown(scroll.dispose);
      const verticalKey = ValueKey('vertical_results');
      const horizontalKey = ValueKey('horizontal_results');
      await tester.pumpWidget(
        MaterialApp(
          home: AppSearchPageScaffold<int>(
            controller: controller,
            focusNode: focusNode,
            hintText: 'Search',
            categories: const [AppSearchCategory(value: 0, label: 'All')],
            selectedCategory: 0,
            onCategorySelected: (_) {},
            onChanged: (_) {},
            onSubmitted: (_) {},
            onCloseOrClear: () {},
            body: Column(
              children: [
                const SizedBox(height: 120),
                SizedBox(
                  height: 60,
                  child: ListView.builder(
                    key: horizontalKey,
                    scrollDirection: Axis.horizontal,
                    itemCount: 30,
                    itemExtent: 100,
                    itemBuilder: (_, index) => Text('Tag $index'),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    key: verticalKey,
                    controller: scroll,
                    itemCount: 100,
                    itemExtent: 60,
                    itemBuilder: (_, index) => Text('Result $index'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('app_search_field'));
      await tester.showKeyboard(field);
      expect(tester.testTextInput.isVisible, isTrue);
      scroll.jumpTo(120);
      await tester.pumpAndSettle();
      expect(focusNode.hasFocus, isTrue);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byKey(horizontalKey)),
          scrollDelta: const Offset(150, 0),
        ),
      );
      await tester.pumpAndSettle();
      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.drag(find.byKey(verticalKey), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(controller.text, 'query');
      expect(scroll.offset, greaterThan(120));

      await tester.showKeyboard(field);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byKey(verticalKey)),
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();
      expect(focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(controller.text, 'query');
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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

  for (final hasCategories in [false, true]) {
    testWidgets(
      'search slides in and out while its header fades for 300 ms (categories: $hasCategories)',
      (tester) async {
        final controller = TextEditingController();
        final focusNode = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focusNode.dispose);
        final navigator = GlobalKey<NavigatorState>();
        final surface = GlobalKey();
        const lowerPageColor = Color(0xff0000ff);
        Future<Color> headerPixel(Offset point) async =>
            (await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(surface),
              );
              final image = await boundary.toImage();
              final data = await image.toByteData();
              final offset =
                  (point.dy.floor() * image.width + point.dx.floor()) * 4;
              final color = Color.fromARGB(
                data!.getUint8(offset + 3),
                data.getUint8(offset),
                data.getUint8(offset + 1),
                data.getUint8(offset + 2),
              );
              image.dispose();
              return color;
            }))!;
        await tester.pumpWidget(
          RepaintBoundary(
            key: surface,
            child: MaterialApp(
              navigatorKey: navigator,
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                extensions: [
                  AppDesignTokens.light.copyWith(barGlassEnabled: true),
                ],
                colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)
                    .copyWith(
                      surface: Colors.black,
                      surfaceContainerHigh: const Color(0xffff0000),
                    ),
              ),
              builder: (_, child) => AppPageTransitionHost(child: child!),
              home: const Scaffold(backgroundColor: lowerPageColor),
            ),
          ),
        );
        final route = buildAppPageRoute<void>(
          context: navigator.currentContext!,
          separateHeader: true,
          child: AppSearchPageScaffold<int>(
            controller: controller,
            focusNode: focusNode,
            hintText: 'Search',
            categories: hasCategories
                ? const [AppSearchCategory(value: 0, label: 'All')]
                : const [],
            selectedCategory: 0,
            onCategorySelected: (_) {},
            onChanged: (_) {},
            onSubmitted: (_) {},
            onCloseOrClear: () => navigator.currentState!.pop(),
            body: const SizedBox.expand(key: ValueKey('sliding_search_body')),
          ),
        );
        expect(route.transitionDuration, const Duration(milliseconds: 300));
        expect(
          route.reverseTransitionDuration,
          const Duration(milliseconds: 300),
        );
        unawaited(navigator.currentState!.push(route));
        await tester.pump();
        await tester.pump();
        final body = find.byKey(const ValueKey('sliding_search_body'));
        final width = tester.getSize(find.byType(Scaffold).last).width;
        final header = find.byKey(const ValueKey('app_search_field_shell'));
        final headerRect = tester.getRect(header);
        const leftBodyPoint = Offset(8, 250);
        final rightBodyPoint = Offset(width - 8, 250);
        expect(tester.getTopLeft(body).dx, width);
        expect(await headerPixel(leftBodyPoint), lowerPageColor);
        expect(await headerPixel(rightBodyPoint), lowerPageColor);
        final points = [
          for (final key in [
            'app_search_field_shell',
            'app_search_close',
            if (hasCategories) 'app_search_category_shell',
          ])
            tester.getRect(find.byKey(ValueKey(key))).centerRight -
                const Offset(12, 0),
        ];
        for (final point in points) {
          expect(await headerPixel(point), lowerPageColor);
        }
        await tester.pump(const Duration(milliseconds: 150));
        expect(route.animation!.value, closeTo(0.5, 0.001));
        expect(tester.getTopLeft(body).dx, inExclusiveRange(0, width));
        expect(tester.getRect(header), headerRect);
        expect(await headerPixel(leftBodyPoint), lowerPageColor);
        expect(await headerPixel(rightBodyPoint), Colors.black);
        final entering = [for (final point in points) await headerPixel(point)];
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.getTopLeft(body).dx, 0);
        expect(await headerPixel(leftBodyPoint), Colors.black);
        expect(await headerPixel(rightBodyPoint), Colors.black);
        final settled = [for (final point in points) await headerPixel(point)];
        for (var i = 0; i < points.length; i++) {
          expect(settled[i].r, greaterThan(0.2));
          expect(
            entering[i].r,
            closeTo(settled[i].r * kAppFadeCurve.transform(0.5), 0.01),
          );
        }
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.getTopLeft(body).dx, inExclusiveRange(0, width));
        expect(tester.getRect(header), headerRect);
        expect(await headerPixel(leftBodyPoint), lowerPageColor);
        expect(await headerPixel(rightBodyPoint), Colors.black);
        for (var i = 0; i < points.length; i++) {
          expect(
            (await headerPixel(points[i])).r,
            closeTo(settled[i].r * kAppFadeCurve.transform(0.5), 0.01),
          );
        }
        await tester.pumpAndSettle();
        expect(body, findsNothing);
        expect(await headerPixel(leftBodyPoint), lowerPageColor);
        expect(await headerPixel(rightBodyPoint), lowerPageColor);
        for (final point in points) {
          expect(await headerPixel(point), lowerPageColor);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('sliding search requests focus once after entrance completes', (
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
      separateHeader: true,
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

  testWidgets('keyboard animation does not rebuild search controls or results', (
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
          showConfirmButton: true,
          onConfirm: () {},
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
    final fieldShell = tester.widget(
      find.byKey(const ValueKey('app_search_field_shell')),
    );
    for (final bottom in [80.0, 160.0, 240.0, 320.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: bottom);
      await tester.pump();
      expect(
        tester.widget(find.byKey(const ValueKey('app_search_field_shell'))),
        same(fieldShell),
        reason: 'Keyboard metrics must not rebuild the search controls.',
      );
    }
    expect(builds, initialBuilds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard motion defers results and covers until metrics settle', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator.instance;
    coordinator.resetForTest();
    addTearDown(coordinator.resetForTest);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetPhysicalSize);
    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: AppSearchPageScaffold<int>(
          controller: controller,
          focusNode: focusNode,
          hintText: 'Search',
          categories: const [AppSearchCategory(value: 0, label: 'All')],
          selectedCategory: 0,
          onCategorySelected: (_) {},
          onChanged: (_) {},
          onSubmitted: (_) {},
          onCloseOrClear: () {},
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pump();
    expect(coordinator.isInteracting, isFalse);

    for (final insets in [
      [80.0, 160.0, 320.0],
      [160.0, 80.0, 0.0],
    ]) {
      var results = 0;
      var covers = 0;
      tester.view.viewInsets = FakeViewPadding(bottom: insets.first);
      coordinator.scheduleCommit(key: 'search-results', commit: () => results++);
      coordinator.scheduleCommit(
        key: 'search-cover',
        allowDuringScroll: true,
        commit: () => covers++,
      );
      for (final bottom in insets) {
        tester.view.viewInsets = FakeViewPadding(bottom: bottom);
        await tester.pump(const Duration(milliseconds: 100));
        expect(results, 0);
        expect(covers, 0);
        expect(coordinator.isVisualUpdateDeferred, isTrue);
        expect(coordinator.navigationAllowed.value, isTrue);
      }
      await tester.pump(coordinator.idleDelay);
      await tester.pump();
      expect(results, 1);
      expect(covers, 1);
      expect(coordinator.isVisualUpdateDeferred, isFalse);
    }

    tester.view.viewInsets = const FakeViewPadding(bottom: 80);
    expect(coordinator.isInteracting, isTrue);
    unawaited(
      navigatorKey.currentState!.push(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(coordinator.isInteracting, isFalse);
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    expect(coordinator.isInteracting, isFalse);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    expect(coordinator.isInteracting, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(coordinator.isInteracting, isFalse);
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
      expect(tester.getSize(fadeMaskFinder).height, 136);
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
        findsNothing,
      );
      expect(
        tester
            .widgetList<AppGlassSurface>(find.byType(AppGlassSurface))
            .map((surface) => surface.enabled),
        everyElement(isFalse),
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

  testWidgets('search fades its three glass capsules with independent samples', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: [AppDesignTokens.light.copyWith(barGlassEnabled: true)],
        ),
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
    expect(filters.map((filter) => filter.backdropKey), everyElement(isNull));
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
  }, variant: const TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  }));

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

  testWidgets(
    'search results fade in and out over 300ms and hide confirm button',
    (tester) async {
      final controller = TextEditingController();
      final focusNode = FocusNode();
      final showResults = ValueNotifier<bool>(false);
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      addTearDown(showResults.dispose);

      double fadeOpacityOf(Finder finder) {
        final fade = tester.widget<FadeTransition>(
          find
              .ancestor(of: finder, matching: find.byType(FadeTransition))
              .first,
        );
        return fade.opacity.value;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: showResults,
            builder: (_, hasResults, _) => AppSearchPageScaffold<int>(
              controller: controller,
              focusNode: focusNode,
              hintText: 'Search audio',
              showConfirmButton: !hasResults,
              onConfirm: () => showResults.value = true,
              categories: const <AppSearchCategory<int>>[],
              selectedCategory: 0,
              onCategorySelected: (_) {},
              onChanged: (_) => showResults.value = false,
              onSubmitted: (_) => showResults.value = true,
              onCloseOrClear: () => showResults.value = false,
              body: const SizedBox.expand(
                key: ValueKey<String>('test_suggestions'),
              ),
              resultsBody: hasResults
                  ? const SizedBox.expand(
                      key: ValueKey<String>('test_results'),
                    )
                  : null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final suggestions = find.byKey(const ValueKey<String>('test_suggestions'));
      final results = find.byKey(const ValueKey<String>('test_results'));
      final confirm = find.byKey(const ValueKey<String>('app_search_confirm'));

      expect(suggestions, findsOneWidget);
      expect(results, findsNothing);
      expect(confirm, findsOneWidget);

      showResults.value = true;
      await tester.pump();
      expect(suggestions, findsOneWidget);
      expect(results, findsOneWidget);
      expect(fadeOpacityOf(results), 0);

      await tester.pump(const Duration(milliseconds: 150));
      expect(
        fadeOpacityOf(results),
        closeTo(kAppFadeCurve.transform(0.5), 0.001),
      );
      expect(
        fadeOpacityOf(suggestions),
        closeTo(1 - kAppFadeCurve.transform(0.5), 0.001),
      );

      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(results, findsOneWidget);
      expect(suggestions, findsNothing);
      expect(confirm, findsNothing);

      showResults.value = false;
      await tester.pump();
      expect(suggestions, findsOneWidget);
      expect(results, findsOneWidget);
      expect(fadeOpacityOf(results), 1);

      await tester.pump(const Duration(milliseconds: 150));
      expect(
        fadeOpacityOf(results),
        closeTo(kAppFadeCurve.transform(0.5), 0.001),
      );
      expect(
        fadeOpacityOf(suggestions),
        closeTo(1 - kAppFadeCurve.transform(0.5), 0.001),
      );

      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(suggestions, findsOneWidget);
      expect(results, findsNothing);
      expect(confirm, findsOneWidget);
    },
  );
}
