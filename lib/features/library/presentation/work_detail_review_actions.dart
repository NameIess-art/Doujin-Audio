import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_display.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/work_review_panel.dart';
import '../application/audio_detail_repository.dart';
import 'library_providers.dart';

Future<AudioDetailSaveResult?> saveLocalWorkUserReviewWithFeedback(
  BuildContext context,
  WidgetRef ref,
  AudioDetailTarget target,
  WorkReviewDraft draft,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final library = container.read(libraryFacadeProvider);
  final i18n = container.read(appLanguageProviderInstanceProvider);
  try {
    final result = await library.saveAudioUserReview(
      target,
      listenStatus: draft.listenStatus,
      userRating: draft.userRating,
      reviewText: draft.reviewText,
    );
    if (result.documentFailed && context.mounted) {
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_backup_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
    return result;
  } catch (_) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.destructive,
      );
    }
    return null;
  }
}

Future<AudioDetail?> openLocalWorkReviewEditor(
  BuildContext context,
  WidgetRef ref,
  AudioDetailTarget target, {
  String fallbackTitle = '',
  AudioDetail? initialDetail,
}) async {
  final library = ref.read(libraryFacadeProvider);
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  var detail =
      initialDetail ??
      library.resolvedAudioDetail(target) ??
      library.categorySnapshot?.detailFor(target);
  if (detail == null) {
    try {
      detail = (await library.loadAudioDetail(target)).detail;
    } catch (_) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('operation_failed_retry'),
          tone: AppFeedbackTone.destructive,
        );
      }
      return null;
    }
  }
  if (!context.mounted) return null;
  final resolvedTitle = detail.workTitle.trim().isNotEmpty
      ? detail.workTitle.trim()
      : (fallbackTitle.trim().isNotEmpty
            ? fallbackTitle.trim()
            : PathDisplay.fileName(
                target.targetPath,
                withoutExtension: !target.isLibraryRootFolder,
              ));
  final draft = await showWorkReviewEditPanel(
    context: context,
    workTitle: resolvedTitle,
    rjCode: detail.rjCode,
    initialStatus: detail.listenStatus,
    initialUserRating: detail.userRating,
    initialReviewText: detail.reviewText,
    syncsWithCloud:
        AudioDetail.findRjCodeInText(detail.rjCode) != null &&
        ref.read(asmrCloudReviewAvailableProvider)(),
    translate: i18n.tr,
  );
  if (draft == null || !context.mounted) return null;
  final saved = await saveLocalWorkUserReviewWithFeedback(
    context,
    ref,
    target,
    draft,
  );
  return saved?.detail;
}
