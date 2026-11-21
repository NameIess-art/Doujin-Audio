import 'dart:async';

import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/widgets/app_edit_panel.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'support/asmr_controller_test_fixture.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  testWidgets(
    'ASMR login uses the shared editor in its original overlay',
    (tester) async {
      final controller = _LoginPanelAsmrLibraryController(
        createTestAsmrServices(),
      );
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
      final form = find.byType(AppEditPanelForm);
      await pumpUntilFound(tester, form);
      expect(
        find.ancestor(of: form, matching: find.byType(AppEditPanelSurface)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: form, matching: find.byType(ScaleTransition)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('app_overlay_panel_scrim')),
        findsOneWidget,
      );
      final fields = find.descendant(
        of: form,
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(2));
      expect(
        tester.widget<TextField>(fields.first).textInputAction,
        TextInputAction.next,
      );
      expect(tester.widget<TextField>(fields.last).obscureText, isTrue);
      expect(tester.widget<AppEditPanelForm>(form).onSubmit, isNull);

      await tester.enterText(fields.first, '  alice  ');
      await tester.enterText(fields.last, 'secret');
      await tester.pump();
      expect(tester.widget<AppEditPanelForm>(form).onSubmit, isNotNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(controller.loginAttempt, ('alice', 'secret'));
      expect(tester.widget<AppEditPanelForm>(form).onCancel, isNull);
      expect(tester.widget<AppEditPanelForm>(form).onSubmit, isNull);
      expect(tester.widget<TextField>(fields.last).enabled, isFalse);
      controller.login.complete();
      await tester.pump();
      expect(tester.widget<AppEditPanelForm>(form).onSubmit, isNotNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('ASMR logout failure restores the action and shows feedback', (
    tester,
  ) async {
    final controller = _LogoutFailureAsmrLibraryController(
      createTestAsmrServices(),
    );
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
    final panelSurface = find.byKey(const ValueKey('asmr_panel_surface'));
    final panelMaterial = find
        .descendant(of: panelSurface, matching: find.byType(Material))
        .first;
    expect(tester.widget<Material>(panelMaterial).color!.a, 1);
    expect(
      find.ancestor(of: panelSurface, matching: find.byType(ScaleTransition)),
      findsOneWidget,
    );
    final logoutFinder = find
        .ancestor(
          of: find.text(i18n.tr('asmr_logout_action')),
          matching: find.byType(TextButton),
        )
        .first;
    final syncFinder = find
        .ancestor(
          of: find.text(i18n.tr('asmr_account_sync_now')),
          matching: find.byType(FilledButton),
        )
        .first;
    expect(tester.getSize(logoutFinder).height, 48);
    expect(tester.getSize(syncFinder).height, 48);
    final statusBox = tester.widget<DecoratedBox>(
      find
          .ancestor(
            of: find.text(i18n.tr('asmr_logged_in_as', {'name': 'alice'})),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final statusDecoration = statusBox.decoration as BoxDecoration;
    final panelContext = tester.element(panelSurface);
    expect(
      statusDecoration.color,
      Theme.of(panelContext).colorScheme.surfaceContainer,
    );
    expect(
      statusDecoration.borderRadius,
      BorderRadius.circular(AppDesignTokens.of(panelContext).radiusCard),
    );

    await tester.tap(find.text(i18n.tr('asmr_logout_action')));
    await pumpUntilFound(
      tester,
      find.textContaining(i18n.tr('operation_failed_retry')),
    );

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

  testWidgets(
    'Windows ASMR account logout button highlights and keeps its size',
    (tester) async {
      final controller = _LogoutFailureAsmrLibraryController(
        createTestAsmrServices(),
      );
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
      await tester.pumpAndSettle();
      await tester.tap(accountButton);
      final logoutText = find.text(i18n.tr('asmr_logout_action'));
      await pumpUntilFound(tester, logoutText);

      final logoutFinder = find
          .ancestor(of: logoutText, matching: find.byType(TextButton))
          .first;
      final restColor = DefaultTextStyle.of(
        tester.element(logoutText),
      ).style.color;
      final logoutMaterial = find.descendant(
        of: logoutFinder,
        matching: find.byType(Material),
      );
      final restBackground = tester.widget<Material>(logoutMaterial).color;

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      await mouse.moveTo(tester.getCenter(logoutFinder));
      await tester.pumpAndSettle();

      double readScale() => tester
          .widgetList<Transform>(
            find.ancestor(of: logoutText, matching: find.byType(Transform)),
          )
          .where((t) => !t.transformHitTests)
          .fold<double>(1.0, (p, t) => p * t.transform.entry(0, 0));

      expect(readScale(), closeTo(1.0, 0.001));
      expect(
        DefaultTextStyle.of(tester.element(logoutText)).style.color,
        isNot(equals(restColor)),
      );
      expect(tester.widget<Material>(logoutMaterial).color, restBackground);

      await mouse.down(tester.getCenter(logoutFinder));
      await tester.pumpAndSettle();
      expect(readScale(), 1.0);
      await mouse.up();
      await tester.pumpAndSettle();
      await mouse.removePointer();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

class _LoginPanelAsmrLibraryController
    extends LoadedEmptyAsmrLibraryController {
  _LoginPanelAsmrLibraryController(super.services);

  final login = Completer<void>();
  (String, String)? loginAttempt;

  @override
  AsmrAuthViewState get authViewState => const AsmrAuthViewState(
    isLoggedIn: false,
    isRestoring: false,
    userName: '',
    revision: 0,
  );

  @override
  Future<void> loginAsmrAccount(String name, String password) {
    loginAttempt = (name, password);
    return login.future;
  }
}

class _LogoutFailureAsmrLibraryController
    extends LoadedEmptyAsmrLibraryController {
  _LogoutFailureAsmrLibraryController(super.services);

  int logoutAttempts = 0;

  @override
  bool get isAsmrAccountLoggedIn => true;

  @override
  AsmrAuthViewState get authViewState => const AsmrAuthViewState(
    isLoggedIn: true,
    isRestoring: false,
    userName: 'alice',
    revision: 0,
  );

  @override
  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {}

  @override
  Future<void> syncAsmrAccount({bool force = false}) async {}

  @override
  Future<void> logoutAsmrAccount() async {
    logoutAttempts++;
    throw StateError('simulated logout failure');
  }
}
