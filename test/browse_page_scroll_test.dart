import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/browse_page_state_store.dart';
import 'package:doujin_audio/app/presentation/browse_page_scroll.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/glass_refresh_indicator.dart';

void main() {
  Widget page(
    BrowsePageStateStore store,
    ScrollController controller, {
    String key = 'page',
    int count = 40,
    double extent = 80,
    int start = 0,
    bool restoreReady = true,
    int columns = 1,
    bool fixedExtent = true,
    ScrollController? placeholderController,
    List<String>? ids,
  }) => ProviderScope(
    overrides: [browsePageStateStoreProvider.overrideWithValue(store)],
    child: MaterialApp(
      home: Scaffold(
        body: BrowsePageScroll(
          pageKey: key,
          controller: controller,
          restoreReady: restoreReady,
          anchorIds: ids ?? List.generate(count, (i) => '${i + start}'),
          child: LayoutBuilder(
            builder: (context, constraints) {
              BrowsePageScroll.setAnchorIds(
                context,
                ids ?? List.generate(count, (i) => '${i + start}'),
                columnCount: columns,
                rowExtent: extent,
              );
              return ListView.builder(
                controller: placeholderController ?? controller,
                itemExtent: fixedExtent ? extent : null,
                itemCount: (count / columns).ceil(),
                findChildIndexCallback: columns == 1 && fixedExtent
                    ? (key) {
                        if (key is! ValueKey<String>) return null;
                        final index = int.parse(key.value) - start;
                        return index >= 0 && index < count ? index : null;
                      }
                    : null,
                itemBuilder: (_, row) => columns == 1 && fixedExtent
                    ? BrowseAnchor(
                        key: ValueKey('${row + start}'),
                        id: ids?[row] ?? '${row + start}',
                        child: Text('item $row'),
                      )
                    : SizedBox(
                        height: extent,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var column = 0; column < columns; column++)
                              if (row * columns + column < count)
                                Expanded(
                                  child: BrowseAnchor(
                                    id:
                                        ids?[row * columns + column] ??
                                        '${row * columns + column + start}',
                                    child: Text(
                                      'item ${row * columns + column}',
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ),
              );
            },
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
    'large catalogs preserve a scrolled anchor across insertion and column reflow',
    (tester) async {
      final store = BrowsePageStateStore();
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(page(store, controller, count: 20000));
      await tester.pumpAndSettle();
      controller.jumpTo(1200000);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -80));
      await tester.pumpAndSettle();
      final saved = store.stateFor('page');
      final anchor = int.parse(saved['anchor'] as String);
      final anchorOffset = saved['anchorOffset'] as double;
      expect(anchor, greaterThanOrEqualTo(15000));
      await tester.pumpWidget(
        page(store, controller, count: 20005, start: -5, columns: 2),
      );
      await tester.pumpAndSettle();
      expect(
        controller.offset,
        closeTo(((anchor + 5) ~/ 2) * 80 - anchorOffset, 0.5),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'restoration uses the first duplicate ID in a large ordered snapshot',
    (tester) async {
      final store = BrowsePageStateStore();
      store.update('page', {
        'offset': 1600.0,
        'anchor': 'duplicate',
        'anchorOffset': 0.0,
      });
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final ids = List.generate(20000, (index) => '$index');
      ids[10] = ids[19900] = 'duplicate';
      await tester.pumpWidget(
        page(store, controller, count: ids.length, ids: ids),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, 800);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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

  for (final restoreReady in [false, true]) {
    testWidgets(
      'scrolling a placeholder preserves pending restoration when ready=$restoreReady',
      (tester) async {
        final store = BrowsePageStateStore();
        store.update('page', {'offset': 1800.0});
        final controller = ScrollController();
        final placeholderController = ScrollController();
        addTearDown(controller.dispose);
        addTearDown(placeholderController.dispose);

        await tester.pumpWidget(
          page(
            store,
            controller,
            restoreReady: restoreReady,
            placeholderController: placeholderController,
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.hasClients, isFalse);
        await tester.drag(find.byType(ListView), const Offset(0, -240));
        await tester.pumpAndSettle();
        expect(placeholderController.offset, greaterThan(0));
        expect(tester.takeException(), isNull);
        expect(store.stateFor('page')['offset'], 1800.0);

        await tester.pumpWidget(page(store, controller));
        await tester.pumpAndSettle();
        expect(controller.offset, 1800.0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'incomplete short content preserves the saved offset until restoration is ready',
    (tester) async {
      final store = BrowsePageStateStore();
      store.update('page', {'offset': 1800.0});
      final controller = ScrollController();

      await tester.pumpWidget(
        page(store, controller, count: 15, restoreReady: false),
      );
      await tester.pumpAndSettle();
      expect(controller.position.maxScrollExtent, greaterThan(0));
      expect(controller.position.maxScrollExtent, lessThan(1800));
      expect(controller.offset, 0);
      expect(store.stateFor('page')['offset'], 1800.0);

      await tester.pumpWidget(page(store, controller));
      await tester.pumpAndSettle();
      expect(controller.offset, 1800);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'user scrolling takes precedence while delayed content becomes ready',
    (tester) async {
      final store = BrowsePageStateStore();
      store.update('page', {'offset': 1800.0});
      final controller = ScrollController();
      await tester.pumpWidget(
        page(store, controller, count: 15, restoreReady: false),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(400);
      await tester.pumpAndSettle();
      final position = controller.position;
      await tester.pumpWidget(page(store, controller));
      await tester.pumpAndSettle();
      expect(controller.position, same(position));
      expect(controller.offset, 400);
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
  testWidgets('scrolled page preserves its anchor when rows are prepended', (
    tester,
  ) async {
    final store = BrowsePageStateStore();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(page(store, controller));
    await tester.pumpAndSettle();
    controller.jumpTo(640);
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(store, controller, count: 45, start: -5));
    await tester.pumpAndSettle();
    expect(controller.offset, 1040);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('top stays fixed when insertion also changes column count', (
    tester,
  ) async {
    final store = BrowsePageStateStore();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(page(store, controller, columns: 2));
    await tester.pumpAndSettle();
    controller.jumpTo(80);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(store, controller, count: 45, start: -5));
    expect(controller.offset, 0);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('pull refresh keeps new rows at the top on ${platform.name}', (
      tester,
    ) async {
      final store = BrowsePageStateStore();
      final controller = ScrollController();
      final indicator = GlobalKey<GlassRefreshIndicatorState>();
      final refresh = Completer<void>();
      final interaction = UiInteractionCoordinator.instance;
      addTearDown(interaction.resetForTest);
      addTearDown(controller.dispose);
      var ids = List.generate(40, (i) => '$i');
      var refreshCount = 0;
      final offsets = <double>[];
      controller.addListener(() => offsets.add(controller.offset));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [browsePageStateStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => BrowsePageScroll(
                  pageKey: 'page',
                  controller: controller,
                  anchorIds: ids,
                  child: GlassRefreshIndicator(
                    key: indicator,
                    lockChildWhileRefreshing: true,
                    onRefresh: () async {
                      refreshCount++;
                      await refresh.future;
                      interaction.scheduleCommit(
                        key: 'refresh-test-data',
                        structural: true,
                        commit: () => setState(() {
                          ids = [...List.generate(5, (i) => 'new$i'), ...ids];
                        }),
                      );
                    },
                    child: ListView.builder(
                      controller: controller,
                      padding: const EdgeInsets.only(top: 100, bottom: 80),
                      itemExtent: 80,
                      physics: AlwaysScrollableScrollPhysics(
                        parent: GlassRefreshIndicatorScrollPhysics(
                          isIndicatorVisible: () =>
                              indicator.currentState?.isIndicatorVisible ??
                              false,
                        ),
                      ),
                      itemCount: ids.length,
                      findChildIndexCallback: (key) =>
                          ids.indexOf((key as ValueKey<String>).value),
                      itemBuilder: (context, index) => BrowseAnchor(
                        key: ValueKey(ids[index]),
                        id: ids[index],
                        child: Text('item ${ids[index]}'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(refreshCount, 1);
      expect(controller.offset, 0);
      refresh.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pumpAndSettle();
      expect(ids.length, 45);
      expect(controller.offset, 0);
      expect(offsets, everyElement(0));
      expect(tester.getTopLeft(find.text('item new0')).dy, 100);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

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

  testWidgets('bottom anchor settles when variable rows change column count', (
    tester,
  ) async {
    final store = BrowsePageStateStore();
    final controller = ScrollController();
    for (final columns in [2, 1, 2, 3, 1, 3]) {
      await tester.pumpWidget(
        page(
          store,
          controller,
          count: 101,
          columns: columns,
          fixedExtent: false,
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.offset, controller.position.maxScrollExtent);
      expect(find.text('item 100'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('column reflow paints the visible anchor in its first frame', (
    tester,
  ) async {
    final store = BrowsePageStateStore();
    final controller = ScrollController();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(page(store, controller, count: 100, columns: 2));
    await tester.pumpAndSettle();
    controller.jumpTo(640);
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(find.text('item 16')).dy;
    expect(store.stateFor('page')['anchor'], '16');
    tester.view.physicalSize = const Size(400, 600);
    await tester.pumpWidget(page(store, controller, count: 100));
    expect(find.text('item 16'), findsOneWidget);
    expect(tester.getTopLeft(find.text('item 16')).dy, closeTo(top, 0.5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
