import 'package:flutter/material.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../core/widgets/app_feedback.dart';
import '../application/library_scan_models.dart';

class LibraryScanFeedback {
  const LibraryScanFeedback({
    required this.message,
    required this.tone,
    required this.icon,
  });

  final String message;
  final AppFeedbackTone tone;
  final IconData icon;
}

abstract final class LibraryScanPresentationMapper {
  static LibraryScanLabels labels(AppLanguageProvider i18n) =>
      LibraryScanLabels(
        chooseMusicFolder: i18n.tr('choose_music_folder'),
        chooseLibraryFolder: i18n.tr('choose_library_folder'),
        chooseAudioFiles: i18n.tr('choose_audio_files'),
        importedFiles: i18n.tr('imported_files'),
        manuallySelectedFiles: i18n.tr('manually_selected_files'),
      );

  static LibraryScanFeedback? feedback(
    LibraryScanOutcome outcome,
    AppLanguageProvider i18n,
  ) {
    if (outcome.code == LibraryScanOutcomeCode.noSources) return null;
    final detailImportFailureCount =
        (outcome.details['detailImportFailureCount'] as int?) ?? 0;
    if (detailImportFailureCount > 0) {
      return LibraryScanFeedback(
        message: i18n.tr('detail_backup_import_failed', {
          'count': detailImportFailureCount,
        }),
        tone: AppFeedbackTone.warning,
        icon: Icons.sync_problem_rounded,
      );
    }
    final isFailure = switch (outcome.code) {
      LibraryScanOutcomeCode.permissionDenied ||
      LibraryScanOutcomeCode.failed ||
      LibraryScanOutcomeCode.alreadyRunning => true,
      _ => false,
    };
    final isCancelled = outcome.code == LibraryScanOutcomeCode.cancelled;
    return LibraryScanFeedback(
      message: switch (outcome.code) {
        LibraryScanOutcomeCode.noSources => '',
        LibraryScanOutcomeCode.permissionDenied => i18n.tr(
          'need_storage_permission_scan_folder',
        ),
        LibraryScanOutcomeCode.alreadyRunning => i18n.tr('scanning_title'),
        LibraryScanOutcomeCode.folderExists => i18n.tr('library_folder_exists'),
        LibraryScanOutcomeCode.libraryExists => i18n.tr('library_exists'),
        LibraryScanOutcomeCode.fileExists => i18n.tr('library_file_exists'),
        LibraryScanOutcomeCode.cancelled => i18n.tr('scan_cancelled'),
        LibraryScanOutcomeCode.failed => i18n.tr('scan_failed_next_step'),
        LibraryScanOutcomeCode.noAudio => i18n.tr('no_audio_found'),
        LibraryScanOutcomeCode.refreshAdded => i18n.tr('refresh_done_added', {
          'count': outcome.addedCount,
        }),
        LibraryScanOutcomeCode.refreshNoChanges => i18n.tr(
          'refresh_done_no_new',
        ),
        LibraryScanOutcomeCode.importAdded => i18n.tr('import_done_added', {
          'count': outcome.addedCount,
        }),
        LibraryScanOutcomeCode.libraryImported => i18n.tr(
          'import_library_done',
          <String, Object?>{
            'count': outcome.addedCount,
            'folderCount': outcome.folderCount,
          },
        ),
      },
      tone: isFailure
          ? AppFeedbackTone.destructive
          : isCancelled
          ? AppFeedbackTone.warning
          : AppFeedbackTone.success,
      icon: isFailure
          ? Icons.error_outline_rounded
          : isCancelled
          ? Icons.cancel_outlined
          : Icons.check_circle_outline_rounded,
    );
  }
}
