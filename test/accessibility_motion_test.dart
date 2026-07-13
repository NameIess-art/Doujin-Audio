import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/widgets/shimmer_loading.dart';
import 'package:nameless_audio/core/widgets/unified_popup_menu.dart';

void main() {
  testWidgets('reduced motion disables shimmer animation', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: ShimmerLoader(child: SizedBox(width: 40, height: 40)),
        ),
      ),
    );

    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('popup menu button exposes a labeled button semantic', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedPopupMenuButton<int>(
            icon: Icons.more_vert,
            tooltip: 'More actions',
            entries: const <UnifiedMenuEntry<int>>[
              UnifiedMenuEntry<int>.action(
                value: 1,
                icon: Icons.play_arrow,
                label: 'Play',
              ),
            ],
            onSelected: (_) {},
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byTooltip('More actions')),
      matchesSemantics(
        tooltip: 'More actions',
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
      ),
    );
  });
}
