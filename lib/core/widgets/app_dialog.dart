import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';
import 'app_transitions.dart';

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  double maxWidth = 420,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.transparent,
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kSecondaryOverlayConfig.transitionDuration,
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
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
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Material(
                    color: Colors.transparent,
                    child: builder(dialogContext),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return buildAppScaleFadeTransition(
        context: context,
        animation: animation,
        child: child,
      );
    },
  );
}

class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    this.icon,
    this.accentColor,
    this.actions,
    this.scrollable = false,
  });

  final String title;
  final Widget content;
  final IconData? icon;
  final Color? accentColor;
  final Widget? actions;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final resolvedAccentColor = accentColor ?? cs.primary;

    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: title,
      child: Container(
        key: const ValueKey('app_dialog_surface'),
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (icon != null) ...[
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: resolvedAccentColor.withValues(alpha: 0.12),
                        borderRadius: AppRadius.borderMedium,
                      ),
                      child: Icon(icon, color: resolvedAccentColor),
                    ),
                    const SizedBox(width: AppSpacing.md),
                  ],
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: icon == null ? 0 : 8),
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Flexible(
                child: scrollable
                    ? SingleChildScrollView(child: content)
                    : content,
              ),
              if (actions != null) ...[
                const SizedBox(height: AppSpacing.lg),
                actions!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AppDialogActions extends StatelessWidget {
  const AppDialogActions({
    super.key,
    required this.children,
    this.forceVertical = false,
  });

  final List<Widget> children;
  final bool forceVertical;

  @override
  Widget build(BuildContext context) {
    assert(children.isNotEmpty);

    return LayoutBuilder(
      builder: (context, constraints) {
        final stackVertically =
            forceVertical || children.length > 2 || constraints.maxWidth < 260;

        if (stackVertically) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                SizedBox(width: double.infinity, child: children[index]),
                if (index != children.length - 1)
                  const SizedBox(height: AppSpacing.sm),
              ],
            ],
          );
        }

        return Row(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              Expanded(child: children[index]),
              if (index != children.length - 1)
                const SizedBox(width: AppSpacing.md),
            ],
          ],
        );
      },
    );
  }
}
