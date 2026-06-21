import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/screens/permission_status_page.dart';
import 'package:nameless_audio/services/permission_status_service.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('permission center groups optional capabilities by purpose', (
    tester,
  ) async {
    final language = AppLanguageProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: language,
        child: MaterialApp(
          home: PermissionStatusPage(
            statusService: _FakePermissionStatusService(
              const PermissionStatusSnapshot(
                notificationsEnabled: false,
                backgroundRunAllowed: false,
                exactAlarmsAllowed: true,
                manageFilesAllowed: false,
                overlayAllowed: true,
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
}

class _FakePermissionStatusService extends PermissionStatusService {
  _FakePermissionStatusService(this.snapshot) : super(isAndroidOverride: false);

  final PermissionStatusSnapshot snapshot;

  @override
  Future<PermissionStatusSnapshot> load() async => snapshot;
}
