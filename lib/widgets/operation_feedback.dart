import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';
import 'shimmer_loading.dart';

class OperationStatusBanner extends StatelessWidget {
  const OperationStatusBanner({
    super.key,
    required this.label,
    this.progress,
    this.error,
    this.icon = Icons.hourglass_empty_rounded,
    this.onRetry,
  });

  final String label;
  final double? progress;
  final Object? error;
  final IconData icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final hasError = error != null;
    final color = hasError ? cs.error : cs.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(tokens.radiusControl),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(hasError ? Icons.error_outline_rounded : icon, color: color),
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
              tooltip: MaterialLocalizations.of(
                context,
              ).refreshIndicatorSemanticLabel,
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ],
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
