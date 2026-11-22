import 'dart:async';

import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_buttons.dart';
import 'package:doujin_audio/core/widgets/app_dialog.dart';
import 'package:doujin_audio/core/widgets/app_entry_ink_well.dart';
import 'package:doujin_audio/core/widgets/app_glass_surface.dart';
import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:doujin_audio/core/widgets/unified_popup_menu.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/app/presentation/work_detail_navigation.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entries.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entry_tile.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  final coordinator = UiInteractionCoordinator.instance;
  setUp(coordinator.resetForTest);
  tearDown(coordinator.resetForTest);

  testWidgets(
    'menus blur the backdrop beyond the originating pane',
    (tester) async {
      final captureKey = GlobalKey();
      final menuOverlay = GlobalKey<OverlayState>();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            theme: ThemeData(
              extensions: [AppDesignTokens.light.copyWith(barGlassEnabled: true)],
            ),
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var index = 0; index < 100; index++)
                        Expanded(
                          child: ColoredBox(
                            color: index.isEven ? Colors.black : Colors.white,
                          ),
                        ),
                    ],
                  ),
                  Positioned(
                    left: 30,
                    top: 36,
                    width: 520,
                    height: 230,
                    child: MobileOverlayInset(
                      bottomInset: 0,
                      menuOverlayKey: menuOverlay,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned(
                            left: 150,
                            top: 64,
                            width: 240,
                            height: 80,
                            child: UnifiedContextMenuRegion(
                              shape: const StadiumBorder(),
                              openOnAndroidLongPress: true,
                              buildEntries: () => [
                                UnifiedMenuEntry.action(
                                  value: () {},
                                  label: 'Action',
                                ),
                              ],
                              child: const SizedBox.expand(),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            top: 12,
                            child: UnifiedPopupMenuButton<int>(
                              icon: Icons.add_rounded,
                              tooltip: 'Add',
                              entries: const [
                                UnifiedMenuEntry.action(
                                  value: 1,
                                  label: 'Add folder',
                                ),
                              ],
                              onSelected: (_) {},
                            ),
                          ),
                          Overlay(key: menuOverlay),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      Future<(int, int)> stripeContrast() async {
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = boundary.toImageSync();
        try {
          final bytes = (await tester.runAsync(image.toByteData))!;
          int red(int x, int y) => bytes.getUint8((y * image.width + x) * 4);
          int contrast(int y) => (red(220, y) - red(228, y)).abs();
          return (contrast(120), contrast(350));
        } finally {
          image.dispose();
        }
      }

      expect(await stripeContrast(), (255, 255));
      const trigger = Offset(406, 144);
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await tester.tapAt(
          trigger,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
      } else {
        await tester.longPressAt(trigger);
      }
      await tester.pumpAndSettle();
      expect(find.text('Action'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppGlassSurface),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      final (highlighted, background) = await stripeContrast();
      expect(highlighted, greaterThan(180));
      expect(background, lessThan(40));

      final highlight = find.descendant(
        of: find.byType(UnifiedContextMenuRegion),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.position == DecorationPosition.foreground &&
              widget.decoration is ShapeDecoration,
        ),
      );
      double highlightAlpha() =>
          (tester.widget<DecoratedBox>(highlight).decoration as ShapeDecoration)
              .color!
              .a;
      final openAlpha = highlightAlpha();
      await tester.tapAt(const Offset(40, 240));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(highlightAlpha(), closeTo(openAlpha / 2, 0.001));
      await tester.pumpAndSettle();
      expect(highlight, findsNothing);
      expect(find.byType(AppModalBackground), findsNothing);
      expect(await stripeContrast(), (255, 255));

      if (defaultTargetPlatform == TargetPlatform.windows) {
        await tester.tap(find.byTooltip('Add'));
        await tester.pumpAndSettle();
        expect(find.text('Add folder'), findsOneWidget);
        final (insidePane, outsidePane) = await stripeContrast();
        expect(insidePane, lessThan(40));
        expect(outsidePane, lessThan(40));
        await tester.tapAt(const Offset(40, 240));
        await tester.pumpAndSettle();
        expect(await stripeContrast(), (255, 255));
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('Windows text right-click menu keeps selection and add styling', (
    tester,
  ) async {
    const text = 'Select these words';
    final controller = TextEditingController(text: text);
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Center(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              contextMenuBuilder: buildAppEditableTextMenu,
            ),
          ),
        ),
      ),
    );
    final field = find.byType(TextField);
    await tester.tapAt(tester.getTopLeft(field) + const Offset(20, 20));
    await tester.pump();
    await tester.tapAt(
      tester.getTopLeft(field) + const Offset(20, 20),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    final selectAll = find.byIcon(Icons.select_all_rounded);
    final row = find.ancestor(of: selectAll, matching: find.byType(AppEntryInkWell));
    expect(tester.getSize(row), const Size(236, 48));
    expect(find.byType(AppModalBackground), findsNothing);
    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    expect(controller.selection.textInside(text), text);
    expect(focusNode.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('button menu highlights the first row on the initial mouse move', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerLeft,
            child: UnifiedPopupMenuButton<int>(
              icon: Icons.add,
              tooltip: 'Add',
              entries: const [
                UnifiedMenuEntry.action(value: 1, label: 'Add folder'),
                UnifiedMenuEntry.action(value: 2, label: 'Add file'),
                UnifiedMenuEntry.action(value: 3, label: 'Add library'),
              ],
              onSelected: (value) => selected = value,
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    final anchor = tester.getCenter(find.byTooltip('Add'));
    await mouse.addPointer(location: anchor);
    await mouse.down(anchor);
    await mouse.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 8));

    final first = find.text('Add folder');
    final second = find.text('Add file');
    bool isHighlighted(Finder row) {
      final dynamic material = Material.of(tester.element(row));
      final features = material.debugInkFeatures as Iterable<InkFeature>?;
      return features?.whereType<InkHighlight>().any((ink) => ink.color.a > 0) ??
          false;
    }

    expect(Focus.of(tester.element(first)).hasFocus, isFalse);
    expect(isHighlighted(first), isFalse);

    final firstRow = find.ancestor(
      of: first,
      matching: find.byType(AppEntryInkWell),
    );
    final paintedRow = tester.getRect(firstRow);
    await mouse.moveTo(Offset(paintedRow.center.dx, paintedRow.top + 0.25));
    await tester.pump();
    expect(isHighlighted(first), isTrue);
    expect(
      Material.of(tester.element(first)) as RenderObject,
      paints..rect(
        color: appHoverTint(Theme.of(tester.element(first)).colorScheme),
      ),
    );
    await mouse.moveTo(tester.getCenter(second));
    await tester.pumpAndSettle();
    expect(isHighlighted(second), isTrue);
    await mouse.moveTo(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(isHighlighted(second), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(first)).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(first, findsNothing);
  });

  for (final interruptOpening in [false, true]) {
    testWidgets(
      'Windows toolbar menu scales around the trigger (interrupted: $interruptOpening)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: Center(
                child: UnifiedPopupMenuButton<int>(
                  icon: Icons.more_vert,
                  tooltip: 'Open toolbar menu',
                  entries: const [
                    UnifiedMenuEntry.action(value: 1, label: 'Menu action'),
                  ],
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        );
        final trigger = find.byTooltip('Open toolbar menu');
        final anchor = tester.getCenter(trigger);
        await tester.tap(trigger);
        await tester.pump();

        final action = find.text('Menu action');
        final menuTransform = find
            .ancestor(
              of: action,
              matching: find.byElementPredicate(
                (element) =>
                    element is RenderObjectElement &&
                    element.renderObject is RenderTransform,
              ),
            )
            .first;
        final menu = tester.renderObject<RenderTransform>(menuTransform).child!;
        final pivot = menu.globalToLocal(anchor);
        double scale() => menu.getTransformTo(null).entry(0, 0);

        var previous = scale();
        expect(previous, lessThan(1));
        final openingFrames = interruptOpening ? 4 : 13;
        for (var frame = 0; frame < openingFrames; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final current = scale();
          expect(current, inInclusiveRange(previous, 1));
          expect(
            (menu.localToGlobal(pivot) - anchor).distance,
            lessThan(0.001),
          );
          previous = current;
        }
        expect(previous, interruptOpening ? lessThan(1) : equals(1));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(scale(), closeTo(previous, 0.001));
        for (var frame = 0; frame < 13; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (action.evaluate().isEmpty) break;
          final current = scale();
          expect(current, inInclusiveRange(0.88, previous));
          expect(
            (menu.localToGlobal(pivot) - anchor).distance,
            lessThan(0.001),
          );
          previous = current;
        }
        expect(action, findsNothing);
      },
    );
  }

  for (final atLeft in [false, true]) {
    testWidgets(
      'context menu grows toward its final bounds (left: $atLeft)',
      (tester) async {
        late BuildContext hostContext;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                hostContext = context;
                return const Scaffold();
              },
            ),
          ),
        );
        final result = showUnifiedContextMenu<int>(
          context: hostContext,
          globalPosition: Offset(atLeft ? 2 : 798, 596),
          entries: const [UnifiedMenuEntry.action(value: 1, label: 'Anchored')],
        );
        await tester.pump();
        final menuTransform = find.ancestor(
          of: find.text('Anchored'),
          matching: find.byElementPredicate(
            (element) =>
                element is RenderObjectElement &&
                element.renderObject is RenderTransform,
          ),
        ).first;
        final box = tester.renderObject<RenderTransform>(menuTransform).child!;
        final corner = Offset(atLeft ? 0 : box.size.width, box.size.height);
        final pinnedPoint = box.localToGlobal(corner);
        var scale = box.getTransformTo(null).entry(0, 0);
        expect(scale, lessThan(0.75));
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final nextScale = box.getTransformTo(null).entry(0, 0);
          expect(nextScale, inInclusiveRange(scale, 0.75));
          final cornerInViewport = box.localToGlobal(corner);
          expect(cornerInViewport.dx, closeTo(pinnedPoint.dx, 0.001));
          expect(cornerInViewport.dy, closeTo(pinnedPoint.dy, 0.001));
          scale = nextScale;
        }
        expect(scale, 0.75);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(await result, isNull);
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  testWidgets('context menu highlights the first hover at its animated edge', (
    tester,
  ) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Builder(
          builder: (context) {
            hostContext = context;
            return const Scaffold();
          },
        ),
      ),
    );
    const anchor = Offset(780, 590);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: anchor);
    final menu = showUnifiedContextMenu<int>(
      context: hostContext,
      globalPosition: anchor,
      entries: [
        for (var i = 1; i <= 11; i++)
          UnifiedMenuEntry.action(value: i, label: 'Action $i'),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 165));

    final first = find.text('Action 1');
    final second = find.text('Action 2');
    final row = find.ancestor(of: first, matching: find.byType(AppEntryInkWell));
    final bounds = tester.getRect(row);
    await mouse.moveTo(Offset(bounds.center.dx, bounds.top + 0.02));
    await tester.pump();

    Iterable<InkHighlight> highlights(Finder label) {
      final dynamic material = Material.of(tester.element(label));
      final features = material.debugInkFeatures as Iterable<InkFeature>?;
      return features?.whereType<InkHighlight>().where(
            (ink) => ink.color.a > 0,
          ) ??
          const <InkHighlight>[];
    }

    expect(highlights(first), isNotEmpty);
    expect(
      Material.of(tester.element(first)) as RenderObject,
      paints..rect(
        color: appHoverTint(Theme.of(tester.element(first)).colorScheme),
      ),
    );
    expect(highlights(second), isEmpty);
    await mouse.down(tester.getCenter(first));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(await menu, 1);
  });

  for (final side in [Alignment.centerLeft, Alignment.centerRight]) {
    for (final mode in ['button', 'dock', 'context']) {
      testWidgets(
        '$mode menu fits its longest label and left aligns at $side',
        (tester) async {
          const entries = [
            UnifiedMenuEntry.action(
              value: 1,
              label: 'Short',
              icon: Icons.folder,
            ),
            UnifiedMenuEntry.action(value: 2, label: 'Long option'),
          ];
          await tester.pumpWidget(
            MaterialApp(
              home: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 300,
                  child: Navigator(
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (context) => Scaffold(
                        body: Align(
                          alignment: side,
                          child: Builder(
                            builder: (context) => mode == 'button'
                                ? UnifiedPopupMenuButton<int>(
                                    icon: Icons.more_vert,
                                    tooltip: 'Open aligned menu',
                                    entries: entries,
                                    onSelected: (_) {},
                                  )
                                : TextButton(
                                    onPressed: () {
                                      final anchor =
                                          context.findRenderObject()!
                                              as RenderBox;
                                      final overlay =
                                          Overlay.of(
                                                context,
                                              ).context.findRenderObject()!
                                              as RenderBox;
                                      final rect =
                                          anchor.localToGlobal(Offset.zero) &
                                          anchor.size;
                                      unawaited(
                                        mode == 'context'
                                            ? showUnifiedContextMenu<int>(
                                                context: context,
                                                globalPosition: rect.center,
                                                entries: entries,
                                              )
                                            : showDockAwareMenu<int>(
                                                context: context,
                                                position: RelativeRect.fromRect(
                                                  rect.shift(
                                                    -overlay.localToGlobal(
                                                      Offset.zero,
                                                    ),
                                                  ),
                                                  Offset.zero & overlay.size,
                                                ),
                                                entries: entries,
                                              ),
                                      );
                                    },
                                    child: const Text('Open aligned menu'),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(
            find.byTooltip('Open aligned menu').evaluate().isEmpty
                ? find.text('Open aligned menu')
                : find.byTooltip('Open aligned menu'),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AppModalBackground), findsOneWidget);
          expect(find.byType(BackdropFilter), findsWidgets);
          final firstLabel = find.text('Short');
          final card = find
              .ancestor(of: firstLabel, matching: find.byType(ClipRRect))
              .first;
          final rows = find.descendant(
            of: card,
            matching: find.byType(AppEntryInkWell),
          );
          final cardBounds = tester.getRect(card);
          final firstRow = tester.getRect(rows.first);
          final lastRow = tester.getRect(rows.last);
          expect(firstRow.top, cardBounds.top);
          expect(lastRow.bottom, cardBounds.bottom);
          final menuScale = mode == 'button' ? 1.0 : 0.75;
          final rowHeight = 48 * menuScale;
          expect(firstRow.height, closeTo(rowHeight, 0.01));
          expect(lastRow.height, closeTo(rowHeight, 0.01));
          expect(
            rows.first.hitTestable(at: const Alignment(0, -0.95)),
            findsOneWidget,
          );

          Rect glyphBounds(String label) {
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(
                of: find.text(label),
                matching: find.byType(RichText),
              ),
            );
            final bounds = paragraph
                .getBoxesForSelection(
                  TextSelection(baseOffset: 0, extentOffset: label.length),
                )
                .map((box) => box.toRect())
                .reduce((a, b) => a.expandToInclude(b));
            return MatrixUtils.transformRect(
              paragraph.getTransformTo(null),
              bounds,
            );
          }

          final short = glyphBounds('Short');
          final long = glyphBounds('Long option');
          expect(cardBounds.width, closeTo(long.width + 61 * menuScale, 1));
          expect(short.left, closeTo(long.left, 0.01));
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.text('Short'), findsNothing);
          expect(find.byType(AppModalBackground), findsNothing);
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.windows,
        }),
      );
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'Add, more and right-click menus share row and icon styles ($brightness)',
      (tester) async {
        const entries = [
          UnifiedMenuEntry.action(
            value: 1,
            icon: Icons.folder,
            label: 'Styled action',
          ),
        ];
        final theme = ThemeData(brightness: brightness);
        for (final mode in ['add', 'button', 'context']) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Builder(
                  builder: (context) => mode == 'add'
                      ? UnifiedPopupMenuButton<int>(
                          icon: Icons.add,
                          tooltip: 'Open styled menu',
                          entries: entries,
                          onSelected: (_) {},
                        )
                      : TextButton(
                          onPressed: () {
                            if (mode == 'context') {
                              unawaited(
                                showUnifiedContextMenu<int>(
                                  context: context,
                                  globalPosition: const Offset(200, 100),
                                  entries: entries,
                                ),
                              );
                            } else {
                              unawaited(
                                showDockAwareMenu<int>(
                                  context: context,
                                  position: const RelativeRect.fromLTRB(
                                    200,
                                    100,
                                    200,
                                    100,
                                  ),
                                  entries: entries,
                                ),
                              );
                            }
                          },
                          child: const Text('Open styled menu'),
                        ),
                ),
              ),
            ),
          );
          await tester.tap(
            mode == 'add'
                ? find.byTooltip('Open styled menu')
                : find.text('Open styled menu'),
          );
          await tester.pumpAndSettle();
          final label = find.text('Styled action');
          final row = find
              .ancestor(of: label, matching: find.byType(InkWell))
              .first;
          final iconTheme = IconTheme.of(
            tester.element(find.byIcon(Icons.folder)),
          );
          final textStyle = tester.widget<Text>(label).style;
          final text = tester.renderObject<RenderParagraph>(label);
          final menuScale = mode == 'add' ? 1.0 : 0.75;
          expect(tester.getRect(row).height, closeTo(48 * menuScale, 0.01));
          expect(
            tester.getRect(row).width,
            closeTo((text.getMaxIntrinsicWidth(double.infinity) + 61) * menuScale, 1),
          );
          expect(
            textStyle,
            Theme.of(tester.element(label)).textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          );
          expect(iconTheme.size, 21);
          expect(
            tester.getRect(find.byIcon(Icons.folder)).width,
            closeTo(21 * menuScale, 0.01),
          );
          expect(iconTheme.color, theme.colorScheme.onSurface);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(label, findsNothing);
          expect(tester.takeException(), isNull);
        }
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final dockMenu in [false, true]) {
    testWidgets(
      'outgoing menu excludes focus and semantics (dock: $dockMenu)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        var selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => dockMenu
                    ? TextButton(
                        onPressed: () async {
                          final result = await showDockAwareMenu<int>(
                            context: context,
                            position: const RelativeRect.fromLTRB(
                              10,
                              10,
                              10,
                              10,
                            ),
                            entries: const [
                              UnifiedMenuEntry.action(
                                value: 1,
                                label: 'Closing action',
                              ),
                            ],
                          );
                          if (result != null) selected++;
                        },
                        child: const Text('Open menu'),
                      )
                    : UnifiedPopupMenuButton<int>(
                        icon: Icons.more_vert,
                        tooltip: 'Open menu',
                        entries: const [
                          UnifiedMenuEntry.action(
                            value: 1,
                            label: 'Closing action',
                          ),
                        ],
                        onSelected: (_) => selected++,
                      ),
              ),
            ),
          ),
        );
        await tester.tap(
          dockMenu ? find.text('Open menu') : find.byTooltip('Open menu'),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.text('Closing action'), findsOneWidget);
        expect(find.semantics.byLabel('Closing action'), findsNothing);
        final action = find
            .ancestor(
              of: find.text('Closing action'),
              matching: find.byType(InkWell),
            )
            .first;
        expect(Focus.of(tester.element(action)).hasFocus, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selected, 0);
        expect(find.text('Closing action'), findsNothing);
        semantics.dispose();
      },
    );
  }

  testWidgets('external menu replacement waits for the full fade out', (
    tester,
  ) async {
    final dismiss = ValueNotifier<VoidCallback?>(null);
    addTearDown(dismiss.dispose);
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileOverlayInset(
            bottomInset: 0,
            menuDismiss: dismiss,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  await showDockAwareMenu<int>(
                    context: context,
                    position: const RelativeRect.fromLTRB(10, 10, 10, 10),
                    entries: const [
                      UnifiedMenuEntry.action(value: 1, label: 'Fading action'),
                    ],
                  );
                  completed = true;
                },
                child: const Text('Open fading menu'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open fading menu'));
    await tester.pumpAndSettle();
    dismiss.value!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('Fading action'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));
    expect(completed, isFalse);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('Fading action'), findsNothing);
    expect(completed, isTrue);
  });

  for (final localOverlay in [false, true]) {
    testWidgets(
      'context menu starts without row focus and supports hover and keyboard (local: $localOverlay)',
      (tester) async {
        final overlayKey = GlobalKey<OverlayState>();
        int? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: MobileOverlayInset(
                bottomInset: 0,
                menuOverlayKey: localOverlay ? overlayKey : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Builder(
                      builder: (context) => GestureDetector(
                        onSecondaryTapDown: (event) async {
                          selected = await showUnifiedContextMenu<int>(
                            context: context,
                            globalPosition: event.globalPosition,
                            entries: const [
                              UnifiedMenuEntry.action(value: 1, label: 'First'),
                              UnifiedMenuEntry.action(
                                value: 2,
                                label: 'Second',
                              ),
                            ],
                          );
                        },
                        child: const ColoredBox(color: Colors.white),
                      ),
                    ),
                    if (localOverlay) Overlay(key: overlayKey),
                  ],
                ),
              ),
            ),
          ),
        );
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(200, 200));
        await mouse.down(const Offset(200, 200));
        await mouse.up();
        await tester.pumpAndSettle();
        final first = find.text('First');
        final second = find.text('Second');
        expect(Focus.of(tester.element(first)).hasFocus, isFalse);
        expect(Focus.of(tester.element(second)).hasFocus, isFalse);
        bool isHighlighted(Finder rowLabel) {
          final dynamic material = Material.of(tester.element(rowLabel));
          final ink = material.debugInkFeatures as Iterable<InkFeature>?;
          return ink?.whereType<InkHighlight>().any((ink) => ink.color.a > 0) ??
              false;
        }

        expect(isHighlighted(first), isFalse);
        expect(tester.getCenter(first).dy, closeTo(218, 0.01));
        expect(tester.getCenter(second).dy, closeTo(254, 0.01));

        await mouse.moveTo(tester.getCenter(first));
        await tester.pumpAndSettle();
        expect(isHighlighted(first), isTrue);
        expect(
          Material.of(tester.element(first)) as RenderObject,
          paints..rect(
            color: appHoverTint(Theme.of(tester.element(first)).colorScheme),
          ),
        );
        final firstCenter = tester.getCenter(first);
        await mouse.moveTo(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(isHighlighted(first), isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(Focus.of(tester.element(first)).hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(Focus.of(tester.element(second)).hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(Focus.of(tester.element(first)).hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selected, 1);
        expect(first, findsNothing);

        await mouse.moveTo(const Offset(200, 200));
        await mouse.down(const Offset(200, 200));
        await mouse.up();
        // The first move can arrive before Flutter lays out the popup.
        await mouse.moveTo(firstCenter);
        await tester.pumpAndSettle();
        expect(isHighlighted(first), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(selected, isNull);
        expect(first, findsNothing);

        for (final (label, isFirst, action) in [
          (first, true, 1),
          (second, false, 2),
        ]) {
          await mouse.moveTo(const Offset(200, 200));
          await mouse.down(const Offset(200, 200));
          await mouse.up();
          await tester.pumpAndSettle();
          final rowBounds = tester.getRect(
            find.ancestor(of: label, matching: find.byType(AppEntryInkWell)),
          );
          final edge = Offset(
            rowBounds.center.dx,
            isFirst ? rowBounds.top + 2 : rowBounds.bottom - 2,
          );
          await mouse.moveTo(edge);
          await tester.pumpAndSettle();
          expect(isHighlighted(label), isTrue);
          await tester.tapAt(edge);
          await tester.pumpAndSettle();
          expect(selected, action);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [190.0, 360.0]) {
    for (final contextMenu in [false, true]) {
      testWidgets(
        '${contextMenu ? 'context' : 'button'} menu stays within a $width pane',
        (tester) async {
          final overlayKey = GlobalKey<OverlayState>();
          final menuDismiss = ValueNotifier<VoidCallback?>(null);
          addTearDown(menuDismiss.dispose);
          int? selected;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 80),
                    child: SizedBox(
                      key: const ValueKey('menu_region'),
                      width: width,
                      height: 360,
                      child: MobileOverlayInset(
                        bottomInset: 0,
                        menuOverlayKey: overlayKey,
                        menuDismiss: menuDismiss,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Align(
                              alignment: Alignment.topRight,
                              child: Builder(
                                builder: (context) => contextMenu
                                    ? TextButton(
                                        onPressed: () async {
                                          final box =
                                              context.findRenderObject()!
                                                  as RenderBox;
                                          selected =
                                              await showUnifiedContextMenu<int>(
                                                context: context,
                                                globalPosition: box
                                                    .localToGlobal(
                                                      Offset(
                                                        box.size.width - 10,
                                                        24,
                                                      ),
                                                    ),
                                                entries: const [
                                                  UnifiedMenuEntry.action(
                                                    value: 1,
                                                    label: 'Action',
                                                  ),
                                                ],
                                              );
                                        },
                                        child: const Text('Menu'),
                                      )
                                    : UnifiedPopupMenuButton<int>(
                                        icon: Icons.more_vert,
                                        tooltip: 'Menu',
                                        entries: const [
                                          UnifiedMenuEntry.action(
                                            value: 1,
                                            label: 'Action',
                                          ),
                                        ],
                                        onSelected: (value) => selected = value,
                                      ),
                              ),
                            ),
                            Overlay(key: overlayKey),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(
            contextMenu ? find.text('Menu') : find.byTooltip('Menu'),
          );
          await tester.pumpAndSettle();
          final region = tester.getRect(
            find.byKey(const ValueKey('menu_region')),
          );
          final menu = tester.getRect(
            find
                .ancestor(
                  of: find.text('Action'),
                  matching: find.byType(ClipRRect),
                )
                .first,
          );
          expect(menu.left, greaterThanOrEqualTo(region.left));
          expect(menu.right, lessThanOrEqualTo(region.right));
          expect(menu.top, greaterThanOrEqualTo(region.top));
          expect(menu.bottom, lessThanOrEqualTo(region.bottom));
          expect(menuDismiss.value, isNotNull);
          await tester.tap(find.text('Action'));
          await tester.pumpAndSettle();
          expect(selected, 1);
          expect(menuDismiss.value, isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final contextMenu in [false, true]) {
    testWidgets(
      'Android back closes ${contextMenu ? 'context' : 'button'} menu before detail',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final root = GlobalKey<NavigatorState>();
        final navigation = WorkDetailNavigation(rootNavigatorKey: root);
        final mainMenuOverlay = GlobalKey<OverlayState>();
        addTearDown(navigation.dispose);
        await tester.pumpWidget(
          fixture.build(
            WorkDetailNavigationScope(
              navigation: navigation,
              child: MaterialApp(
                navigatorKey: root,
                home: Scaffold(
                  body: WorkDetailPane(
                    isLandscape: true,
                    sidebarWidth: 80,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 340,
                        child: MobileOverlayInset(
                          bottomInset: 0,
                          menuOverlayKey: mainMenuOverlay,
                          menuDismiss: navigation.menuDismiss,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('Main retained'),
                                    Builder(
                                      builder: (context) => TextButton(
                                        onPressed: () => unawaited(
                                          showDockAwareMenu<int>(
                                            context: context,
                                            position:
                                                const RelativeRect.fromLTRB(
                                                  50,
                                                  150,
                                                  50,
                                                  150,
                                                ),
                                            entries: const [
                                              UnifiedMenuEntry.action(
                                                value: 2,
                                                label: 'Main action',
                                              ),
                                            ],
                                          ),
                                        ),
                                        child: const Text('Main menu'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Overlay(key: mainMenuOverlay),
                            ],
                          ),
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
        unawaited(
          navigation.open(
            'detail',
            (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const Text('Detail retained'),
                    contextMenu
                        ? TextButton(
                            onPressed: () {
                              final box =
                                  context.findRenderObject()! as RenderBox;
                              unawaited(
                                showUnifiedContextMenu<int>(
                                  context: context,
                                  globalPosition: box.localToGlobal(
                                    const Offset(100, 100),
                                  ),
                                  entries: const [
                                    UnifiedMenuEntry.action(
                                      value: 1,
                                      label: 'Action',
                                    ),
                                  ],
                                ),
                              );
                            },
                            child: const Text('Menu'),
                          )
                        : UnifiedPopupMenuButton<int>(
                            icon: Icons.more_vert,
                            tooltip: 'Menu',
                            entries: const [
                              UnifiedMenuEntry.action(
                                value: 1,
                                label: 'Action',
                              ),
                            ],
                            onSelected: (_) {},
                          ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          contextMenu ? find.text('Menu') : find.byTooltip('Menu'),
        );
        await tester.pumpAndSettle();
        expect(navigation.menuDismiss.value, isNotNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Action'), findsNothing);
        expect(find.text('Detail retained'), findsOneWidget);
        expect(navigation.isOpen, isTrue);
        expect(navigation.menuDismiss.value, isNull);
        await tester.tap(
          contextMenu ? find.text('Menu') : find.byTooltip('Menu'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Action'), findsOneWidget);
        expect(navigation.menuDismiss.value, isNotNull);

        // Clicking empty space in the other pane dismisses the open menu.
        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
        expect(find.text('Action'), findsNothing);
        expect(navigation.menuDismiss.value, isNull);

        // Clicking a button in the other pane dismisses the menu without activating it.
        await tester.tap(
          contextMenu ? find.text('Menu') : find.byTooltip('Menu'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Action'), findsOneWidget);
        await tester.tap(find.text('Main menu'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('Action'), findsNothing);
        expect(find.text('Main action'), findsNothing);
        expect(navigation.menuDismiss.value, isNull);

        // Once dismissed, tapping Main menu opens its menu normally.
        await tester.tap(find.text('Main menu'));
        await tester.pumpAndSettle();
        expect(find.text('Main action'), findsOneWidget);
        expect(navigation.menuDismiss.value, isNotNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Main action'), findsNothing);
        expect(navigation.isOpen, isTrue);
        expect(navigation.menuDismiss.value, isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(navigation.isOpen, isFalse);
        expect(find.text('Main retained'), findsOneWidget);
        await tester.pump(coordinator.idleDelay);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('popup releases curve listeners after each dismissal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedPopupMenuButton<int>(
            icon: Icons.more_vert,
            tooltip: 'Menu',
            entries: const [UnifiedMenuEntry.action(value: 1, label: 'Action')],
            onSelected: (_) {},
          ),
        ),
      ),
    );
    for (var opening = 0; opening < 3; opening++) {
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('Action'),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      final curve = fade.opacity as CurvedAnimation;
      expect(curve.isDisposed, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Action'), findsNothing);
      expect(curve.isDisposed, isTrue);
    }
    await tester.pump(coordinator.idleDelay);
    expect(coordinator.isInteracting, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final stage in ['enter', 'open', 'exit']) {
    testWidgets('removing work entry during menu $stage clears root overlay', (
      tester,
    ) async {
      var visible = true;
      var actions = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return visible
                    ? WorkDetailEntryTile(
                        item: const WorkEntryItem(
                          name: 'Track',
                          relativePath: 'Track.mp3',
                          type: WorkEntryType.audio,
                        ),
                        accentColor: Colors.blue,
                        moreLabel: 'Menu',
                        unknownSizeLabel: 'Size unknown',
                        menuEntries: const [
                          UnifiedMenuEntry.action(
                            value: WorkEntryAction.play,
                            label: 'Play',
                          ),
                        ],
                        onAction: (_) => actions++,
                      )
                    : const Text('Directory replaced');
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Menu'));
      await tester.pump();
      if (stage != 'enter') await tester.pumpAndSettle();
      if (stage == 'exit') {
        await tester.tap(find.text('Play'));
        await tester.pump(const Duration(milliseconds: 40));
      }
      update(() => visible = false);
      await tester.pump();
      await tester.pump();
      expect(find.text('Play'), findsNothing);
      expect(find.text('Directory replaced'), findsOneWidget);
      expect(actions, 0);
      expect(coordinator.isInteracting, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final closing in [false, true]) {
    for (final change in ['hidden', 'reduced', 'disabled']) {
      testWidgets(
        'popup $change during ${closing ? 'exit' : 'enter'} clears protection',
        (tester) async {
          var visible = true;
          var reduced = false;
          var enabled = true;
          late StateSetter update;
          await tester.pumpWidget(
            MaterialApp(
              home: StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return TickerMode(
                    enabled: visible,
                    child: MediaQuery(
                      data: MediaQueryData(disableAnimations: reduced),
                      child: Scaffold(
                        body: UnifiedPopupMenuButton<int>(
                          icon: Icons.more_vert,
                          tooltip: 'Menu',
                          enabled: enabled,
                          entries: const [
                            UnifiedMenuEntry.action(value: 1, label: 'Action'),
                          ],
                          onSelected: (_) {},
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.tap(find.byTooltip('Menu'));
          await tester.pump();
          if (closing) {
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pump();
          }
          expect(coordinator.isInteracting, isTrue);
          update(() {
            visible = change != 'hidden';
            reduced = change == 'reduced';
            enabled = change != 'disabled';
          });
          await tester.pump();
          await tester.pump();
          expect(coordinator.isInteracting, isFalse);
          if (change == 'reduced' && !closing) {
            expect(find.text('Action'), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pump();
          }
          expect(find.text('Action'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final closing in [false, true]) {
    for (final change in ['hidden', 'reduced']) {
      testWidgets(
        'dock $change during ${closing ? 'exit' : 'enter'} clears protection',
        (tester) async {
          var visible = true;
          var reduced = false;
          late StateSetter update;
          Future<int?>? result;
          await tester.pumpWidget(
            MaterialApp(
              builder: (_, child) => StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return MediaQuery(
                    data: MediaQueryData(disableAnimations: reduced),
                    child: TickerMode(enabled: visible, child: child!),
                  );
                },
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () {
                      result = showDockAwareMenu<int>(
                        context: context,
                        position: const RelativeRect.fromLTRB(
                          100,
                          100,
                          100,
                          100,
                        ),
                        entries: const [
                          UnifiedMenuEntry.action(value: 1, label: 'Action'),
                        ],
                      );
                    },
                    child: const Text('Menu'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Menu'));
          await tester.pump();
          if (closing) {
            await tester.pumpAndSettle();
            await tester.tap(find.text('Action'));
            await tester.pump();
          }
          expect(coordinator.isInteracting, isTrue);
          update(() {
            visible = change != 'hidden';
            reduced = change == 'reduced';
          });
          await tester.pump();
          await tester.pump();
          expect(coordinator.isInteracting, isFalse);
          if (change == 'reduced' && !closing) {
            expect(find.text('Action'), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pump();
          }
          expect(await result, closing && change == 'reduced' ? 1 : isNull);
          expect(find.text('Action'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('dock menu captures theme with sibling playback overlay', (
    tester,
  ) async {
    final overlay = GlobalKey<OverlayState>();
    Future<int?>? result;
    const accent = Colors.teal;
    await tester.pumpWidget(
      MaterialApp(
        home: MobileOverlayInset(
          bottomInset: 80,
          menuOverlayKey: overlay,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Theme(
                data: ThemeData(
                  colorScheme: ColorScheme.fromSeed(seedColor: accent),
                ),
                child: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () {
                        result = showDockAwareMenu<int>(
                          context: context,
                          position: const RelativeRect.fromLTRB(
                            100,
                            100,
                            100,
                            100,
                          ),
                          entries: const [
                            UnifiedMenuEntry.action(value: 1, label: 'Action'),
                          ],
                        );
                      },
                      child: const Text('Launch menu'),
                    ),
                  ),
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 64,
                child: SizedBox(key: ValueKey('mock-playback-dock')),
              ),
              Overlay(key: overlay),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch menu'));
    await tester.pumpAndSettle();
    final menu = find.text('Action');
    expect(menu, findsOneWidget);
    expect(
      Theme.of(tester.element(menu)).colorScheme.primary,
      ColorScheme.fromSeed(seedColor: accent).primary,
    );
    final paintOrder = tester.allWidgets.toList();
    expect(
      paintOrder.indexOf(
        tester.widget(find.byKey(const ValueKey('mock-playback-dock'))),
      ),
      lessThan(paintOrder.indexOf(tester.widget(menu))),
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(await result, 1);
    expect(menu, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final dockAware in [false, true]) {
    Future<void> pumpMenu(WidgetTester tester, {bool reduced = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  const entries = [
                    UnifiedMenuEntry<int>.action(value: 1, label: 'Action'),
                  ];
                  return dockAware
                      ? TextButton(
                          onPressed: () {
                            unawaited(
                              showDockAwareMenu<int>(
                                context: context,
                                position: const RelativeRect.fromLTRB(
                                  100,
                                  100,
                                  100,
                                  100,
                                ),
                                entries: entries,
                              ),
                            );
                          },
                          child: const Text('Menu'),
                        )
                      : UnifiedPopupMenuButton<int>(
                          icon: Icons.more_vert,
                          tooltip: 'Menu',
                          entries: entries,
                          onSelected: (_) {},
                        );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byTooltip('Menu').evaluate().isNotEmpty
            ? find.byTooltip('Menu')
            : find.text('Menu'),
      );
    }

    testWidgets(
      'async results wait through menu open and close (dock: $dockAware)',
      (tester) async {
        await pumpMenu(tester);
        expect(coordinator.isInteracting, isTrue);
        int? published;
        Future<void> completeResult(int value) async {
          final result = Completer<int>();
          final completion = result.future.then((value) {
            coordinator.scheduleCommit(
              key: 'menu-result',
              commit: () => published = value,
            );
          });
          result.complete(value);
          await completion;
        }

        await completeResult(1);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(published, isNull);
        await tester.pumpAndSettle();
        await tester.pump(coordinator.idleDelay);
        await tester.pump();
        expect(published, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await completeResult(2);
        await completeResult(3);
        await tester.pump(const Duration(milliseconds: 50));
        expect(published, 1);
        expect(coordinator.isInteracting, isTrue);
        await tester.pumpAndSettle();
        await tester.pump(coordinator.idleDelay);
        await tester.pump();
        expect(published, 3);
        expect(coordinator.isInteracting, isFalse);
        expect(find.text('Action'), findsNothing);
      },
    );

    testWidgets('menu can dismiss during its entrance (dock: $dockAware)', (
      tester,
    ) async {
      await pumpMenu(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 45));
      final action = find.text('Action');
      final fade = find
          .ancestor(of: action, matching: find.byType(FadeTransition))
          .first;
      double opacity() => tester.widget<FadeTransition>(fade).opacity.value;

      final beforeClose = opacity();
      expect(beforeClose, inExclusiveRange(0, 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(opacity(), closeTo(beforeClose, 0.001));
      await tester.pumpAndSettle();
      expect(action, findsNothing);
      await tester.pump(coordinator.idleDelay);
      expect(coordinator.isInteracting, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('static open menu allows data commits (dock: $dockAware)', (
      tester,
    ) async {
      await pumpMenu(tester);
      await tester.pumpAndSettle();
      await tester.pump(coordinator.idleDelay);
      expect(coordinator.isInteracting, isFalse);
      var committed = false;
      coordinator.scheduleCommit(
        key: 'static-menu',
        commit: () => committed = true,
      );
      await tester.pump();
      expect(committed, isTrue);
      expect(find.text('Action'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pump(coordinator.idleDelay);
    });

    testWidgets(
      'reduced menu opens and closes immediately (dock: $dockAware)',
      (tester) async {
        await pumpMenu(tester, reduced: true);
        await tester.pump();
        final fades = tester.widgetList<FadeTransition>(
          find.ancestor(
            of: find.text('Action'),
            matching: find.byType(FadeTransition),
          ),
        );
        expect(fades.every((fade) => fade.opacity.value == 1), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.text('Action'), findsNothing);
        await tester.pump(coordinator.idleDelay);
        expect(coordinator.isInteracting, isFalse);
      },
    );

    testWidgets(
      'host disposal during reverse releases menu (dock: $dockAware)',
      (tester) async {
        await pumpMenu(tester);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(coordinator.isInteracting, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final beforeLayout in [false, true]) {
    testWidgets(
      'dock menu follows route removal with root overlay retained (before layout: $beforeLayout)',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        Future<int?>? result;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Root retained')),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () {
                      result = showDockAwareMenu<int>(
                        context: context,
                        position: const RelativeRect.fromLTRB(
                          100,
                          100,
                          100,
                          100,
                        ),
                        entries: const [
                          UnifiedMenuEntry.action(value: 1, label: 'Action'),
                        ],
                      );
                    },
                    child: const Text('Launch menu'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Launch menu'));
        if (!beforeLayout) {
          await tester.pumpAndSettle();
          await tester.pump(coordinator.idleDelay);
          expect(find.text('Action'), findsOneWidget);
        }
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(await result, isNull);
        expect(find.text('Action'), findsNothing);
        expect(find.text('Root retained'), findsOneWidget);
        expect(coordinator.isInteracting, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('dock menu dismisses safely after launching context is removed', (
    tester,
  ) async {
    var visible = true;
    late StateSetter update;
    Future<int?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return visible
                  ? Builder(
                      builder: (context) => TextButton(
                        onPressed: () {
                          result = showDockAwareMenu<int>(
                            context: context,
                            position: const RelativeRect.fromLTRB(
                              100,
                              100,
                              100,
                              100,
                            ),
                            entries: const [
                              UnifiedMenuEntry.action(
                                value: 1,
                                label: 'Action',
                              ),
                            ],
                          );
                        },
                        child: const Text('Launch menu'),
                      ),
                    )
                  : const Text('Host retained');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch menu'));
    await tester.pumpAndSettle();
    update(() => visible = false);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.text('Action'), findsNothing);
    expect(coordinator.isInteracting, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing popup button during reverse clears its root overlay', (
    tester,
  ) async {
    var visible = true;
    late StateSetter update;
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return visible
                  ? UnifiedPopupMenuButton<int>(
                      icon: Icons.more_vert,
                      tooltip: 'Menu',
                      entries: const [
                        UnifiedMenuEntry.action(value: 1, label: 'Action'),
                      ],
                      onSelected: (_) => selected++,
                    )
                  : const Text('Host retained');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action'));
    await tester.pump(const Duration(milliseconds: 40));
    update(() => visible = false);
    await tester.pumpAndSettle();
    expect(find.text('Action'), findsNothing);
    expect(find.text('Host retained'), findsOneWidget);
    expect(selected, 0);
    expect(coordinator.isInteracting, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'short context menu stays fixed when dragged at either edge',
    (tester) async {
      late BuildContext hostContext;
      var overscrollIndicators = 0;
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          builder: (_, child) =>
              NotificationListener<OverscrollIndicatorNotification>(
                onNotification: (_) {
                  overscrollIndicators++;
                  return false;
                },
                child: child!,
              ),
          home: Builder(
            builder: (context) {
              hostContext = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final menu = showUnifiedContextMenu<int>(
        context: hostContext,
        globalPosition: const Offset(360, 200),
        entries: const [UnifiedMenuEntry.action(value: 1, label: 'Action')],
      );
      await tester.pumpAndSettle();

      final row = find.byType(AppEntryInkWell);
      final rowBounds = tester.getRect(row);
      for (final delta in [const Offset(0, 60), const Offset(0, -60)]) {
        final drag = await tester.startGesture(rowBounds.center);
        await drag.moveBy(delta / 2);
        await drag.moveBy(delta / 2);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(row), rowBounds);
        await drag.up();
        await tester.pumpAndSettle();
      }
      expect(overscrollIndicators, 0);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(await menu, 1);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('tall popup menu scrolls rows inside a fixed shadow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int? chosen;
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: UnifiedPopupMenuButton<int>(
              icon: Icons.more_vert,
              tooltip: 'TallMenu',
              entries: [
                for (var i = 1; i <= 12; i++)
                  UnifiedMenuEntry.action(value: i, label: 'Option $i'),
              ],
              onSelected: (value) => chosen = value,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('TallMenu'));
    await tester.pumpAndSettle();

    final firstRect = tester.getRect(find.text('Option 1'));
    expect(firstRect.top, greaterThanOrEqualTo(0));
    final shadow = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).boxShadow?.isNotEmpty == true,
    );
    final shadowBounds = tester.getRect(shadow);
    expect(shadowBounds.bottom, lessThanOrEqualTo(320));
    final scrollable = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('Option 12'),
      120,
      scrollable: scrollable,
    );
    expect(tester.getRect(shadow), shadowBounds);
    final lastRect = tester.getRect(find.text('Option 12'));
    expect(lastRect.bottom, lessThanOrEqualTo(320));
    await tester.tap(find.text('Option 12'));
    await tester.pumpAndSettle();
    expect(chosen, 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pointer-anchored context menu opens rightward and respects custom trailingTooltip',
    (tester) async {
      late BuildContext hostContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Builder(
            builder: (context) {
              hostContext = context;
              return const Scaffold();
            },
          ),
        ),
      );
      const anchor = Offset(240, 120);
      unawaited(
        showUnifiedContextMenu<int>(
          context: hostContext,
          globalPosition: anchor,
          entries: const [
            UnifiedMenuEntry.action(
              value: 1,
              label: 'Rightward item',
              trailing: Icon(Icons.close, size: 16),
              trailingValue: 99,
              trailingTooltip: 'Custom remove tip',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final card = find
          .ancestor(
            of: find.text('Rightward item'),
            matching: find.byType(ClipRRect),
          )
          .first;
      expect(tester.getRect(card).left, closeTo(anchor.dx, 0.5));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Custom trailingTooltip is used on UnifiedPopupMenuButton entries.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Center(
              child: UnifiedPopupMenuButton<int>(
                icon: Icons.more_vert,
                tooltip: 'Trailing menu',
                entries: const [
                  UnifiedMenuEntry.action(
                    value: 1,
                    label: 'Row',
                    trailing: Icon(Icons.clear, size: 16),
                    trailingValue: 2,
                    trailingTooltip: 'Custom trailing action',
                  ),
                ],
                onSelected: (_) {},
                onTrailingSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Trailing menu'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Custom trailing action'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
