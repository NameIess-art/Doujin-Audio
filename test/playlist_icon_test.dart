import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/widgets/playlist_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('PlaylistIcon inherits IconTheme size and color', (tester) async {
    const customColor = Color(0xFF4F46E5);
    await tester.pumpWidget(
      const MaterialApp(
        home: IconTheme(
          data: IconThemeData(size: 30, color: customColor),
          child: Center(child: PlaylistIcon(filled: false)),
        ),
      ),
    );

    final box = tester.widget<SizedBox>(
      find.descendant(
        of: find.byType(PlaylistIcon),
        matching: find.byType(SizedBox),
      ),
    );
    expect(box.width, 30);
    expect(box.height, 30);

    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(PlaylistIcon),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = paint.painter! as PlaylistIconPainter;
    expect(painter.filled, isFalse);
    expect(painter.color, customColor);
  });

  test('PlaylistIconPainter repaints only when filled or color changes', () {
    const base = PlaylistIconPainter(filled: false, color: Colors.black);
    const same = PlaylistIconPainter(filled: false, color: Colors.black);
    const filledChanged = PlaylistIconPainter(filled: true, color: Colors.black);
    const colorChanged = PlaylistIconPainter(filled: false, color: Colors.white);

    expect(base.shouldRepaint(same), isFalse);
    expect(base.shouldRepaint(filledChanged), isTrue);
    expect(base.shouldRepaint(colorChanged), isTrue);
    expect(
      base.shouldRepaint(
        const PlaylistIconPainter(
          filled: false,
          color: Colors.black,
          variant: PlaylistIconVariant.add,
        ),
      ),
      isTrue,
    );
  });

  testWidgets('PlaylistIcon.add uses add variant and inherits IconTheme', (
    tester,
  ) async {
    const customColor = Color(0xFF059669);
    await tester.pumpWidget(
      const MaterialApp(
        home: IconTheme(
          data: IconThemeData(size: 20, color: customColor),
          child: Center(child: PlaylistIcon.add()),
        ),
      ),
    );

    final box = tester.widget<SizedBox>(
      find.descendant(
        of: find.byType(PlaylistIcon),
        matching: find.byType(SizedBox),
      ),
    );
    expect(box.width, 20);
    expect(box.height, 20);

    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(PlaylistIcon),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = paint.painter! as PlaylistIconPainter;
    expect(painter.variant, PlaylistIconVariant.add);
    expect(painter.filled, isTrue);
    expect(painter.color, customColor);
  });

  testWidgets('PlaylistIcon paints hollow outline vs solid filled layer', (
    tester,
  ) async {
    Future<List<Invocation>> paintInvocations(bool filled) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: PlaylistIcon(filled: filled, size: 24, color: Colors.black),
          ),
        ),
      );
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(PlaylistIcon),
          matching: find.byType(CustomPaint),
        ),
      );
      final canvas = TestRecordingCanvas();
      paint.painter!.paint(canvas, const Size(24, 24));
      return canvas.invocations.map((call) => call.invocation).toList();
    }

    final hollowCalls = await paintInvocations(false);
    final solidCalls = await paintInvocations(true);

    expect(hollowCalls.any((c) => c.memberName == #saveLayer), isFalse);
    expect(solidCalls.any((c) => c.memberName == #saveLayer), isFalse);
    expect(solidCalls.any((c) => c.memberName == #drawPath), isTrue);
  });

  test('opticalIconSize normalizes navigation icon glyphs uniformly', () {
    expect(
      AppDesignTokens.opticalIconSize(Icons.cloud_outlined, 28),
      closeTo(28 * 0.92, 0.001),
    );
    expect(
      AppDesignTokens.opticalIconSize(Icons.cloud_rounded, 22),
      closeTo(22 * 0.92, 0.001),
    );
    expect(
      AppDesignTokens.opticalIconSize(Icons.library_music_outlined, 28),
      closeTo(28 * 0.96, 0.001),
    );
    expect(
      AppDesignTokens.opticalIconSize(Icons.library_music_rounded, 18),
      closeTo(18 * 0.96, 0.001),
    );
    expect(
      AppDesignTokens.opticalIconSize(Icons.person_outline_rounded, 28),
      closeTo(28 * 1.18, 0.001),
    );
    expect(
      AppDesignTokens.opticalIconSize(Icons.person_rounded, 13),
      closeTo(13 * 1.18, 0.001),
    );
    expect(
      AppDesignTokens.opticalIconSize(Icons.settings_outlined, 28),
      closeTo(28 * 0.98, 0.001),
    );
    expect(
      AppDesignTokens.opticalIconSize(Icons.settings_rounded, 22),
      closeTo(22 * 0.98, 0.001),
    );
    expect(AppDesignTokens.opticalIconSize(Icons.tune_rounded, 24), 24);

    final destinations = resolveMainDestinations(
      showLocalLibrary: true,
      showAsmrOne: true,
    );
    for (final destination in destinations) {
      final widget = destination.buildIcon(selected: true, size: 28);
      if (destination.type == MainDestinationType.playlist) {
        expect(widget, isA<PlaylistIcon>());
        expect((widget as PlaylistIcon).size, 28);
      } else {
        final icon = widget as Icon;
        expect(
          icon.size,
          closeTo(AppDesignTokens.opticalIconSize(icon.icon, 28), 0.001),
        );
      }
    }
  });
}
