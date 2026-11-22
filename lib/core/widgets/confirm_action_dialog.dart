import 'package:flutter/material.dart';

import 'app_buttons.dart';
import 'app_dialog.dart';
import 'app_feedback.dart';

Future<bool> showConfirmActionDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String cancelLabel,
  required String confirmLabel,
  IconData? icon,
  IconData? confirmIcon,
  Color? confirmColor,
  bool isDestructive = true,
}) async {
  final result = await showAppDialog<bool>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final cs = theme.colorScheme;
      final resolvedConfirmColor =
          confirmColor ?? (isDestructive ? cs.error : cs.primary);

      return AppDialog(
        title: title,
        scrollable: true,
        icon:
            icon ??
            (isDestructive
                ? Icons.warning_amber_rounded
                : Icons.info_outline_rounded),
        accentColor: resolvedConfirmColor,
        content: Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.25,
          ),
        ),
        actions: AppDialogActions(
          children: [
            AppPillButton.outlined(
              autofocus: isDestructive,
              onPressed: () => Navigator.of(ctx).pop(false),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.primary,
                minimumSize: const Size.fromHeight(48),
                side: BorderSide(color: cs.outlineVariant),
                shape: const StadiumBorder(),
                textStyle: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              child: Text(cancelLabel),
            ),
            AppPrimaryButton(
              onPressed: () {
                AppInteractionFeedback.trigger(
                  isDestructive
                      ? AppInteractionFeedbackType.destructive
                      : AppInteractionFeedbackType.confirmation,
                );
                Navigator.of(ctx).pop(true);
              },
              label: confirmLabel,
              isDestructive: isDestructive,
              icon: confirmIcon,
            ),
          ],
        ),
      );
    },
  );

  return result ?? false;
}
