import 'package:flutter/material.dart';

import 'app_feedback.dart';
import 'app_transitions.dart';
import 'app_buttons.dart';
import '../theme/app_styles.dart';

Future<bool> showConfirmActionDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String cancelLabel,
  required String confirmLabel,
  IconData? icon,
  IconData? confirmIcon,
  Color? confirmColor,
  Color? confirmForegroundColor,
  bool isDestructive = true,
}) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kSecondaryOverlayConfig.transitionDuration,
    pageBuilder: (ctx, animation, secondaryAnimation) {
      final theme = Theme.of(ctx);
      final cs = theme.colorScheme;
      final resolvedConfirmColor =
          confirmColor ?? (isDestructive ? cs.error : cs.primary);

      return Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: animation,
            builder: (context, child) {
              return ColoredBox(
                color: kSecondaryOverlayConfig.scrimColor(
                  context,
                  animation.value,
                ),
              );
            },
          ),
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: AppSpacing.xl,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLow.withValues(alpha: 0.94),
                        borderRadius: AppRadius.borderDialog,
                        border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.22),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: cs.shadow.withValues(alpha: 0.24),
                            blurRadius: 38,
                            offset: const Offset(0, 22),
                          ),
                          BoxShadow(
                            color: cs.shadow.withValues(alpha: 0.08),
                            blurRadius: 14,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: resolvedConfirmColor.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius: AppRadius.borderMedium,
                                  ),
                                  child: Icon(
                                    icon ??
                                        (isDestructive
                                            ? Icons.warning_amber_rounded
                                            : Icons.info_outline_rounded),
                                    color: resolvedConfirmColor,
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.md),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                      const SizedBox(height: AppSpacing.xxs),
                                      Text(
                                        message,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: cs.onSurfaceVariant,
                                              height: 1.25,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final stackVertically =
                                    constraints.maxWidth < 260;

                                final cancelButton = AppSecondaryButton(
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                  label: cancelLabel,
                                );

                                final confirmButton = AppPrimaryButton(
                                  onPressed: () {
                                    AppInteractionFeedback.trigger(
                                      isDestructive
                                          ? AppInteractionFeedbackType
                                                .destructive
                                          : AppInteractionFeedbackType
                                                .confirmation,
                                    );
                                    Navigator.of(ctx).pop(true);
                                  },
                                  label: confirmLabel,
                                  isDestructive: isDestructive,
                                  icon: confirmIcon,
                                );

                                if (stackVertically) {
                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: double.infinity,
                                        child: cancelButton,
                                      ),
                                      const SizedBox(height: AppSpacing.sm),
                                      SizedBox(
                                        width: double.infinity,
                                        child: confirmButton,
                                      ),
                                    ],
                                  );
                                }

                                return Row(
                                  children: [
                                    Expanded(child: cancelButton),
                                    const SizedBox(width: AppSpacing.md),
                                    Expanded(child: confirmButton),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      return FadeTransition(opacity: curved, child: child);
    },
  );

  return result ?? false;
}
