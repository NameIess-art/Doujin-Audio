import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/shimmer_loading.dart';

class MetadataReviewSkeleton extends StatelessWidget {
  const MetadataReviewSkeleton({super.key, required this.showCover});

  final bool showCover;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fieldCount = (MediaQuery.sizeOf(context).height / 68).ceil();
    return ShimmerLoader(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showCover) ...[
            const AspectRatio(
              key: ValueKey<String>('dlsite_review_skeleton_cover'),
              aspectRatio: kStandardCoverAspectRatio,
              child: ShimmerContainer(borderRadius: 16),
            ),
            const SizedBox(
              height: 56,
              child: Row(
                children: [
                  ShimmerContainer(
                    key: ValueKey<String>(
                      'dlsite_review_skeleton_save_cover_label',
                    ),
                    width: 150,
                    height: 14,
                  ),
                  Spacer(),
                  SizedBox(
                    width: 60,
                    height: 40,
                    child: Center(
                      child: ShimmerContainer(
                        key: ValueKey<String>(
                          'dlsite_review_skeleton_save_cover',
                        ),
                        width: 52,
                        height: 32,
                        borderRadius: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (var index = 0; index < fieldCount; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                key: ValueKey<String>('dlsite_review_skeleton_field_$index'),
                height: index == 1 ? 44 : 56,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(index == 1 ? 8 : 4),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: ShimmerContainer(
                  width: index.isEven ? 140 : 180,
                  height: 14,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class DlsiteReviewErrorView extends StatelessWidget {
  const DlsiteReviewErrorView({super.key, required this.onRetry, this.onSkip});

  final VoidCallback onRetry;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 44,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(i18n.tr('dlsite_fetch_failed'), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(i18n.tr('retry')),
            ),
            if (onSkip != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onSkip, child: Text(i18n.tr('skip'))),
            ],
          ],
        ),
      ),
    );
  }
}
