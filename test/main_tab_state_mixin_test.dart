import 'package:doujin_audio/app/presentation/main_tab_state_mixin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('deep scroll jumps directly to the top without animation', (
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

    // Jumps immediately to top without animation frames
    expect(controller.offset, 0);
  });

  testWidgets('short scroll jumps directly to the top without animation', (
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

    expect(controller.offset, 0);
  });

  testWidgets('scrollToTop when already at top is a no-op', (tester) async {
    final tabKey = GlobalKey<_ScrollToTopTestTabState>();
    await tester.pumpWidget(
      MaterialApp(home: _ScrollToTopTestTab(key: tabKey)),
    );

    final controller = tabKey.currentState!.controller;
    expect(controller.offset, 0);
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
