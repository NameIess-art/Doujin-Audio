import 'package:doujin_audio/app/presentation/main_tab_state_mixin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('deep scroll animates only the final two viewports', (
    tester,
  ) async {
    final tabKey = GlobalKey<_ScrollToTopTestTabState>();
    await tester.pumpWidget(
      MaterialApp(home: _ScrollToTopTestTab(key: tabKey)),
    );

    final controller = tabKey.currentState!.controller;
    controller.jumpTo(40000);
    await tester.pump();

    tabKey.currentState!.scrollToTop();

    final animationStart = controller.offset;
    expect(animationStart, controller.position.viewportDimension * 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(animationStart));
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
  });

  testWidgets('short scroll animates from its current position', (
    tester,
  ) async {
    final tabKey = GlobalKey<_ScrollToTopTestTabState>();
    await tester.pumpWidget(
      MaterialApp(home: _ScrollToTopTestTab(key: tabKey)),
    );

    final controller = tabKey.currentState!.controller;
    final shortOffset = controller.position.viewportDimension / 2;
    controller.jumpTo(shortOffset);
    await tester.pump();

    tabKey.currentState!.scrollToTop();

    expect(controller.offset, shortOffset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(shortOffset));
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
  });

  testWidgets('reduced motion returns to the top immediately', (tester) async {
    final tabKey = GlobalKey<_ScrollToTopTestTabState>();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _ScrollToTopTestTab(key: tabKey),
        ),
      ),
    );

    final controller = tabKey.currentState!.controller;
    controller.jumpTo(40000);
    await tester.pump();
    tabKey.currentState!.scrollToTop();

    expect(controller.offset, 0);
  });
}

class _ScrollToTopTestTab extends StatefulWidget {
  const _ScrollToTopTestTab({super.key});

  @override
  State<_ScrollToTopTestTab> createState() => _ScrollToTopTestTabState();
}

class _ScrollToTopTestTabState extends State<_ScrollToTopTestTab>
    with MainTabStateMixin<_ScrollToTopTestTab> {
  final controller = ScrollController();

  @override
  int get tabIndex => 0;

  @override
  ScrollController get mainScrollController => controller;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView.builder(
      controller: controller,
      itemCount: 1000,
      itemExtent: 100,
      itemBuilder: (context, index) => const SizedBox.shrink(),
    ),
  );
}
