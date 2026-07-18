import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
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
      final rewardButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, i18n.tr('about_reward')),
      );
      expect(rewardButton.onPressed, isNotNull);
      expect(find.text('NameIess-art'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      final appTitle = find.text(i18n.tr('app_title'));
      final appTitleContext = tester.element(appTitle);
      final aboutSurface = tester
          .widgetList<Container>(
            find.ancestor(of: appTitle, matching: find.byType(Container)),
          )
          .firstWhere(
            (container) =>
                container.decoration is BoxDecoration &&
                (container.decoration! as BoxDecoration).color ==
                    Theme.of(appTitleContext).colorScheme.surfaceContainerLow,
          );
      expect(
        (aboutSurface.decoration! as BoxDecoration).border,
        isNull,
        reason: 'About-page item groups should not paint a card outline.',
      );

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

  testWidgets('reward opens the Afdian custom sponsorship order page', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    final updateService = _FakeAppUpdateService(openResult: true);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        ProviderScope(
          overrides: [
            appUpdateServiceProvider.overrideWithValue(updateService),
          ],
          child: AboutPage(
            versionFuture: Future.value(
              const AppVersionInfo(versionName: '1.2.3', buildNumber: 123),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rewardFinder = find.text(harness.languageProvider.tr('about_reward'));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(rewardFinder);
    await tester.pump();

    expect(
      updateService.openedUrl,
      'https://ifdian.net/order/create?user_id='
      'c6acfc3a646d11f0ae8a5254001e7c00',
    );
  });

  testWidgets('reward shows a warning when the sponsorship page cannot open', (
    tester,
  ) async {
    final harness = AppRuntimeWidgetTestFixture();
    final updateService = _FakeAppUpdateService(openResult: false);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        ProviderScope(
          overrides: [
            appUpdateServiceProvider.overrideWithValue(updateService),
          ],
          child: AboutPage(
            versionFuture: Future.value(
              const AppVersionInfo(versionName: '1.2.3', buildNumber: 123),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final i18n = harness.languageProvider;
    final rewardFinder = find.text(i18n.tr('about_reward'));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(rewardFinder);
    await tester.pump();

    expect(find.text(i18n.tr('about_reward_open_failed')), findsOneWidget);
  });
}

final class _FakeAppUpdateService extends AppUpdateService {
  _FakeAppUpdateService({required this.openResult});

  final bool openResult;
  String? openedUrl;

  @override
  Future<bool> openReleasePage(String url) async {
    openedUrl = url;
    return openResult;
  }
}
