import 'package:doujin_audio/core/widgets/page_translation_scope.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_header.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'RJ and circle support tap, action menus and hover in $brightness',
      (tester) async {
        final copied = <String>[];
        final capture = GlobalKey();
        final theme = ThemeData(brightness: brightness);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: RepaintBoundary(
                key: capture,
                child: SizedBox(
                  width: 400,
                  height: 300,
                  child: CustomScrollView(
                    slivers: [
                      SliverPersistentHeader(
                        delegate: WorkDetailHeaderDelegate(
                          topSafeArea: 0,
                          coverMaxHeight: 240,
                          coverMinHeight: 120,
                          rjBarHeight: 44,
                          title: 'Title',
                          rjCode: 'RJ123456',
                          circleName: 'Circle',
                          coverWidget: const ColoredBox(color: Colors.blue),
                          accentColor: theme.colorScheme.primary,
                          surfaceColor: theme.colorScheme.surface,
                          onCopyMetadata: copied.add,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<List<int>> pixel(Offset point) async =>
            (await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(capture),
              );
              final image = await boundary.toImage();
              final bytes = (await image.toByteData())!;
              final offset =
                  (point.dy.floor() * image.width + point.dx.floor()) * 4;
              final result = bytes.buffer
                  .asUint8List(bytes.offsetInBytes + offset, 4)
                  .toList();
              image.dispose();
              return result;
            }))!;
        final isWindows = defaultTargetPlatform == TargetPlatform.windows;
        final mouse = isWindows
            ? await tester.createGesture(kind: PointerDeviceKind.mouse)
            : null;
        if (mouse != null) {
          await mouse.addPointer(location: const Offset(500, 500));
          addTearDown(mouse.removePointer);
        }
        for (final entry in {'rj': 'RJ123456', 'circle': 'Circle'}.entries) {
          final target = find.byKey(ValueKey('work_detail_${entry.key}_copy'));
          final targetRect = tester.getRect(target);
          final textRect = tester.getRect(find.text(entry.value));
          expect(targetRect.width, closeTo(textRect.width, 0.01));
          expect(targetRect.height, closeTo(textRect.height + 4, 0.01));
          if (mouse != null) {
            final rect = tester.getRect(target);
            final point = Offset(rect.center.dx, rect.top + 3);
            final before = await pixel(point);
            await mouse.moveTo(rect.center);
            await tester.pumpAndSettle();
            expect(await pixel(point), isNot(before), reason: entry.key);
            await mouse.moveTo(const Offset(500, 500));
            await tester.pumpAndSettle();
            expect(await pixel(point), before, reason: entry.key);
          }
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(copied.last, entry.value);
          final count = copied.length;
          if (isWindows) {
            await tester.tap(
              target,
              buttons: kSecondaryMouseButton,
              kind: PointerDeviceKind.mouse,
            );
          } else {
            await tester.longPress(target);
          }
          await tester.pumpAndSettle();
          expect(copied.length, count);
          expect(find.text('Search online'), findsOneWidget);
          expect(find.text('Search locally'), findsOneWidget);
          await tester.ensureVisible(find.text('Copy'));
          await tester.tap(find.text('Copy'));
          await tester.pumpAndSettle();
          expect(copied.last, entry.value);
          expect(copied.length, count + 1);
        }
        expect(copied, ['RJ123456', 'RJ123456', 'Circle', 'Circle']);
        final title = find.byKey(const ValueKey('work_detail_title_copy'));
        final titleText = find.descendant(
          of: title,
          matching: find.byType(RichText),
        );
        Color? titleColor() =>
            tester.widget<RichText>(titleText).text.style?.color;
        expect(
          tester.getSize(title).width,
          closeTo(tester.getSize(titleText).width, 0.01),
        );
        expect(titleColor(), Colors.white);
        if (mouse != null) {
          await mouse.moveTo(tester.getCenter(title));
          await tester.pumpAndSettle();
          expect(titleColor(), theme.colorScheme.primary);
          await mouse.moveTo(const Offset(500, 500));
          await tester.pumpAndSettle();
          expect(titleColor(), Colors.white);
        }
        await tester.tap(title);
        await tester.pumpAndSettle();
        expect(copied.last, 'Title');
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'missing cover hides scrolled content in $brightness',
      (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final capture = GlobalKey();
        late StateSetter updateBody;
        var bodyColor = Colors.red;
        final theme = ThemeData(brightness: brightness);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: capture,
              child: Scaffold(
                body: CustomScrollView(
                  controller: scroll,
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: WorkDetailHeaderDelegate(
                        topSafeArea: 24,
                        coverMaxHeight: 240,
                        coverMinHeight: 120,
                        rjBarHeight: 44,
                        title: 'Title',
                        rjCode: 'RJ123456',
                        circleName: 'Circle',
                        coverWidget: const CoverFallbackArtwork(),
                        accentColor: theme.colorScheme.primary,
                        surfaceColor: theme.colorScheme.surface,
                        onCopyMetadata: (_) {},
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: StatefulBuilder(
                        builder: (context, setState) {
                          updateBody = setState;
                          return SizedBox(
                            height: 1600,
                            child: ColoredBox(color: bodyColor),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<List<int>> sample(Offset point) async {
          return (await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(capture),
            );
            final image = await boundary.toImage();
            final bytes = (await image.toByteData())!;
            final offset =
                (point.dy.floor() * image.width + point.dx.floor()) * 4;
            final pixel = bytes.buffer
                .asUint8List(bytes.offsetInBytes + offset, 4)
                .toList();
            image.dispose();
            return pixel;
          }))!;
        }

        Future<void> expectMetadataBoundary({required bool hasShadow}) async {
          final bar = tester.getRect(
            find.byKey(const ValueKey('work_detail_metadata_bar')),
          );
          final surfaceColor = theme.colorScheme.surface;
          expect(await sample(Offset(8, bar.bottom - 0.5)), [
            for (final channel in [
              surfaceColor.r,
              surfaceColor.g,
              surfaceColor.b,
              surfaceColor.a,
            ])
              (channel * 255).round(),
          ]);
          final shadow = await sample(Offset(8, bar.bottom + 2));
          final body = await sample(Offset(8, bar.bottom + 16));
          expect(shadow.first, hasShadow ? lessThan(body.first) : body.first);
        }

        await expectMetadataBoundary(hasShadow: false);
        scroll.jumpTo(120);
        await tester.pumpAndSettle();
        await expectMetadataBoundary(hasShadow: false);
        scroll.jumpTo(300);
        await tester.pumpAndSettle();
        await expectMetadataBoundary(hasShadow: true);
        final cover = tester.getRect(
          find.byKey(const ValueKey('work_detail_cover_bounds')),
        );
        final point = cover.topLeft + const Offset(8, 50);
        final before = await sample(point);
        final bodyPoint = Offset(8, cover.bottom + 100);
        final beforeBody = await sample(bodyPoint);
        updateBody(() => bodyColor = Colors.green);
        await tester.pump();
        expect(await sample(bodyPoint), isNot(beforeBody));
        expect(
          await sample(point),
          before,
          reason: 'The fallback cover must obscure content painted underneath.',
        );
        expect(find.byType(CoverFallbackArtwork), findsOneWidget);
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        await expectMetadataBoundary(hasShadow: false);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

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
      'collapsing work header retains one fixed-size title at $textScale scale',
      (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        tester.view.physicalSize = Size(
          defaultTargetPlatform == TargetPlatform.android ? 480 : 1280,
          800,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final copied = <String>[];
        Future<void> copy(Finder target) async {
          if (defaultTargetPlatform == TargetPlatform.windows) {
            await tester.tap(
              target,
              buttons: kSecondaryMouseButton,
              kind: PointerDeviceKind.mouse,
            );
            await tester.pumpAndSettle();
            final copyAction = find.widgetWithIcon(
              ListTile,
              Icons.content_copy_rounded,
            );
            await tester.scrollUntilVisible(
              copyAction,
              200,
              scrollable: find
                  .descendant(
                    of: find.byType(BottomSheet),
                    matching: find.byType(Scrollable),
                  )
                  .last,
            );
            await tester.pumpAndSettle();
            await tester.tap(copyAction);
            await tester.pumpAndSettle();
          } else {
            await tester.tap(target);
          }
        }

        final title = List.filled(
          12,
          'A long work title 作品名称・作品タイトル',
        ).join(' ');
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
        expect(find.byType(BackdropFilter), findsNothing);
        expect(
          find.ancestor(
            of: find.byKey(const ValueKey('work_detail_rj_copy')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Container &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration! as BoxDecoration).color == Colors.white,
            ),
          ),
          findsOneWidget,
          reason: 'The metadata row uses the opaque page surface without blur.',
        );
        final titleText = find.descendant(
          of: find.byKey(const ValueKey('work_detail_title_copy')),
          matching: find.byType(RichText),
        );
        final paragraph = tester.renderObject<RenderParagraph>(titleText);
        final titleSize = paragraph.size;
        expect(titleSize.width, greaterThan(0));
        expect(titleSize.height, greaterThan(0));
        expect(
          find.byKey(
            const ValueKey('work_detail_title_copy'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<WorkPageTranslationText>(
                find.byType(WorkPageTranslationText),
              )
              .style!
              .fontSize,
          15,
        );
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(title))),
          findsOneWidget,
        );
        final initialRjTop = tester
            .getTopLeft(find.byKey(const ValueKey('work_detail_rj_copy')))
            .dy;
        final initialStatusRect = tester.getRect(find.text('No subtitles'));
        expect(
          initialStatusRect.center.dy,
          tester.getRect(find.text('RJ123456')).center.dy,
        );
        expect(initialStatusRect.right, tester.view.physicalSize.width - 16);
        var titleBuilds = 0;
        var rjBuilds = 0;
        final titleLayouts = <String>[];
        final paragraphId = describeIdentity(paragraph);
        final previousPrint = debugPrint;
        final previousPrintLayouts = debugPrintLayouts;
        debugPrint = (message, {wrapWidth}) {
          if (message != null && message.startsWith('Laying out')) {
            if (message.contains(paragraphId)) titleLayouts.add(message);
          } else {
            previousPrint(message, wrapWidth: wrapWidth);
          }
        };
        debugPrintLayouts = true;
        addTearDown(() {
          debugPrint = previousPrint;
          debugPrintLayouts = previousPrintLayouts;
        });
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
        expect(titleBuilds, 0);
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
        for (final offset in [59.0, 61.0, 60.0, 61.0, 59.0, 61.0]) {
          controller.jumpTo(offset);
          await tester.pump();
          expect(
            tester
                .widget<WorkPageTranslationText>(
                  find.byType(WorkPageTranslationText),
                )
                .style!
                .fontSize,
            15,
          );
          expect(
            tester.renderObject<RenderParagraph>(titleText),
            same(paragraph),
          );
          expect(paragraph.size, titleSize);
          expect(
            find.byKey(const ValueKey('work_detail_title_copy')),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel(RegExp(RegExp.escape(title))),
            findsOneWidget,
          );
          final coverRect = tester.getRect(
            find.byKey(const ValueKey('work_detail_cover_bounds')),
          );
          expect(
            tester
                .getRect(find.byKey(const ValueKey('work_detail_title_copy')))
                .bottom,
            closeTo(coverRect.bottom - 10, 0.01),
          );
          await copy(find.byKey(const ValueKey('work_detail_title_copy')));
        }
        expect(copied, List.filled(6, title));
        copied.clear();
        expect(titleBuilds, 0);
        expect(
          titleLayouts,
          isEmpty,
          reason: 'Scrolling must reuse the fixed-size title layout.',
        );
        debugPrint = previousPrint;
        debugPrintLayouts = previousPrintLayouts;
        await copy(find.byKey(const ValueKey('work_detail_rj_copy')));
        await copy(find.byKey(const ValueKey('work_detail_circle_copy')));
        expect(copied, ['RJ123456', 'Circle']);
        tester.view.physicalSize = Size(
          tester.view.physicalSize.width - 40,
          800,
        );
        await tester.pumpAndSettle();
        expect(paragraph.size.width, tester.view.physicalSize.width - 32);
        await tester.pumpWidget(const SizedBox());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }
}
