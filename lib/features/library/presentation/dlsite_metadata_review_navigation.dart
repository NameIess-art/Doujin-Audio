import 'package:flutter/material.dart';

import '../../../core/widgets/shimmer_loading.dart';
import '../../../core/widgets/top_page_header.dart';

class ReviewWorkNavigation extends StatelessWidget {
  const ReviewWorkNavigation({
    super.key,
    required this.skeleton,
    required this.batchIndex,
    required this.batchTotal,
    required this.canNavigatePrevious,
    required this.canNavigateNext,
    required this.saving,
    required this.previousLabel,
    required this.nextLabel,
    required this.onNavigatePrevious,
    required this.onNavigateNext,
  });

  final bool skeleton;
  final int? batchIndex;
  final int? batchTotal;
  final bool canNavigatePrevious;
  final bool canNavigateNext;
  final bool saving;
  final String previousLabel;
  final String nextLabel;
  final VoidCallback onNavigatePrevious;
  final VoidCallback onNavigateNext;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
      fontWeight: FontWeight.w700,
    );
    final hasProgress = batchIndex != null && batchTotal != null;

    Widget iconPlaceholder() =>
        const ShimmerContainer(width: 20, height: 20, borderRadius: 10);

    Widget navigationButton({
      required Key key,
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
    }) {
      return IconButton(
        key: key,
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        onPressed: skeleton ? null : onPressed,
        tooltip: tooltip,
        icon: skeleton ? iconPlaceholder() : Icon(icon),
      );
    }

    return HeaderFloatingSurface(
      key: ValueKey<String>(
        skeleton
            ? 'dlsite_review_skeleton_work_navigation'
            : 'dlsite_review_work_navigation',
      ),
      height: 46,
      radius: 23,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ShimmerLoader(
        enabled: skeleton,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            navigationButton(
              key: ValueKey<String>(
                skeleton
                    ? 'dlsite_review_skeleton_previous_work'
                    : 'dlsite_review_previous_work',
              ),
              icon: Icons.chevron_left_rounded,
              tooltip: previousLabel,
              onPressed: !canNavigatePrevious || saving
                  ? null
                  : onNavigatePrevious,
            ),
            if (hasProgress)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: skeleton
                    ? Stack(
                        children: [
                          Opacity(
                            opacity: 0,
                            child: Text(
                              '$batchIndex/$batchTotal',
                              style: labelStyle,
                            ),
                          ),
                          const Positioned.fill(
                            child: ShimmerContainer(
                              height: 14,
                              borderRadius: 4,
                            ),
                          ),
                        ],
                      )
                    : Text('$batchIndex/$batchTotal', style: labelStyle),
              ),
            navigationButton(
              key: ValueKey<String>(
                skeleton
                    ? 'dlsite_review_skeleton_next_work'
                    : 'dlsite_review_next_work',
              ),
              icon: Icons.chevron_right_rounded,
              tooltip: nextLabel,
              onPressed: !canNavigateNext || saving ? null : onNavigateNext,
            ),
          ],
        ),
      ),
    );
  }
}

class ReviewConfirmButton extends StatelessWidget {
  const ReviewConfirmButton({
    super.key,
    required this.saving,
    required this.onTap,
    required this.label,
  });

  final bool saving;
  final VoidCallback? onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(
      color: cs.onPrimary,
      fontWeight: FontWeight.w700,
    );

    return HeaderFloatingSurface(
      key: const ValueKey<String>('dlsite_review_confirm'),
      height: 46,
      radius: 23,
      padding: EdgeInsets.zero,
      child: Material(
        color: cs.primary,
        borderRadius: BorderRadius.circular(23),
        child: InkWell(
          borderRadius: BorderRadius.circular(23),
          onTap: saving ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (saving)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.onPrimary,
                    ),
                  )
                else
                  Icon(
                    key: const ValueKey<String>('dlsite_review_confirm_icon'),
                    Icons.check_rounded,
                    size: 18,
                    color: cs.onPrimary,
                  ),
                const SizedBox(width: 6),
                Text(label, style: labelStyle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
