import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/work_review_panel.dart';
import '../application/asmr_library_controller.dart';
import '../domain/asmr_models.dart';
import 'asmr_providers.dart';

Future<bool> setAsmrWorksFavoriteWithFeedback(
  BuildContext context,
  WidgetRef ref,
  List<AsmrWork> works, {
  bool? favorite,
}) {
  final feedbackContext = Scaffold.maybeOf(context)?.context ?? context;
  return _setFavoriteWithFeedback(
    feedbackContext,
    ProviderScope.containerOf(context, listen: false),
    works,
    favorite: favorite,
  );
}

Future<bool> _setFavoriteWithFeedback(
  BuildContext context,
  ProviderContainer container,
  List<AsmrWork> works, {
  bool? favorite,
}) async {
  if (works.isEmpty || !context.mounted) return false;
  final controller = container.read(asmrLibraryControllerProvider);
  if (controller == null) return false;
  final operations = container.read(uiOperationServiceProvider);
  final scopes = works
      .map(
        (work) =>
            UiOperationScope.asmrWork(AsmrOperationKind.favorite, work.workKey),
      )
      .toSet()
      .toList(growable: false);
  if (scopes.any(operations.isBusy)) return false;
  final shouldFavorite =
      favorite ?? works.any((work) => !controller.isFavorite(work.workKey));
  final i18n = container.read(appLanguageProviderInstanceProvider);
  final accent = Theme.of(context).colorScheme.primary;

  // Reserve all selected works before saving so card and batch actions cannot
  // race while the shared controller persists the same favorites.
  Future<void> save(int index) => index == scopes.length
      ? controller.setFavorites(works, favorite: shouldFavorite)
      : operations.run<void>(
          scope: scopes[index],
          labelKey: 'loading_dot',
          task: (_) => save(index + 1),
          cancelPrevious: false,
        );
  try {
    await save(0);
  } catch (_) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        i18n.tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    }
    return false;
  }
  if (!context.mounted) return true;
  showAppSnackBar(
    context,
    i18n.tr(shouldFavorite ? 'asmr_favorite_added' : 'asmr_favorite_removed'),
    tone: shouldFavorite ? AppFeedbackTone.success : AppFeedbackTone.warning,
    icon: shouldFavorite
        ? Icons.favorite_rounded
        : Icons.favorite_border_rounded,
    iconColor: accent,
    actionLabel: shouldFavorite ? null : i18n.tr('undo'),
    onAction: shouldFavorite
        ? null
        : () {
            if (!context.mounted) return;
            unawaited(
              _setFavoriteWithFeedback(
                context,
                container,
                works,
                favorite: true,
              ),
            );
          },
    isUndoAction: !shouldFavorite,
  );
  return true;
}

WorkReviewDraft readAsmrWorkReviewDraft(
  AsmrLibraryController? controller,
  AsmrWork work,
) {
  final reviewed = controller?.reviewForWork(work);
  if (reviewed != null) {
    return (
      listenStatus: reviewed.listenStatus,
      userRating: reviewed.userRating,
      reviewText: reviewed.reviewText,
    );
  }
  final isFavorite = controller?.isFavorite(work.workKey) ?? work.isFavorite;
  if (controller?.initialized ?? false) {
    return (
      listenStatus: isFavorite ? WorkListenStatus.marked : null,
      userRating: null,
      reviewText: '',
    );
  }
  return (
    listenStatus: isFavorite
        ? WorkListenStatus.marked
        : (work.listenStatus == WorkListenStatus.marked
              ? null
              : work.listenStatus),
    userRating: work.userRating,
    reviewText: work.reviewText,
  );
}

Future<bool> saveAsmrWorkReviewWithFeedback(
  BuildContext context,
  WidgetRef ref,
  AsmrWork work,
  WorkReviewDraft draft,
) async {
  final feedbackContext = Scaffold.maybeOf(context)?.context ?? context;
  final container = ProviderScope.containerOf(context, listen: false);
  final controller = container.read(asmrLibraryControllerProvider);
  final current = readAsmrWorkReviewDraft(controller, work);
  if (draft.userRating == null &&
      draft.reviewText.isEmpty &&
      current.userRating == null &&
      current.reviewText.isEmpty &&
      (draft.listenStatus == WorkListenStatus.marked ||
          (draft.listenStatus == null &&
              current.listenStatus == WorkListenStatus.marked))) {
    return setAsmrWorksFavoriteWithFeedback(context, ref, [
      work,
    ], favorite: draft.listenStatus == WorkListenStatus.marked);
  }
  if (controller == null || !feedbackContext.mounted) return false;
  final operations = container.read(uiOperationServiceProvider);
  final scope = UiOperationScope.asmrWork(
    AsmrOperationKind.favorite,
    work.workKey,
  );
  if (operations.isBusy(scope)) return false;
  final i18n = container.read(appLanguageProviderInstanceProvider);
  try {
    await operations.run<void>(
      scope: scope,
      labelKey: 'loading_dot',
      cancelPrevious: false,
      task: (_) => controller.saveWorkReview(
        work,
        listenStatus: draft.listenStatus,
        userRating: draft.userRating,
        reviewText: draft.reviewText,
      ),
    );
    return true;
  } catch (_) {
    if (feedbackContext.mounted) {
      showAppSnackBar(
        feedbackContext,
        i18n.tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    }
    return false;
  }
}

Future<void> openAsmrWorkReviewEditor(
  BuildContext context,
  WidgetRef ref,
  AsmrWork work,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final controller = container.read(asmrLibraryControllerProvider);
  final i18n = container.read(appLanguageProviderInstanceProvider);
  final current = readAsmrWorkReviewDraft(controller, work);
  final syncsWithCloud =
      (controller?.isAsmrAccountLoggedIn ?? false) &&
      work.resourceFor(AsmrCatalogSource.asmrOne) != null;
  final draft = await showWorkReviewEditPanel(
    context: context,
    workTitle: work.title,
    rjCode: work.rjCode.isNotEmpty ? work.rjCode : work.workCode,
    initialStatus: current.listenStatus,
    initialUserRating: current.userRating,
    initialReviewText: current.reviewText,
    syncsWithCloud: syncsWithCloud,
    translate: i18n.tr,
  );
  if (draft == null || !context.mounted) return;
  await saveAsmrWorkReviewWithFeedback(context, ref, work, draft);
}
