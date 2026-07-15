import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/core/platform/permission_action_controller.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:nameless_audio/features/settings/presentation/app_update_flow.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('automatic and manual checks share the same operation flow', (
    tester,
  ) async {
    final operations = UiOperationService();
    final permissionController = PermissionActionController();
    addTearDown(operations.dispose);
    addTearDown(permissionController.dispose);
    var checks = 0;
    final flow = AppUpdateFlow(
      permissionController: permissionController,
      languageProvider: AppLanguageProvider(),
      updateService: AppUpdateService(),
      checkLatest: () async {
        checks++;
        return const AppUpdateInfo(
          currentVersion: AppVersionInfo(
            versionName: '0.13.0',
            buildNumber: 1300,
          ),
          latestVersionName: '0.13.0',
          tagName: 'v0.13.0',
          assetName: null,
          assetUrl: null,
          checksumAssetUrl: null,
          releaseUrl: 'https://example.test/releases',
          isUpdateAvailable: false,
          status: AppUpdateStatus.upToDate,
        );
      },
    );
    late BuildContext context;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppLanguageProvider(),
        child: MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      ),
    );

    await flow.checkAndPresent(
      context: context,
      operations: operations,
      automatic: true,
    );

    await flow.checkAndPresent(context: context, operations: operations);
    expect(checks, 2);
    expect(
      operations.operationFor(UiOperationScope.settingsUpdate).phase,
      UiOperationPhase.succeeded,
    );
  });
}
