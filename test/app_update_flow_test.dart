import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/core/ui/permission_action_controller.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/features/settings/application/app_update_service.dart';
import 'package:doujin_audio/features/settings/presentation/app_update_flow.dart';

class _FakeAppUpdateService extends AppUpdateService {
  _FakeAppUpdateService({required this.downloadedFile});

  final File downloadedFile;
  bool installPermissionGranted = false;
  bool openSettingsResult = true;
  bool failDownload = false;
  int openSettingsCalls = 0;
  int openReleasePageCalls = 0;
  int installCalls = 0;
  final List<File> releasedFiles = <File>[];

  @override
  Future<bool> openReleasePage(String releaseUrl) async {
    openReleasePageCalls++;
    return true;
  }

  @override
  Future<bool> canInstallUnknownApps() async => installPermissionGranted;

  @override
  Future<bool> openInstallPermissionSettings() async {
    openSettingsCalls++;
    return openSettingsResult;
  }

  @override
  Future<File> downloadUpdate(
    AppUpdateInfo info, {
    required void Function(double? progress) onProgress,
  }) async {
    if (failDownload) {
      throw StateError('download failed');
    }
    onProgress(1);
    return downloadedFile;
  }

  @override
  Future<UpdateInstallResult> installUpdate(File file) async {
    installCalls++;
    if (!installPermissionGranted) {
      return const UpdateInstallResult(
        ok: false,
        needsPermission: true,
        message: 'Install permission required',
      );
    }
    return const UpdateInstallResult(ok: true, needsPermission: false);
  }

  @override
  void releaseDownloadedUpdate(File file) {
    releasedFiles.add(file);
  }
}

const _availableUpdate = AppUpdateInfo(
  currentVersion: AppVersionInfo(versionName: '0.13.0', buildNumber: 1300),
  latestVersionName: '0.14.0',
  tagName: 'v0.14.0',
  assetName: 'DoujinAudio-v0.14.0.apk',
  assetUrl: 'https://example.test/DoujinAudio-v0.14.0.apk',
  checksumAssetUrl: 'https://example.test/DoujinAudio-v0.14.0.apk.sha256',
  releaseUrl: 'https://example.test/releases/v0.14.0',
  isUpdateAvailable: true,
);

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
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
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

  testWidgets(
    'releases downloaded update when install permission dialog is cancelled or resume stays denied',
    (tester) async {
      for (final mode in ['cancel_dialog', 'resume_denied', 'resume_granted']) {
        final operations = UiOperationService();
        final permissionController = PermissionActionController();
        final language = AppLanguageProvider();
        final file = File('update_$mode.apk');
        final service = _FakeAppUpdateService(downloadedFile: file);
        final flow = AppUpdateFlow(
          permissionController: permissionController,
          languageProvider: language,
          updateService: service,
          checkLatest: () async => _availableUpdate,
        );
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (value) {
                context = value;
                return const Scaffold();
              },
            ),
          ),
        );

        final flowFuture = flow.checkAndPresent(
          context: context,
          operations: operations,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(language.tr('download_update')));
        await tester.pumpAndSettle();

        expect(service.installCalls, 1);
        expect(service.releasedFiles, isEmpty);

        if (mode == 'cancel_dialog') {
          await tester.tap(find.text(language.tr('cancel')));
          await tester.pumpAndSettle();
          await flowFuture;
          expect(service.releasedFiles, [file]);
          expect(service.installCalls, 1);
        } else {
          await tester.tap(find.text(language.tr('go_settings')));
          await tester.pumpAndSettle();
          await flowFuture;
          expect(service.openSettingsCalls, 1);
          // Lease must stay active while user is in system Settings.
          expect(service.releasedFiles, isEmpty);

          service.installPermissionGranted = mode == 'resume_granted';
          final resume = permissionController.handleAppResumed();
          await tester.pump(const Duration(milliseconds: 450));
          await resume;
          await tester.pumpAndSettle();

          if (mode == 'resume_granted') {
            expect(service.installCalls, 2);
            expect(service.releasedFiles, isEmpty);
          } else {
            expect(service.installCalls, 1);
            expect(service.releasedFiles, [file]);
          }
        }

        await operations.dispose();
        permissionController.dispose();
        service.dispose();
        language.dispose();
      }
    },
  );

  testWidgets(
    'update dialog exposes release page link and closing failure dialog clears error banner',
    (tester) async {
      final operations = UiOperationService();
      final permissionController = PermissionActionController();
      final language = AppLanguageProvider();
      final file = File('/tmp/internal/update.exe');
      final service = _FakeAppUpdateService(downloadedFile: file)
        ..failDownload = true
        ..installPermissionGranted = true;
      final flow = AppUpdateFlow(
        permissionController: permissionController,
        languageProvider: language,
        updateService: service,
        checkLatest: () async => _availableUpdate,
      );
      addTearDown(operations.dispose);
      addTearDown(permissionController.dispose);
      addTearDown(service.dispose);
      addTearDown(language.dispose);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );

      final flowFuture = flow.checkAndPresent(
        context: context,
        operations: operations,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(language.tr('open_release_page')));
      await tester.pump();
      expect(service.openReleasePageCalls, 1);

      await tester.tap(find.text(language.tr('download_update')));
      await tester.pumpAndSettle();
      expect(find.text(language.tr('update_download_failed')), findsOneWidget);

      await tester.tap(find.text(language.tr('close')));
      await tester.pumpAndSettle();
      await flowFuture;

      expect(
        operations.operationFor(UiOperationScope.settingsUpdate).hasError,
        isFalse,
      );
      expect(
        operations.operationFor(UiOperationScope.settingsUpdate).phase,
        UiOperationPhase.idle,
      );
    },
  );
}
