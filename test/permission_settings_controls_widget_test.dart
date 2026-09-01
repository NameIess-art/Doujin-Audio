import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/app_settings_group_card.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/widgets/app_settings_action_tile.dart';
import 'package:doujin_audio/core/platform/notifications_platform_service.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';
import 'package:doujin_audio/features/settings/presentation/permission_settings_controls.dart';
import 'package:doujin_audio/features/settings/application/permission_status_service.dart';

void main() {
  testWidgets('permission settings use independent rows with status buttons', (
    tester,
  ) async {
    final language = AppLanguageProvider();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PermissionSettingsControls(
              statusService: PermissionStatusService(
                isAndroidOverride: true,
                powerService: PowerPlatformService(isAndroidOverride: false),
                notificationsService: NotificationsPlatformService(
                  isAndroidOverride: false,
                ),
                overlayCheck: () async => false,
                updateInstallCheck: () async => false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final titles = [
      'notification_permission_status',
      'allow_background_run',
      'exact_alarm_permission_status',
      'manage_files_permission_title',
      'overlay_permission_title',
      'install_permission_title',
    ];
    expect(find.byType(AppSettingsActionTile), findsNWidgets(titles.length));
    expect(find.byType(AppSettingsGroupCard), findsOneWidget);
    expect(find.byType(Card), findsNWidgets(titles.length));
    expect(find.byType(Divider), findsNothing);
    for (final titleKey in titles) {
      final tile = find.widgetWithText(ListTile, language.tr(titleKey));
      expect(tile, findsOneWidget);
      expect(tester.widget<ListTile>(tile).subtitle, isNull);
      expect(
        find.ancestor(of: tile, matching: find.byType(Card)),
        findsOneWidget,
      );
    }
    expect(find.byType(TextButton), findsNWidgets(titles.length));
    expect(find.text(language.tr('permission_enabled')), findsNWidgets(4));
    expect(find.text(language.tr('permission_not_enabled')), findsNWidgets(2));
    final cards = find.byType(Card);
    for (var index = 0; index < titles.length - 1; index++) {
      final gap =
          tester.getTopLeft(cards.at(index + 1)).dy -
          tester.getBottomRight(cards.at(index)).dy;
      expect(gap, closeTo(3, 0.001));
    }
    final firstCardShape =
        tester.widget<Card>(cards.first).shape! as RoundedRectangleBorder;
    final firstBorderRadius = firstCardShape.borderRadius as BorderRadius;
    expect(firstBorderRadius.topLeft, const Radius.circular(12));
    expect(firstBorderRadius.bottomLeft, const Radius.circular(6));
    final lastCardShape =
        tester.widget<Card>(cards.last).shape! as RoundedRectangleBorder;
    final lastBorderRadius = lastCardShape.borderRadius as BorderRadius;
    expect(lastBorderRadius.topLeft, const Radius.circular(6));
    expect(lastBorderRadius.bottomLeft, const Radius.circular(12));
    expect(find.text(language.tr('permission_group_playback')), findsNothing);
    expect(
      find.text(language.tr('permission_group_reliability')),
      findsNothing,
    );
    expect(find.text(language.tr('permission_group_advanced')), findsNothing);
    expect(find.text(language.tr('permission_state_authorized')), findsNothing);
    expect(
      find.text(language.tr('permission_state_unauthorized')),
      findsNothing,
    );
    expect(find.text(language.tr('permission_state_restricted')), findsNothing);
    expect(
      find.text(language.tr('permission_state_recommended')),
      findsNothing,
    );
  });
}
