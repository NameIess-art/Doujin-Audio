import 'package:doujin_audio/app/presentation/main_tab_state_mixin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('deep scroll returns from its near-top offset', (tester) async {
    final tabKey = GlobalKey<_ScrollToTopTestTabState>();
    await tester.pumpWidget(
      MaterialApp(home: _ScrollToTopTestTab(key: tabKey)),
    );

    final controller = tabKey.currentState!.controller;
    controller.jumpTo(1800);
    await tester.pump();

    tabKey.currentState!.jumpToTop();

    expect(controller.offset, 360);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.offset, 0);
  });

  testWidgets('short scroll keeps its current offset before animating to top', (
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

    tabKey.currentState!.jumpToTop();

    expect(controller.offset, shortOffset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(controller.offset, 0);
  });

  testWidgets('reduced motion returns directly to the top', (tester) async {
    final tabKey = GlobalKey<_ScrollToTopTestTabState>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: _ScrollToTopTestTab(key: tabKey)),
      ),
    );

    final controller = tabKey.currentState!.controller;
    controller.jumpTo(1800);
    await tester.pump();

    tabKey.currentState!.jumpToTop();

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
    body: ListView(
      controller: controller,
      children: const [SizedBox(height: 2400)],
    ),
  );
}
