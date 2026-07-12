import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';
import 'shimmer_loading.dart';

enum OperationStatusTone { info, success, warning, error }

class OperationStatusBanner extends StatelessWidget {
  const OperationStatusBanner({
    super.key,
    required this.label,
    this.progress,
    this.error,
    this.icon = Icons.hourglass_empty_rounded,
    this.onRetry,
    this.onCancel,
    this.retryTooltip,
    this.cancelTooltip,
    this.semanticLabel,
    this.tone = OperationStatusTone.info,
  });

  final String label;
  final double? progress;
  final Object? error;
  final IconData icon;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final String? retryTooltip;
  final String? cancelTooltip;
  final String? semanticLabel;
  final OperationStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final resolvedTone = error != null ? OperationStatusTone.error : tone;
    final color = switch (resolvedTone) {
      OperationStatusTone.info => cs.primary,
      OperationStatusTone.success => tokens.success,
      OperationStatusTone.warning => tokens.warning,
      OperationStatusTone.error => cs.error,
    };
    final statusIcon = switch (resolvedTone) {
      OperationStatusTone.success => Icons.check_circle_outline_rounded,
      OperationStatusTone.warning => Icons.warning_amber_rounded,
      OperationStatusTone.error => Icons.error_outline_rounded,
      OperationStatusTone.info => icon,
    };
    final hasError = resolvedTone == OperationStatusTone.error;
    return Semantics(
      liveRegion: true,
      label: semanticLabel ?? label,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spaceSm,
          vertical: tokens.spaceSm,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(tokens.radiusControl),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Row(
          children: [
            Icon(statusIcon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: hasError ? cs.error : cs.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!hasError && progress != null) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: progress),
                  ],
                ],
              ),
            ),
            if (!hasError && progress == null) ...[
              const SizedBox(width: 12),
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              ),
            ],
            if (hasError && onRetry != null) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip:
                    retryTooltip ??
                    MaterialLocalizations.of(
                      context,
                    ).refreshIndicatorSemanticLabel,
                onPressed: onRetry,
                constraints: BoxConstraints.tightFor(
                  width: tokens.minimumTapTarget,
                  height: tokens.minimumTapTarget,
                ),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
            if (!hasError && onCancel != null) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip:
                    cancelTooltip ??
                    MaterialLocalizations.of(context).cancelButtonLabel,
                onPressed: onCancel,
                constraints: BoxConstraints.tightFor(
                  width: tokens.minimumTapTarget,
                  height: tokens.minimumTapTarget,
                ),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class OperationSkeletonList extends StatelessWidget {
  const OperationSkeletonList({
    super.key,
    this.itemCount = 4,
    this.showHeader = true,
    this.padding = EdgeInsets.zero,
  });

  final int itemCount;
  final bool showHeader;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return ShimmerLoader(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showHeader) ...[
              const ShimmerContainer(width: 160, height: 20),
              const SizedBox(height: 12),
              const ShimmerContainer(height: 14, borderRadius: 7),
              const SizedBox(height: 20),
            ],
            for (var index = 0; index < itemCount; index++) ...[
              Container(
                height: 58,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(tokens.radiusControl),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: const Row(
                  children: [
                    ShimmerContainer(width: 34, height: 34, borderRadius: 10),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ShimmerContainer(height: 14, borderRadius: 7),
                          SizedBox(height: 8),
                          ShimmerContainer(
                            width: 140,
                            height: 10,
                            borderRadius: 5,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (index != itemCount - 1) const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.actionIcon = Icons.add_rounded,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData actionIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    return Semantics(
      container: true,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: tokens.compactContentMaxWidth),
          child: Padding(
            padding: EdgeInsets.all(tokens.spaceXl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48, color: cs.onSurfaceVariant),
                SizedBox(height: tokens.spaceMd),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                SizedBox(height: tokens.spaceXs),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  SizedBox(height: tokens.spaceLg),
                  FilledButton.icon(
                    onPressed: onAction,
                    icon: Icon(actionIcon),
                    label: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppErrorState extends StatelessWidget {
  const AppErrorState({
    super.key,
    required this.title,
    required this.message,
    this.retryLabel,
    this.onRetry,
  });

  final String title;
  final String message;
  final String? retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.error_outline_rounded,
      title: title,
      message: message,
      actionLabel: retryLabel,
      onAction: onRetry,
      actionIcon: Icons.refresh_rounded,
    );
  }
}
