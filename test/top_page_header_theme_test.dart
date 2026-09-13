import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';

Widget _buildThemedApp({
  required Widget child,
  ThemeData? theme,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: theme ?? ThemeData.light(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('TopPageHeader and HeaderSegmentedCategoryBar theme & accent tests', () {
    testWidgets('TopPageHeader uses custom iconColor when provided', (
      tester,
    ) async {
      const customColor = Colors.deepPurple;
      await tester.pumpWidget(
        _buildThemedApp(
          child: const TopPageHeader(
            icon: Icons.cloud_rounded,
            iconColor: customColor,
            title: 'ASMR.ONE',
            useSafeAreaTop: false,
          ),
        ),
      );

      final iconFinder = find.byIcon(Icons.cloud_rounded);
      expect(iconFinder, findsOneWidget);
      final iconWidget = tester.widget<Icon>(iconFinder);
      expect(iconWidget.color, customColor);
    });

    testWidgets('TopPageHeader top capsule uses custom iconColor', (
      tester,
    ) async {
      const customColor = Colors.teal;
      await tester.pumpWidget(
        _buildThemedApp(
          child: const TopPageHeader(
            icon: Icons.cloud_rounded,
            iconColor: customColor,
            topCapsuleTitle: 'Top Title',
            useSafeAreaTop: false,
          ),
        ),
      );

      final iconFinder = find.byIcon(Icons.cloud_rounded);
      expect(iconFinder, findsOneWidget);
      final iconWidget = tester.widget<Icon>(iconFinder);
      expect(iconWidget.color, customColor);
    });

    testWidgets('TopPageHeader defaults iconColor to Theme primary', (
      tester,
    ) async {
      const primaryColor = Colors.amber;
      final theme = ThemeData.light().copyWith(
        colorScheme: const ColorScheme.light(primary: primaryColor),
      );

      await tester.pumpWidget(
        _buildThemedApp(
          theme: theme,
          child: const TopPageHeader(
            icon: Icons.cloud_rounded,
            title: 'ASMR.ONE',
            useSafeAreaTop: false,
          ),
        ),
      );

      final iconFinder = find.byIcon(Icons.cloud_rounded);
      expect(iconFinder, findsOneWidget);
      final iconWidget = tester.widget<Icon>(iconFinder);
      expect(iconWidget.color, primaryColor);
    });

    testWidgets('HeaderSegmentedCategoryBar uses accentColor for selected item', (
      tester,
    ) async {
      const customAccent = Color(0xFF1D4ED8);
      int selectedIndex = 0;

      await tester.pumpWidget(
        _buildThemedApp(
          child: StatefulBuilder(
            builder: (context, setState) {
              return HeaderSegmentedCategoryBar<int>(
                items: const [0, 1, 2],
                selected: selectedIndex,
                onSelected: (val) => setState(() => selectedIndex = val),
                labelBuilder: (item) => 'Tab $item',
                accentColor: customAccent,
              );
            },
          ),
        ),
      );

      // Check selected tab label color
      final textFinder = find.text('Tab 0');
      expect(textFinder, findsOneWidget);
      final textWidget = tester.widget<Text>(textFinder);
      expect(textWidget.style?.color, customAccent);

      // Check selected tab background Material color
      final materialFinder = find.ancestor(
        of: textFinder,
        matching: find.byType(Material),
      );
      final materialWidget = tester.widget<Material>(materialFinder.first);
      expect(materialWidget.color, customAccent.withValues(alpha: 0.16));
    });

    testWidgets('asmrThemeData produces ThemeData with asmrAccent as primary', (
      tester,
    ) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(
        _buildThemedApp(
          child: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final tokens = AppDesignTokens.of(capturedContext);
      final asmrTheme = asmrThemeData(capturedContext);

      expect(asmrTheme.colorScheme.primary, tokens.asmrAccent);
      expect(asmrTheme.colorScheme.secondary, tokens.asmrAccent);
      expect(asmrTheme.colorScheme.onPrimary, tokens.onAsmrAccent);
      expect(asmrTheme.colorScheme.primaryContainer, tokens.asmrContainer);
      expect(asmrTheme.colorScheme.onPrimaryContainer, tokens.onAsmrContainer);
    });

    testWidgets('TopPageHeader inherits asmrAccent when wrapped in asmrThemeData', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildThemedApp(
          child: Builder(
            builder: (context) {
              final tokens = AppDesignTokens.of(context);
              return Theme(
                data: asmrThemeData(context),
                child: TopPageHeader(
                  icon: Icons.cloud_rounded,
                  iconColor: tokens.asmrAccent,
                  title: 'ASMR.ONE',
                  useSafeAreaTop: false,
                ),
              );
            },
          ),
        ),
      );

      final iconFinder = find.byIcon(Icons.cloud_rounded);
      final iconWidget = tester.widget<Icon>(iconFinder);
      final tokens = AppDesignTokens.of(tester.element(iconFinder));
      expect(iconWidget.color, tokens.asmrAccent);
    });
  });
}
