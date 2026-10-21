import 'package:doujin_audio/app/presentation/app_dock_panel.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/core/widgets/app_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('dock keeps bounds and interactive foreground in $brightness', (
      tester,
    ) async {
      var taps = 0;
      final theme = ThemeData(brightness: brightness);
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
