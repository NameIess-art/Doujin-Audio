import 'package:doujin_audio/app/presentation/app_dock_panel.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/core/widgets/app_glass_surface.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'header and dock default to solid colors and toggle glass together in $brightness',
      (tester) async {
        final enabled = ValueNotifier(false);
        addTearDown(enabled.dispose);
        final boundaryKey = GlobalKey();
        final theme = ThemeData(brightness: brightness);
        final cs = theme.colorScheme;
        final headerColor = brightness == Brightness.dark
            ? cs.surfaceBright
            : cs.surfaceContainerHigh;
        final dockColor = brightness == Brightness.dark
            ? cs.surfaceContainer
            : cs.surfaceContainerHigh;
        await tester.pumpWidget(
          ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, value, child) => MaterialApp(
              theme: theme.copyWith(
                extensions: value
                    ? [
                        (brightness == Brightness.dark
                                ? AppDesignTokens.dark
                                : AppDesignTokens.light)
                            .copyWith(barGlassEnabled: true),
                      ]
                    : [],
              ),
              home: child,
            ),
            child: RepaintBoundary(
              key: boundaryKey,
              child: const ColoredBox(
                color: Colors.red,
                child: Stack(
                  children: [
                    TopPageHeader(
                      showFadeMask: false,
                      useSafeAreaTop: false,
                      topCapsuleTitle: 'Library',
                      titleWidget: SizedBox.shrink(),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: AppDockPanel(
                        showTopHighlight: false,
                        child: SizedBox(width: 320, height: 64),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        Future<void> expectSolidBars() async {
          expect(find.byType(BackdropFilter), findsNothing);
          expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
          final headerRect = tester.getRect(find.byType(HeaderTopCapsule));
          final points = [
            Offset(headerRect.center.dx, headerRect.top + 8),
            tester.getCenter(find.byType(AppDockPanel)),
          ];
          final colors = await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(boundaryKey),
            );
            final image = await boundary.toImage();
            try {
              final bytes = (await image.toByteData())!;
              return points.map((point) {
                final i =
                    (point.dy.floor() * image.width + point.dx.floor()) * 4;
                return Color.fromARGB(
                  bytes.getUint8(i + 3),
                  bytes.getUint8(i),
                  bytes.getUint8(i + 1),
                  bytes.getUint8(i + 2),
                );
              }).toList();
            } finally {
              image.dispose();
            }
          });
          expect(colors, [headerColor, dockColor]);
        }

        await expectSolidBars();
        final headerBounds = tester.getRect(find.byType(TopPageHeader));
        final dockBounds = tester.getRect(find.byType(AppDockPanel));
        enabled.value = true;
        await tester.pumpAndSettle();
        for (final type in [TopPageHeader, AppDockPanel]) {
          expect(
            find.descendant(
              of: find.byType(type),
              matching: find.byType(BackdropFilter),
            ),
            findsWidgets,
          );
        }
        enabled.value = false;
        await tester.pumpAndSettle();
        await expectSolidBars();
        expect(tester.getRect(find.byType(TopPageHeader)), headerBounds);
        expect(tester.getRect(find.byType(AppDockPanel)), dockBounds);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );

    testWidgets('dock keeps bounds and interactive foreground in $brightness', (
      tester,
    ) async {
      var taps = 0;
      final theme = ThemeData(
        brightness: brightness,
        extensions: [
          (brightness == Brightness.dark
                  ? AppDesignTokens.dark
                  : AppDesignTokens.light)
              .copyWith(barGlassEnabled: true),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: AppDockPanel(
                child: SizedBox(
                  width: 320,
                  height: 64,
                  child: TextButton(
                    onPressed: () => taps++,
                    child: const Text('Play'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(AppDockPanel)), const Size(320, 64));
      expect(find.byType(BackdropFilter), findsOneWidget);
      final glass = tester.widget<AppGlassSurface>(
        find.byType(AppGlassSurface),
      );
      expect(glass.blurSigma, 6);
      final tint = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(AppGlassSurface),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(
        tint.color.a,
        closeTo(brightness == Brightness.dark ? 0.756 : 0.72, 1e-6),
      );
      expect(glass.borderRadius, BorderRadius.circular(100));
      final backgrounds = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(AppDockPanel),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decorations = backgrounds
          .map((widget) => widget.decoration)
          .whereType<BoxDecoration>();
      expect(
        decorations.any((decoration) => decoration.border != null),
        isTrue,
      );
      expect(
        decorations.any(
          (decoration) => decoration.boxShadow?.isNotEmpty ?? false,
        ),
        isFalse,
      );
      await tester.tap(find.text('Play'));
      expect(taps, 1);
    });

    testWidgets(
      'fade opacity scales color without changing stops in $brightness',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: const Column(
              children: [
                Expanded(
                  child: AppEdgeFadeMask(
                    direction: AppEdgeFadeDirection.towardBottom,
                  ),
                ),
                Expanded(
                  child: AppEdgeFadeMask(
                    direction: AppEdgeFadeDirection.towardBottom,
                    opacity: .6,
                  ),
                ),
              ],
            ),
          ),
        );
        final gradients = tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .map((widget) => (widget.decoration as BoxDecoration).gradient)
            .whereType<LinearGradient>()
            .toList();
        expect(gradients, hasLength(2));
        expect(gradients[1].stops, gradients[0].stops);
        for (var i = 0; i < gradients[0].colors.length; i++) {
          expect(
            gradients[1].colors[i].a,
            closeTo(gradients[0].colors[i].a * .6, .005),
          );
        }
      },
    );
  }
}
