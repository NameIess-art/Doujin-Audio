import 'package:doujin_audio/core/widgets/page_translation_scope.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_header.dart';
import 'package:flutter/foundation.dart';
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
        Widget? subtitleStatus,
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
        subtitleStatus: subtitleStatus,
      );
      final original = header();
      expect(header().shouldRebuild(original), isFalse);
      expect(header(top: 24).shouldRebuild(original), isTrue);
      expect(header(max: 280).shouldRebuild(original), isTrue);
      expect(header(min: 100).shouldRebuild(original), isTrue);
      expect(header(bar: 48).shouldRebuild(original), isTrue);
      expect(header(onCopy: (_) {}).shouldRebuild(original), isTrue);
      expect(
        header(subtitleStatus: const Text('Subtitles')).shouldRebuild(original),
        isTrue,
      );
    },
  );

  for (final textScale in [1.0, 2.0]) {
    testWidgets(
      'collapsing work header reuses static metadata and title at $textScale scale',
      (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        tester.view.physicalSize = Size(
          defaultTargetPlatform == TargetPlatform.android
              ? (textScale == 1 ? 320 : 480)
              : 1280,
          800,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final copied = <String>[];
        final title = List.filled(30, 'A long work title 作品名称').join(' ');
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
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
                      title: title,
                      rjCode: 'RJ123456',
                      circleName: 'Circle',
                      coverWidget: const ColoredBox(color: Colors.blue),
                      accentColor: Colors.blue,
                      surfaceColor: Colors.white,
                      onCopyMetadata: copied.add,
                      subtitleStatus: const SizedBox(
                        width: 100,
                        child: Text(
                          'No subtitles',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
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
        final initialStatusRect = tester.getRect(find.text('No subtitles'));
        expect(
          initialStatusRect.center.dy,
          tester.getRect(find.text('RJ123456')).center.dy,
        );
        expect(initialStatusRect.right, tester.view.physicalSize.width - 16);
        final titleText = find.text(title);
        final titleElement = tester.element(titleText);
        final expandedTitleRect = tester.getRect(titleText);
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
          tester.getRect(find.text('No subtitles')).top,
          initialStatusRect.top - 48,
        );
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('work_detail_rj_copy')))
              .dy,
          initialRjTop - 48,
        );
        for (var offset = 64.0; offset <= 128; offset += 4) {
          controller.jumpTo(offset);
          await tester.pump();
        }
        expect(
          titleBuilds,
          0,
          reason: 'Crossing the old compact threshold must not rebuild text.',
        );
        expect(rjBuilds, 0);
        expect(
          tester
              .widget<WorkPageTranslationText>(
                find.byType(WorkPageTranslationText),
              )
              .style!
              .fontSize,
          17,
        );
        expect(tester.element(titleText), same(titleElement));
        expect(
          tester.getRect(titleText).height,
          closeTo(expandedTitleRect.height * 15 / 17, 0.01),
        );
        expect(tester.getRect(titleText).left, closeTo(16, 0.01));
        final coverRect = tester.getRect(
          find.byKey(const ValueKey('work_detail_cover_bounds')),
        );
        expect(
          tester.getRect(titleText).bottom,
          closeTo(coverRect.bottom - 10, 0.01),
        );
        for (final offset in [59.0, 61.0, 59.0, 61.0, 59.0, 61.0]) {
          controller.jumpTo(offset);
          await tester.pump();
          expect(
            tester.getRect(titleText).height,
            closeTo(
              expandedTitleRect.height * (1 - offset / 120 * 2 / 17),
              0.01,
            ),
          );
        }
        expect(titleBuilds, 0);
        await tester.tap(find.byKey(const ValueKey('work_detail_title_copy')));
        await tester.tap(find.byKey(const ValueKey('work_detail_rj_copy')));
        await tester.tap(find.byKey(const ValueKey('work_detail_circle_copy')));
        expect(copied, [title, 'RJ123456', 'Circle']);
        await tester.pumpWidget(const SizedBox());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }
}
