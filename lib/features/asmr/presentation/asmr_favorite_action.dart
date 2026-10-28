import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/widgets/app_feedback.dart';
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
  final accent = AppDesignTokens.of(context).asmrAccent;

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
