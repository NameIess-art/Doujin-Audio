import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_feedback.dart';

Future<bool> showConfirmActionDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String cancelLabel,
  required String confirmLabel,
  IconData? icon,
  Color? confirmColor,
}) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, animation, secondaryAnimation) {
      final theme = Theme.of(ctx);
      final cs = theme.colorScheme;
      final resolvedConfirmColor = confirmColor ?? cs.error;

      return SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.8),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: cs.shadow.withValues(alpha: 0.12),
                        blurRadius: 28,
                        offset: const Offset(0, 18),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppFeedbackSurface(
                          tone: AppFeedbackTone.destructive,
                          icon: icon ?? Icons.delete_outline_rounded,
                          title: title,
                          message: message,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                        ),
                        const SizedBox(height: 14),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final stackVertically = constraints.maxWidth < 300;

                            final cancelButton = stackVertically
                                ? SizedBox(
                                    width: double.infinity,
                                    child: _DialogActionButton(
                                      child: OutlinedButton.icon(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(false),
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size.fromHeight(
                                            52,
                                          ),
                                          side: BorderSide(
                                            color: cs.outlineVariant.withValues(
                                              alpha: 0.72,
                                            ),
                                          ),
                                          backgroundColor: cs.surfaceContainer,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                        ),
                                        label: Text(
                                          cancelLabel,
                                          style: theme.textTheme.labelLarge
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                    ),
                                  )
                                : Expanded(
                                    child: _DialogActionButton(
                                      child: OutlinedButton.icon(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(false),
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size.fromHeight(
                                            52,
                                          ),
                                          side: BorderSide(
                                            color: cs.outlineVariant.withValues(
                                              alpha: 0.72,
                                            ),
                                          ),
                                          backgroundColor: cs.surfaceContainer,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                        ),
                                        label: Text(
                                          cancelLabel,
                                          style: theme.textTheme.labelLarge
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                    ),
                                  );

                            final confirmButton = stackVertically
                                ? SizedBox(
                                    width: double.infinity,
                                    child: _DialogActionButton(
                                      child: FilledButton.icon(
                                        onPressed: () {
                                          Feedback.forTap(ctx);
                                          HapticFeedback.mediumImpact();
                                          Navigator.of(ctx).pop(true);
                                        },
                                        style: FilledButton.styleFrom(
                                          backgroundColor: resolvedConfirmColor,
                                          foregroundColor: cs.onError,
                                          minimumSize: const Size.fromHeight(
                                            54,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.delete_sweep_rounded,
                                          size: 18,
                                        ),
                                        label: Text(
                                          confirmLabel,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                color: cs.onError,
                                                fontWeight: FontWeight.w800,
                                              ),
                                        ),
                                      ),
                                    ),
                                  )
                                : Expanded(
                                    child: _DialogActionButton(
                                      child: FilledButton.icon(
                                        onPressed: () {
                                          Feedback.forTap(ctx);
                                          HapticFeedback.mediumImpact();
                                          Navigator.of(ctx).pop(true);
                                        },
                                        style: FilledButton.styleFrom(
                                          backgroundColor: resolvedConfirmColor,
                                          foregroundColor: cs.onError,
                                          minimumSize: const Size.fromHeight(
                                            54,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.delete_sweep_rounded,
                                          size: 18,
                                        ),
                                        label: Text(
                                          confirmLabel,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                color: cs.onError,
                                                fontWeight: FontWeight.w800,
                                              ),
                                        ),
                                      ),
                                    ),
                                  );

                            if (stackVertically) {
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  cancelButton,
                                  const SizedBox(height: 10),
                                  confirmButton,
                                ],
                              );
                            }

                            return Row(
                              children: [
                                cancelButton,
                                const SizedBox(width: 12),
                                confirmButton,
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
      );
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );

  return result ?? false;
}

class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}
