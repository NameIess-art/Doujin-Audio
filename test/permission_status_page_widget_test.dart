import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/screens/permission_status_page.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('permission center groups optional capabilities by purpose', (
    tester,
  ) async {
    final language = AppLanguageProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: language,
        child: const MaterialApp(home: PermissionStatusPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(language.tr('permission_group_playback')), findsOneWidget);
    expect(
      find.text(language.tr('permission_group_reliability')),
      findsOneWidget,
    );
    expect(find.text(language.tr('permission_group_advanced')), findsOneWidget);
  });
}
