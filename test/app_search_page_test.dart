import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/widgets/app_search_page.dart';

void main() {
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
            data: MediaQueryData.fromView(
              tester.view,
            ).copyWith(textScaler: const TextScaler.linear(2)),
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
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey<String>('app_search_close')));
      expect(closeCount, 1);
    },
  );
}
