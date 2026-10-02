import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/browse_page_state_store.dart';
import 'package:doujin_audio/app/presentation/browse_page_scroll.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';

void main() {
  Widget page(
    BrowsePageStateStore store,
    ScrollController controller, {
    String key = 'page',
    int count = 40,
    double extent = 80,
    int start = 0,
  }) => ProviderScope(
    overrides: [browsePageStateStoreProvider.overrideWithValue(store)],
    child: MaterialApp(
      home: Scaffold(
        body: BrowsePageScroll(
          pageKey: key,
          controller: controller,
          anchorIds: List.generate(count, (i) => '${i + start}'),
          child: ListView.builder(
            controller: controller,
            itemExtent: extent,
            itemCount: count,
            itemBuilder: (_, index) => BrowseAnchor(
              id: '${index + start}',
              child: Text('item $index'),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('recreated page restores position and visible anchor', (
    tester,
  ) async {
    final store = BrowsePageStateStore();
    final first = ScrollController();
    await tester.pumpWidget(page(store, first));
    await tester.pumpAndSettle();
    first.jumpTo(640);
    await tester.pumpAndSettle();
    expect(store.stateFor('page')['offset'], 640);
    expect(store.stateFor('page')['anchor'], '8');
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    final reopened = ScrollController();
    await tester.pumpWidget(page(store, reopened));
    await tester.pumpAndSettle();
    expect(reopened.offset, 640);
    await tester.pumpWidget(const SizedBox());
    reopened.dispose();
  });

  testWidgets(
    'restoration waits for asynchronous content and clamps removed rows',
    (tester) async {
      final store = BrowsePageStateStore();
      store.update('page', {'offset': 2600.0});
      final controller = ScrollController();
      await tester.pumpWidget(page(store, controller, count: 0));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page(store, controller, count: 15));
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.maxScrollExtent);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'cleared page state is not resurrected by mounted scroll widgets',
    (tester) async {
      final store = BrowsePageStateStore();
      final controller = ScrollController();
      await tester.pumpWidget(page(store, controller));
      await tester.pumpAndSettle();
      controller.jumpTo(480);
      await tester.pumpAndSettle();
      store.clear();
      controller.jumpTo(720);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(store.stateFor('page'), isEmpty);
      controller.dispose();
    },
  );
  testWidgets(
    'fresh user scrolling resumes persistence after clearing a retained page',
    (tester) async {
      final store = BrowsePageStateStore();
      final controller = ScrollController();
      await tester.pumpWidget(page(store, controller));
      await tester.pumpAndSettle();
      controller.jumpTo(480);
      await tester.pumpAndSettle();
      store.clear();
      await tester.drag(find.byType(ListView), const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(store.stateFor('page')['offset'], controller.offset);
      expect(controller.offset, greaterThan(480));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'stable item restores outside old lazy window after layout and list changes',
    (tester) async {
      final store = BrowsePageStateStore();
      store.update('page', {
        'offset': 1600.0,
        'anchor': '20',
        'anchorOffset': 0.0,
      });
      final controller = ScrollController();
      await tester.pumpWidget(
        page(store, controller, count: 100, extent: 160, start: -10),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, 4800);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'page key switch retains registered anchors for reused children',
    (tester) async {
      final store = BrowsePageStateStore();
      final controller = ScrollController();
      await tester.pumpWidget(page(store, controller));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page(store, controller, key: 'other'));
      await tester.pumpAndSettle();
      controller.jumpTo(640);
      await tester.pumpAndSettle();
      expect(store.stateFor('other')['anchor'], '8');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets('mounted page preserves stable row when layout height changes', (
    tester,
  ) async {
    final store = BrowsePageStateStore();
    final controller = ScrollController();
    await tester.pumpWidget(page(store, controller));
    await tester.pumpAndSettle();
    controller.jumpTo(640);
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(store, controller, extent: 160));
    await tester.pumpAndSettle();
    expect(controller.offset, 1280);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('queued layout restoration yields to a user scroll', (
    tester,
  ) async {
    final store = BrowsePageStateStore();
    final controller = ScrollController();
    await tester.pumpWidget(page(store, controller));
    await tester.pumpAndSettle();
    controller.jumpTo(640);
    await tester.pumpAndSettle();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        controller.animateTo(
          1800,
          duration: const Duration(milliseconds: 200),
          curve: Curves.linear,
        ),
      );
    });
    await tester.pumpWidget(page(store, controller, extent: 160));
    await tester.pumpAndSettle();
    expect(controller.offset, 1800);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
