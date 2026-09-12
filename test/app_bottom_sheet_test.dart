import 'package:doujin_audio/core/widgets/app_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final windowWidth in [960.0, 1280.0, 1920.0]) {
      testWidgets(
        '$platform sheet width in a $windowWidth window',
        (tester) async {
          tester.view.physicalSize = Size(windowWidth, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => AppBottomSheet.show<void>(
                      context: context,
                      builder: (_) =>
                          const SizedBox(width: double.infinity, height: 120),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();

          final material = find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Material),
          );
          final rect = tester.getRect(material.first);
          final expectedWidth = platform == TargetPlatform.windows
              ? windowWidth * 0.5
              : windowWidth;
          expect(rect.width, expectedWidth);
          expect(rect.center.dx, windowWidth / 2);
          expect(rect.bottom, 800);
          expect(tester.takeException(), isNull);

          if (platform == TargetPlatform.windows) {
            for (final resizedWidth in [960.0, 1920.0]) {
              tester.view.physicalSize = Size(resizedWidth, 800);
              await tester.pumpAndSettle();
              final resizedRect = tester.getRect(material.first);
              expect(resizedRect.width, resizedWidth / 2);
              expect(resizedRect.center.dx, resizedWidth / 2);
              expect(resizedRect.bottom, 800);
              expect(tester.takeException(), isNull);
            }
            await tester.tapAt(const Offset(20, 780));
            await tester.pumpAndSettle();
            expect(find.byType(BottomSheet), findsNothing);
          }
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }
}
