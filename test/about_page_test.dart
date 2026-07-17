import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/settings/application/app_update_models.dart';
import 'package:nameless_audio/features/settings/presentation/about_page.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  testWidgets(
    'about page renders grouped identity, links, author, and reward',
    (tester) async {
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(
          AboutPage(
            versionFuture: Future.value(
              const AppVersionInfo(versionName: '1.2.3', buildNumber: 123),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final i18n = harness.languageProvider;
      expect(find.text(i18n.tr('about')), findsOneWidget);
      expect(find.text(i18n.tr('app_title')), findsOneWidget);
      expect(find.text(i18n.tr('about_version')), findsOneWidget);
      expect(find.text('1.2.3'), findsOneWidget);
      expect(find.text(i18n.tr('about_source_code')), findsOneWidget);
      expect(find.text(i18n.tr('about_wiki')), findsOneWidget);
      expect(find.text(i18n.tr('about_author')), findsOneWidget);
      expect(find.text(i18n.tr('about_reward')), findsOneWidget);
      expect(find.text('NameIess-art'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);

      final versionY = tester.getTopLeft(find.text('1.2.3')).dy;
      final sourceY = tester
          .getTopLeft(find.text(i18n.tr('about_source_code')))
          .dy;
      final wikiY = tester.getTopLeft(find.text(i18n.tr('about_wiki'))).dy;
      final authorY = tester.getTopLeft(find.text(i18n.tr('about_author'))).dy;
      expect(versionY, lessThan(wikiY));
      expect(versionY, lessThan(sourceY));
      expect(sourceY, lessThan(wikiY));
      expect(wikiY, lessThan(authorY));
    },
  );
}
