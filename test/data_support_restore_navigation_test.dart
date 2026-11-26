import 'dart:async';

import 'package:doujin_audio/app/application/app_runtime_lifecycle.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/widgets/app_dialog.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/features/data_support/application/cross_platform_sync_service.dart';
import 'package:doujin_audio/features/data_support/application/data_backup_service.dart';
import 'package:doujin_audio/features/data_support/application/data_support_file_service.dart';
import 'package:doujin_audio/features/data_support/domain/cross_platform_sync_models.dart';
import 'package:doujin_audio/features/data_support/presentation/data_support_settings_controls.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  for (final outcome in [
    'success',
    'merge_sync',
    'cancel',
    'failure',
    'incompatible',
  ]) {
    testWidgets(
      'restore uses menu-bar progress and protects navigation on $outcome',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final files = _DeferredRestoreFileService();
        final playback = _RestorePlaybackRepository();
        final fixture = AppRuntimeWidgetTestFixture(
          providedNativePlaybackRepository: playback,
        );
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const Scaffold(body: DataSupportSettingsControls()),
                  ),
                ),
                child: const Text('Open data settings'),
              ),
            ),
            overrides: [
              // Navigation is under test; native runtime startup is independent
              // and requires platform plugins absent from this widget harness.
              audioRuntimeCoordinatorProvider.overrideWithValue(
                _RestoreTestRuntime(),
              ),
              dataSupportFileServiceProvider.overrideWithValue(files),
            ],
          ),
        );
        await tester.tap(find.text('Open data settings'));
        await tester.pumpAndSettle();
        final i18n = fixture.languageProvider;
        await tester.tap(
          find.byKey(const ValueKey('data-support-restore-backup')),
        );
        for (var i = 0; i < 15 && files.pickCalls == 0; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(files.pickCalls, 1);
        await tester.pump();
        final progress = find.widgetWithText(
          AppFeedbackSurface,
          i18n.tr('loading_dot'),
        );
        // Progress feedback must not appear while the native file picker is open.
        expect(progress, findsNothing);
        if (outcome == 'cancel') {
          files.pendingPick.complete(null);
          await tester.pumpAndSettle();
          expect(files.inspectCalls, 0);
          expect(files.stageCalls, 0);
          expect(progress, findsNothing);
          expect(find.text(i18n.tr('backup_ready_to_restore')), findsNothing);
          expect(playback.clearCalls, 0);
          final navigator = Navigator.of(
            tester.element(find.byType(DataSupportSettingsControls)),
          );
          await navigator.maybePop();
          await tester.pumpAndSettle();
          expect(find.text('Open data settings'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          return;
        }
        files.pendingPick.complete(
          PlatformFile(
            name: 'backup.dabackup',
            size: 128,
            path: '/backup.dabackup',
          ),
        );
        for (var i = 0; i < 15 && files.inspectCalls == 0; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(files.inspectCalls, 1);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(progress, findsOneWidget);
        expect(
          find.descendant(
            of: progress,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expect(find.byType(AppDialog), findsNothing);
        final navigator = Navigator.of(
          tester.element(find.byType(DataSupportSettingsControls)),
        );
        await navigator.maybePop();
        await tester.pump(const Duration(seconds: 6));
        expect(files.inspectCalls, 1);
        expect(progress, findsOneWidget);
        expect(find.byType(DataSupportSettingsControls), findsOneWidget);

        if (outcome == 'failure') {
          files.pendingInspect.completeError(StateError('invalid backup'));
        } else if (outcome == 'incompatible') {
          files.pendingInspect.completeError(
            const FormatException('unsupported_database_schema'),
          );
        } else {
          files.pendingInspect.complete(
            BackupInspectionResult(
              manifest: BackupManifest(
                formatVersion: 1,
                appVersion: '1.0.0',
                databaseSchemaVersion: 23,
                platform: outcome == 'merge_sync' ? 'android' : 'windows',
                createdAt: DateTime.utc(2026, 11, 26),
                containsSensitiveAccountData: true,
                files: const {},
              ),
              isSamePlatform: outcome != 'merge_sync',
              hasAccountData: false,
            ),
          );
        }

        if (outcome == 'success') {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(AppDialog), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('backup-import-confirm')));
          for (var i = 0; i < 15 && files.stageCalls == 0; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(files.stageCalls, 1);
          files.pendingStage.complete(
            BackupValidationResult(
              manifest: BackupManifest(
                formatVersion: 1,
                appVersion: '1.0.0',
                databaseSchemaVersion: 23,
                platform: 'windows',
                createdAt: DateTime.utc(2026, 11, 26),
                containsSensitiveAccountData: true,
                files: const {},
              ),
            ),
          );
          // The restore operation remains busy until the app closes, so the
          // obscured settings progress indicator intentionally keeps ticking.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text(i18n.tr('backup_ready_to_restore')), findsOneWidget);
          expect(find.text(i18n.tr('close_app')), findsOneWidget);
          expect(playback.clearCalls, 1);
          await navigator.maybePop();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text(i18n.tr('backup_ready_to_restore')), findsOneWidget);
          // Forced teardown dismisses the non-dismissible completion dialog.
          navigator.pop();
          await tester.pumpAndSettle();
        } else if (outcome == 'merge_sync') {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            find.text(i18n.tr('backup_import_cross_platform_hint')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('backup-import-confirm')));
          for (var i = 0; i < 15 && files.mergeCalls == 0; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(files.mergeCalls, 1);
          files.pendingMerge.complete(
            const BackupMergeResult(
              syncSummary: CrossPlatformSyncSummary(
                trackStatesMerged: 2,
                listeningDaysUpdated: 1,
                timeSegmentsMerged: 3,
                interestsChanged: false,
                peersMerged: 1,
              ),
              accountSynced: false,
              portableSettingsSynced: false,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(i18n.tr('backup_ready_to_restore')), findsNothing);
          expect(playback.clearCalls, 0);
          expect(find.text(i18n.tr('operation_completed')), findsOneWidget);
        } else {
          if (outcome == 'incompatible') {
            // Feedback without an action animates until timeout.
            for (var i = 0; i < 8; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
          } else {
            await tester.pumpAndSettle();
          }
          expect(find.text(i18n.tr('backup_ready_to_restore')), findsNothing);
          expect(playback.clearCalls, 0);
          if (outcome == 'incompatible') {
            expect(
              find.textContaining(i18n.tr('backup_incompatible')),
              findsOneWidget,
            );
            expect(find.text(i18n.tr('retry')), findsNothing);
          }
          if (outcome == 'failure') {
            expect(find.text(i18n.tr('operation_failed')), findsOneWidget);
          }
        }
        expect(progress, findsNothing);
        await navigator.maybePop();
        await tester.pumpAndSettle();
        expect(find.text('Open data settings'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }
}

class _DeferredRestoreFileService extends DataSupportFileService {
  final pendingPick = Completer<PlatformFile?>();
  final pendingInspect = Completer<BackupInspectionResult>();
  final pendingStage = Completer<BackupValidationResult>();
  final pendingMerge = Completer<BackupMergeResult>();
  var pickCalls = 0;
  var inspectCalls = 0;
  var stageCalls = 0;
  var mergeCalls = 0;

  @override
  Future<PlatformFile?> pickBackupFile({required String dialogTitle}) {
    pickCalls++;
    return pendingPick.future;
  }

  @override
  Future<BackupInspectionResult> inspectBackupPath(String sourcePath) {
    inspectCalls++;
    return pendingInspect.future;
  }

  @override
  Future<BackupValidationResult> stageRestorePath(String sourcePath) {
    stageCalls++;
    return pendingStage.future;
  }

  @override
  Future<BackupMergeResult> mergeBackupPath(
    String sourcePath, {
    required CrossPlatformSyncService syncService,
    bool syncAccountAndPortableSettings = false,
  }) {
    mergeCalls++;
    return pendingMerge.future;
  }
}

class _RestorePlaybackRepository extends NativePlaybackRepository {
  var clearCalls = 0;

  @override
  Future<NativeResult<void>> clearAll() async {
    clearCalls++;
    return const NativeSuccess();
  }
}

class _RestoreTestRuntime implements AppRuntimeLifecycle {
  @override
  Future<void> start() async {}

  @override
  Future<void> initializeSecondaryData() async {}

  @override
  Future<void> enterBackground() async {}

  @override
  Future<void> resumeForeground() async {}

  @override
  Future<void> dispose({bool fastShutdown = false}) async {}

  @override
  Future<void> handleMemoryPressure() async {}
}
