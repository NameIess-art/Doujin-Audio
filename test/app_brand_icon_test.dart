import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_brand_icon.dart';

void main() {
  testWidgets('app brand icon stays fixed across theme brightness', (
    tester,
  ) async {
    Future<void> pumpIcon(Brightness brightness) {
      return tester.pumpWidget(
        MaterialApp(
          home: Theme(
            data: ThemeData(brightness: brightness),
            child: const Scaffold(body: AppBrandIcon(size: 80)),
          ),
        ),
      );
    }

    await pumpIcon(Brightness.light);
    expect(_renderedAsset(tester), appBrandIconAsset);
    expect(tester.getSize(find.byType(AppBrandIcon)), const Size(80, 80));

    await pumpIcon(Brightness.dark);
    await tester.pump();
    expect(_renderedAsset(tester), appBrandIconAsset);
    expect(tester.getSize(find.byType(AppBrandIcon)), const Size(80, 80));
    expect(find.byType(ShaderMask), findsNothing);
  });
}

String _renderedAsset(WidgetTester tester) {
  final image = tester.widget<Image>(
    find.descendant(
      of: find.byType(AppBrandIcon),
      matching: find.byType(Image),
    ),
  );
  return (image.image as AssetImage).assetName;
}
