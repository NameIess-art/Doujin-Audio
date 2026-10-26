import 'package:doujin_audio/app/presentation/audio_ui_controllers.dart';
import 'package:doujin_audio/app/presentation/main_tab_state_mixin.dart';
import 'package:doujin_audio/core/widgets/scroll_to_top_list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'snapshot consumes content hits but leaves the scrollbar gutter live',
    (tester) async {
      final state = await _pumpTab(tester);
      state.controller.jumpTo(40000);
      await tester.pump();
      state.scrollToTop();
      await tester.pump();
      await tester.pump();
      final overlay = tester.renderObject<RenderBox>(
        find
            .ancestor(
              of: find.byType(RawImage),
              matching: find.byType(Positioned),
            )
            .last,
      );
      final viewport = tester.getRect(find.byType(ScrollToTopListView));
      expect(
        overlay.hitTest(
          BoxHitTestResult(),
          position: overlay.globalToLocal(viewport.center),
        ),
        isTrue,
      );
      expect(
        overlay.hitTest(
          BoxHitTestResult(),
          position: overlay.globalToLocal(
            viewport.topRight + const Offset(-2, 100),
          ),
        ),
        isFalse,
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'retained categories resolve the active controller at request time',
    (tester) async {
      final state = await _pumpTab(tester, secondaryList: true);
      state.controller.jumpTo(40000);
      state.secondaryController.jumpTo(60000);
      await tester.pump();
      state.selectedList.value = 1;
      await tester.pumpAndSettle();
      state.scrollToTop();
      await tester.pumpAndSettle();
      expect(state.secondaryController.offset, 0);
      expect(state.controller.offset, 40000);
    },
  );

  testWidgets(
    'hiding a page stops its animation before the ticker is silenced',
    (tester) async {
      final tickerEnabled = ValueNotifier(true);
      addTearDown(tickerEnabled.dispose);
      final state = await _pumpTab(tester, tickerEnabled: tickerEnabled);
      state.controller.jumpTo(40000);
      await tester.pump();
      state.scrollToTop();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      tickerEnabled.value = false;
      await tester.pump();
      final stopped = state.controller.offset;
      expect(stopped, greaterThan(0));
      expect(state.controller.position.isScrollingNotifier.value, isFalse);
      await tester.pump(const Duration(seconds: 1));
      tickerEnabled.value = true;
      await tester.pumpAndSettle();
      expect(state.controller.offset, stopped);
      expect(find.byType(RawImage), findsNothing);
    },
  );

  testWidgets(
    'distant return keeps the old picture and cross-fades while moving',
    (tester) async {
      final state = await _pumpTab(tester);
      state.controller.jumpTo(40000);
      await tester.pump();
      state.scrollToTop();
      expect(state.controller.offset, 40000);
      await tester.pump();
      await tester.pump();

      final snapshot = find.byType(RawImage);
      expect(snapshot, findsOneWidget);
      final image = tester.widget<RawImage>(snapshot).image!;
      final opacity = find.ancestor(
        of: snapshot,
        matching: find.byType(Opacity),
      );
      expect(tester.widget<Opacity>(opacity).opacity, 1);
      // The live list has already moved, but the first painted overlay still
      // contains the old row. Compare a real pixel instead of only the offset.
      final bytes = (await tester.runAsync(() => image.toByteData()))!;
      final expected = Colors.primaries[400 % Colors.primaries.length]
          .toARGB32();
      expect(bytes.getUint8(0), (expected >> 16) & 255);
      expect(bytes.getUint8(1), (expected >> 8) & 255);
      expect(bytes.getUint8(2), expected & 255);
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.widget<Opacity>(opacity).opacity, inExclusiveRange(0, 1));
      final transform = tester.widget<Transform>(
        find.ancestor(of: snapshot, matching: find.byType(Transform)).first,
      );
      expect(transform.transform.storage[13], greaterThan(0));
      await tester.pumpAndSettle();
      expect(state.controller.offset, 0);
      expect(snapshot, findsNothing);
      expect(image.debugDisposed, isTrue);
    },
  );

  testWidgets(
    'snapshot stays bounded on a large display and resize cancels it',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(3000, 2000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final state = await _pumpTab(tester);
      state.controller.jumpTo(40000);
      await tester.pump();
      state.scrollToTop();
      await tester.pump();
      await tester.pump();
      final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(image.width * image.height, lessThan(2004000));
      tester.view.physicalSize = const Size(2500, 1800);
      await tester.pump();
      final stopped = state.controller.offset;
      expect(state.controller.position.isScrollingNotifier.value, isFalse);
      expect(find.byType(RawImage), findsNothing);
      expect(image.debugDisposed, isTrue);
      await tester.pumpAndSettle();
      expect(state.controller.offset, stopped);
    },
  );

  testWidgets(
    'mouse wheel interrupts the old image and scrolls the live list',
    (tester) async {
      final state = await _pumpTab(tester);
      state.controller.jumpTo(40000);
      await tester.pump();
      state.scrollToTop();
      await tester.pump();
      await tester.pump();
      final offset = state.controller.offset;
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(100, 100),
          scrollDelta: Offset(0, 100),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RawImage), findsNothing);
      expect(state.controller.offset, offset + 100);
    },
  );

  testWidgets('cancel before capture cannot later move a hidden page', (
    tester,
  ) async {
    final state = await _pumpTab(tester);
    state.controller.jumpTo(40000);
    await tester.pump();
    state.scrollToTop();
    state.signals.requestStopScroll(0);
    await tester.pumpAndSettle();
    expect(state.controller.offset, 40000);
    expect(find.byType(RawImage), findsNothing);
  });

  testWidgets('touching the old image cancels without activating a new row', (
    tester,
  ) async {
    final state = await _pumpTab(tester);
    state.controller.jumpTo(40000);
    await tester.pump();
    state.scrollToTop();
    await tester.pump();
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    final offset = state.controller.offset;
    await tester.tapAt(const Offset(100, 100));
    await tester.pumpAndSettle();
    expect(state.controller.offset, offset);
    expect(state.tappedIndices, isEmpty);
    expect(find.byType(RawImage), findsNothing);
    await tester.tapAt(const Offset(100, 100));
    expect(state.tappedIndices, hasLength(1));
  });

  for (final fixedExtent in [true, false]) {
    for (final offset in [40000.0, 400000.0]) {
      testWidgets(
        'deep return bounds builds at $offset, fixedExtent=$fixedExtent',
        (tester) async {
          final state = await _pumpTab(tester, fixedExtent: fixedExtent);
          final controller = state.controller;
          controller.jumpTo(offset);
          await tester.pump();
          state.builtIndices.clear();

          state.signals.requestScrollToTop(0);
          expect(controller.offset, offset);
          await tester.pump();
          final start = controller.offset;
          expect(start, greaterThan(0));
          expect(
            start,
            lessThanOrEqualTo(controller.position.viewportDimension * 2),
          );
          expect(controller.position.isScrollingNotifier.value, isTrue);

          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(controller.offset, inExclusiveRange(0, start));
          for (var frame = 0; frame < 26; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          expect(controller.offset, 0);
          expect(controller.position.isScrollingNotifier.value, isFalse);
          // Exclude the initial deep jump: returning must only build near the
          // top, including variable-height lists without extent hints.
          expect(state.builtIndices, isNotEmpty);
          expect(state.builtIndices.length, lessThan(80));
          expect(state.builtIndices.every((index) => index < 80), isTrue);
          debugPrint(
            'Return from $offset, fixedExtent=$fixedExtent: '
            '${state.builtIndices.length} item builds',
          );
        },
      );
    }
  }

  for (final keepAliveIndex in [0, 4000]) {
    testWidgets('return preserves requested keep-alive at $keepAliveIndex', (
      tester,
    ) async {
      final state = await _pumpTab(
        tester,
        fixedExtent: false,
        keepAliveIndex: keepAliveIndex,
      );
      final position = state.controller.position;
      final row = find.byType(_KeptAliveRow, skipOffstage: false);
      final initialRowState = keepAliveIndex == 0 ? tester.state(row) : null;
      state.controller.jumpTo(400000);
      await tester.pump();
      final rowState = initialRowState ?? tester.state(row);

      state.scrollToTop();
      await tester.pumpAndSettle();
      expect(state.controller.offset, 0);
      expect(state.controller.position, same(position));
      expect(tester.state(row), same(rowState));
    });
  }

  testWidgets('short return animates directly from the current offset', (
    tester,
  ) async {
    final state = await _pumpTab(tester);
    final controller = state.controller;
    final start = controller.position.viewportDimension / 2;
    controller.jumpTo(start);
    await tester.pump();

    state.scrollToTop();
    expect(controller.offset, start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, inExclusiveRange(0, start));
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
  });

  testWidgets('disabled animations jump directly to the top', (tester) async {
    final state = await _pumpTab(tester, disableAnimations: true);
    state.controller.jumpTo(40000);
    await tester.pump();

    state.scrollToTop();
    expect(state.controller.offset, 0);
    expect(state.controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('already at top and inactive tab signals do not scroll', (
    tester,
  ) async {
    final state = await _pumpTab(tester);
    state.scrollToTop();
    expect(state.controller.offset, 0);
    expect(state.controller.position.isScrollingNotifier.value, isFalse);

    state.controller.jumpTo(400);
    await tester.pump();
    state.signals.requestScrollToTop(1);
    await tester.pumpAndSettle();
    expect(state.controller.offset, 400);
  });

  testWidgets('page-switch stop signal cancels the return animation', (
    tester,
  ) async {
    final state = await _pumpTab(tester);
    state.controller.jumpTo(40000);
    await tester.pump();
    state.scrollToTop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    state.signals.requestStopScroll(0);
    final stoppedOffset = state.controller.offset;
    expect(stoppedOffset, greaterThan(0));
    await tester.pumpAndSettle();
    expect(state.controller.offset, stoppedOffset);
  });

  testWidgets('manual drag interrupts the return animation', (tester) async {
    final state = await _pumpTab(tester);
    state.controller.jumpTo(40000);
    await tester.pump();
    state.scrollToTop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ScrollToTopListView)),
    );
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    final dragOffset = state.controller.offset;
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.controller.offset, dragOffset);
    expect(dragOffset, greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('repeated requests finish and disposal cancels safely', (
    tester,
  ) async {
    final state = await _pumpTab(tester);
    state.controller.jumpTo(40000);
    await tester.pump();
    state.signals.requestScrollToTop(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    state.signals.requestScrollToTop(0);
    await tester.pumpAndSettle();
    expect(state.controller.offset, 0);

    state.controller.jumpTo(40000);
    await tester.pump();
    state.scrollToTop();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<_ScrollToTopTestTabState> _pumpTab(
  WidgetTester tester, {
  bool fixedExtent = true,
  bool disableAnimations = false,
  int? keepAliveIndex,
  bool secondaryList = false,
  ValueNotifier<bool>? tickerEnabled,
}) async {
  final key = GlobalKey<_ScrollToTopTestTabState>();
  Widget tab = _ScrollToTopTestTab(
    key: key,
    fixedExtent: fixedExtent,
    keepAliveIndex: keepAliveIndex,
    secondaryList: secondaryList,
  );
  if (tickerEnabled != null) {
    tab = ValueListenableBuilder<bool>(
      valueListenable: tickerEnabled,
      child: tab,
      builder: (_, enabled, child) =>
          TickerMode(enabled: enabled, child: child!),
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: tab,
        ),
      ),
    ),
  );
  return key.currentState!;
}

class _ScrollToTopTestTab extends StatefulWidget {
  const _ScrollToTopTestTab({
    super.key,
    required this.fixedExtent,
    this.keepAliveIndex,
    this.secondaryList = false,
  });

  final bool fixedExtent;
  final int? keepAliveIndex;
  final bool secondaryList;

  @override
  State<_ScrollToTopTestTab> createState() => _ScrollToTopTestTabState();
}

class _ScrollToTopTestTabState extends State<_ScrollToTopTestTab>
    with MainTabStateMixin<_ScrollToTopTestTab> {
  final controller = ScrollController();
  final secondaryController = ScrollController();
  final selectedList = ValueNotifier<int>(0);
  final signals = MainScreenController();
  final builtIndices = <int>[];
  final tappedIndices = <int>[];

  @override
  int get tabIndex => 0;

  @override
  ScrollController get mainScrollController =>
      selectedList.value == 0 ? controller : secondaryController;

  @override
  void initState() {
    super.initState();
    initTabState(signals.scrollToTopTab, signals.stopScrollTab);
  }

  @override
  void dispose() {
    disposeTabState();
    signals.dispose();
    controller.dispose();
    secondaryController.dispose();
    selectedList.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: buildScrollToTopTransition(
      widget.secondaryList
          ? ValueListenableBuilder<int>(
              valueListenable: selectedList,
              builder: (_, index, _) => IndexedStack(
                index: index,
                children: [_list(controller), _list(secondaryController)],
              ),
            )
          : _list(controller),
    ),
  );

  Widget _list(ScrollController controller) => ScrollToTopListView.builder(
    controller: controller,
    itemCount: 10000,
    itemExtent: widget.fixedExtent ? 100 : null,
    itemBuilder: (context, index) {
      builtIndices.add(index);
      if (index == widget.keepAliveIndex) return const _KeptAliveRow();
      return GestureDetector(
        onTap: () => tappedIndices.add(index),
        child: ColoredBox(
          color: Colors.primaries[index % Colors.primaries.length],
          child: SizedBox(height: index.isEven ? 60 : 140),
        ),
      );
    },
  );
}

class _KeptAliveRow extends StatefulWidget {
  const _KeptAliveRow();

  @override
  State<_KeptAliveRow> createState() => _KeptAliveRowState();
}

class _KeptAliveRowState extends State<_KeptAliveRow>
    with AutomaticKeepAliveClientMixin<_KeptAliveRow> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return const SizedBox(height: 60);
  }
}
