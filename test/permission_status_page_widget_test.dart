import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/features/settings/presentation/permission_status_page.dart';
import 'package:nameless_audio/features/settings/application/permission_status_service.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:nameless_audio/core/widgets/operation_feedback.dart';

void main() {
  testWidgets('permission center groups optional capabilities by purpose', (
    tester,
  ) async {
    final language = AppLanguageProvider();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
          appUpdateServiceProvider.overrideWithValue(AppUpdateService()),
        ],
        child: MaterialApp(
          home: PermissionStatusPage(
            statusService: _FakePermissionStatusService(
              const PermissionStatusSnapshot(
                notificationsEnabled: false,
                backgroundRunAllowed: false,
                exactAlarmsAllowed: true,
                overlayAllowed: false,
                updateInstallsAllowed: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(language.tr('permission_group_playback')), findsOneWidget);
    expect(
      find.text(language.tr('permission_group_reliability')),
      findsOneWidget,
    );
    expect(find.text(language.tr('permission_group_advanced')), findsOneWidget);
    expect(find.text(language.tr('permission_state_authorized')), findsWidgets);
    expect(
      find.text(language.tr('permission_state_unauthorized')),
      findsWidgets,
    );
    expect(find.text(language.tr('permission_state_restricted')), findsWidgets);
    expect(
      find.text(language.tr('permission_state_recommended')),
      findsWidgets,
    );
  });

  testWidgets('permission center shows shell while status loads', (
    tester,
  ) async {
    final language = AppLanguageProvider();
    final completer = Completer<PermissionStatusSnapshot>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
          appUpdateServiceProvider.overrideWithValue(AppUpdateService()),
        ],
        child: MaterialApp(
          home: PermissionStatusPage(
            statusService: _DelayedPermissionStatusService(completer.future),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(language.tr('permission_center')), findsOneWidget);
    expect(find.byType(OperationSkeletonList), findsOneWidget);

    completer.complete(
      const PermissionStatusSnapshot(
        notificationsEnabled: true,
        backgroundRunAllowed: true,
        exactAlarmsAllowed: true,
        overlayAllowed: true,
        updateInstallsAllowed: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OperationSkeletonList), findsNothing);
    expect(find.text(language.tr('permission_group_playback')), findsOneWidget);
  });
}

class _FakePermissionStatusService extends PermissionStatusService {
  _FakePermissionStatusService(this.snapshot) : super(isAndroidOverride: false);

  final PermissionStatusSnapshot snapshot;

  @override
  Future<PermissionStatusSnapshot> load() async => snapshot;
}

class _DelayedPermissionStatusService extends PermissionStatusService {
  _DelayedPermissionStatusService(this.future)
    : super(isAndroidOverride: false);

  final Future<PermissionStatusSnapshot> future;

  @override
  Future<PermissionStatusSnapshot> load() => future;
}
