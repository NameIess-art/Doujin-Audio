import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/core/widgets/unified_dropdown.dart';

void main() {
  const menuColor = Color(0xFF25252A);

  Widget buildHarness(Widget child) {
    return MaterialApp(
      theme: ThemeData(
        canvasColor: Colors.transparent,
        colorScheme: const ColorScheme.dark(surfaceContainerHigh: menuColor),
      ),
      home: Scaffold(body: child),
    );
  }

  testWidgets('unified dropdown button uses the opaque language menu style', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildHarness(
        UnifiedDropdownButton<String>(
          value: 'a',
          items: const [DropdownMenuItem<String>(value: 'a', child: Text('A'))],
          onChanged: (_) {},
        ),
      ),
    );

    final button = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(button.dropdownColor, menuColor);
    expect(button.dropdownColor!.a, 1);
    expect(button.borderRadius, AppRadius.borderMedium);
  });
}
