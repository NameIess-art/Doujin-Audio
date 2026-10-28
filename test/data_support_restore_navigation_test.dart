import 'dart:async';

import 'package:doujin_audio/app/application/app_runtime_lifecycle.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/features/data_support/application/data_backup_service.dart';
import 'package:doujin_audio/features/data_support/application/data_support_file_service.dart';
import 'package:doujin_audio/features/data_support/presentation/data_support_settings_controls.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  for (final outcome in ['success', 'cancel', 'failure', 'incompatible']) {
    testWidgets(
      'restore staging protects navigation and handles $outcome',
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
        await tester.pumpAndSettle();
        await tester.tap(find.text(i18n.tr('select_backup')));
        // The pending picker/staging operation intentionally keeps animating.
        for (var i = 0; i < 15 && files.calls == 0; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(files.calls, 1);
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        final navigator = Navigator.of(
          tester.element(find.byType(CircularProgressIndicator).last),
        );
        await navigator.maybePop();
        await tester.pump(const Duration(milliseconds: 250));
        expect(files.calls, 1);
        expect(find.byType(CircularProgressIndicator), findsWidgets);

        if (outcome == 'failure') {
          files.pending.completeError(StateError('invalid backup'));
        } else if (outcome == 'incompatible') {
          files.pending.completeError(
            const FormatException('incompatible_backup'),
          );
        } else if (outcome == 'cancel') {
          files.pending.complete(null);
        } else {
          files.pending.complete(
            BackupValidationResult(
              manifest: BackupManifest(
                formatVersion: 1,
                appVersion: '1.0.0',
                databaseSchemaVersion: 1,
                platform: 'windows',
                createdAt: DateTime(2026),
                containsSensitiveAccountData: false,
                files: const {},
              ),
            ),
          );
        }
        if (outcome == 'success') {
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
            expect(find.textContaining(i18n.tr('backup_incompatible')), findsOneWidget);
            expect(find.text(i18n.tr('retry')), findsNothing);
          }
          if (outcome == 'failure') {
            expect(find.text(i18n.tr('operation_failed')), findsOneWidget);
          }
        }
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
  final pending = Completer<BackupValidationResult?>();
  var calls = 0;

  @override
  Future<BackupValidationResult?> pickAndStageBackup({
    required String dialogTitle,
  }) {
    calls++;
    return pending.future;
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
  Future<void> dispose() async {}

  @override
  Future<void> handleMemoryPressure() async {}
}
