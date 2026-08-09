import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  testWidgets('ASMR logout failure restores the action and shows feedback', (
    tester,
  ) async {
    final controller = _LogoutFailureAsmrLibraryController();
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(() {
      controller.dispose();
      fixture.dispose();
    });

    await tester.pumpWidget(
      fixture.build(
        const AsmrTab(),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    final i18n = fixture.languageProvider;
    final accountButton = find.byTooltip(i18n.tr('asmr_account_menu'));
    await pumpUntilFound(tester, accountButton);
    await tester.tap(accountButton);
    await pumpUntilFound(tester, find.text(i18n.tr('asmr_logout_action')));
    final panelSurface = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('asmr_panel_surface')),
    );
    final panelDecoration = panelSurface.decoration as BoxDecoration;
    expect(panelDecoration.color!.a, 1);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('asmr_panel_surface')),
        matching: find.byType(ScaleTransition),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(i18n.tr('asmr_logout_action')));
    await pumpUntilFound(tester, find.text(i18n.tr('operation_failed_retry')));

    final logoutButton = tester.widget<TextButton>(
      find
          .ancestor(
            of: find.text(i18n.tr('asmr_logout_action')),
            matching: find.byType(TextButton),
          )
          .first,
    );
    expect(controller.logoutAttempts, 1);
    expect(logoutButton.onPressed, isNotNull);
  });
}

class _LogoutFailureAsmrLibraryController extends AsmrLibraryController {
  _LogoutFailureAsmrLibraryController()
    : super(
        preferencesStore: AsmrPreferencesStore(
          repository: SqliteAsmrRepository(database: AppDatabase.instance),
        ),
      );

  int logoutAttempts = 0;

  @override
  bool get initialized => true;

  @override
  bool get isAsmrAccountLoggedIn => true;

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: true,
    visibleCategories: kDefaultVisibleAsmrCategories,
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: 0,
  );

  @override
  AsmrAuthViewState get authViewState => const AsmrAuthViewState(
    isLoggedIn: true,
    isRestoring: false,
    userName: 'alice',
    revision: 0,
  );

  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {
    notifyListeners();
  }

  @override
  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {}

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}

  @override
  Future<void> syncAsmrAccount({bool force = false}) async {}

  @override
  Future<void> logoutAsmrAccount() async {
    logoutAttempts++;
    throw StateError('simulated logout failure');
  }
}
