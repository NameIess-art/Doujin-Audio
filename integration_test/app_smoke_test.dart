import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/main.dart' as app;
import 'package:nameless_audio/screens/main_screen.dart';
import 'package:provider/provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app starts and navigates across top-level pages', (tester) async {
    await app.main(const <String>[]);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.byType(MainScreen), findsOneWidget);
    final context = tester.element(find.byType(MainScreen));
    final i18n = Provider.of<AppLanguageProvider>(context, listen: false);

    for (final label in <String>[
      'nav_library',
      'nav_sessions',
      'nav_settings',
    ]) {
      await tester.tap(find.text(i18n.tr(label)).last);
      await tester.pumpAndSettle();
    }
  });
}
