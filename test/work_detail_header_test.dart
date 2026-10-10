import 'package:doujin_audio/core/widgets/page_translation_scope.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'header invalidates cached content for geometry and callback changes',
    () {
      void copy(String value) {}
      WorkDetailHeaderDelegate header({
        double top = 0,
        double max = 240,
        double min = 120,
        double bar = 44,
        ValueChanged<String>? onCopy,
      }) => WorkDetailHeaderDelegate(
        topSafeArea: top,
        coverMaxHeight: max,
        coverMinHeight: min,
        rjBarHeight: bar,
        title: 'Title',
        rjCode: 'RJ123456',
        circleName: 'Circle',
        coverWidget: const SizedBox(),
        accentColor: Colors.blue,
        surfaceColor: Colors.white,
        onCopyMetadata: onCopy ?? copy,
      );
      final original = header();
      expect(header().shouldRebuild(original), isFalse);
      expect(header(top: 24).shouldRebuild(original), isTrue);
      expect(header(max: 280).shouldRebuild(original), isTrue);
      expect(header(min: 100).shouldRebuild(original), isTrue);
      expect(header(bar: 48).shouldRebuild(original), isTrue);
      expect(header(onCopy: (_) {}).shouldRebuild(original), isTrue);
    },
  );

  testWidgets(
    'collapsing work header reuses static metadata and title',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final copied = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: WorkDetailHeaderDelegate(
                    topSafeArea: 0,
                    coverMaxHeight: 240,
                    coverMinHeight: 120,
                    rjBarHeight: 44,
                    title: 'A work title',
                    rjCode: 'RJ123456',
                    circleName: 'Circle',
                    coverWidget: const ColoredBox(color: Colors.blue),
                    accentColor: Colors.blue,
                    surfaceColor: Colors.white,
                    onCopyMetadata: copied.add,
                  ),
                ),
                SliverList.builder(
                  itemCount: 100,
                  itemBuilder: (_, index) =>
                      SizedBox(height: 60, child: Text('track $index')),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initialRjTop = tester
          .getTopLeft(find.byKey(const ValueKey('work_detail_rj_copy')))
          .dy;
      var titleBuilds = 0;
      var rjBuilds = 0;
      final previousCallback = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousCallback?.call(element, builtOnce);
        if (element.widget is WorkPageTranslationText) titleBuilds++;
        if (element.widget case Text(data: 'RJ123456')) rjBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousCallback);
      for (var offset = 4.0; offset <= 48; offset += 4) {
        controller.jumpTo(offset);
        await tester.pump();
      }
      expect(titleBuilds, 0);
      expect(rjBuilds, 0);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('work_detail_rj_copy'))).dy,
        initialRjTop - 48,
      );
      for (var offset = 64.0; offset <= 128; offset += 4) {
        controller.jumpTo(offset);
        await tester.pump();
      }
      expect(
        titleBuilds,
        1,
        reason: 'Only crossing the compact title threshold rebuilds text.',
      );
      expect(rjBuilds, 0);
      expect(
        tester
            .widget<WorkPageTranslationText>(
              find.byType(WorkPageTranslationText),
            )
            .style!
            .fontSize,
        15,
      );
      await tester.tap(find.byKey(const ValueKey('work_detail_rj_copy')));
      await tester.tap(find.byKey(const ValueKey('work_detail_circle_copy')));
      expect(copied, ['RJ123456', 'Circle']);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
