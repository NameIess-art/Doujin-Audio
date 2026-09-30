import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../domain/asmr_models.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/shimmer_loading.dart';
import '../../../core/widgets/top_page_header.dart';

import 'asmr_download_format.dart';

class AsmrDownloadSummaryCard extends ConsumerWidget {
  const AsmrDownloadSummaryCard({
    super.key,
    this.work,
    this.initialRjCode,
    required this.selectedLeafCount,
    required this.selectedTotalSizeBytes,
    this.customWorkFolderName,
  });

  final AsmrWork? work;
  final String? initialRjCode;
  final int selectedLeafCount;
  final int selectedTotalSizeBytes;
  final String? customWorkFolderName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);

    final currentWork = work;
    if (currentWork == null) {
      return HeaderFloatingSurface(
        key: const ValueKey<String>('asmr_download_summary_skeleton'),
        height: null,
        radius: 16,
        padding: const EdgeInsets.all(16),
        child: ShimmerLoader(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (initialRjCode != null && initialRjCode!.trim().isNotEmpty)
                Text(
                  initialRjCode!.trim(),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                )
              else
                const ShimmerContainer(width: 200, height: 18),
              const SizedBox(height: 10),
              const Row(
                children: [
                  ShimmerContainer(width: 16, height: 16, borderRadius: 8),
                  SizedBox(width: 6),
                  ShimmerContainer(width: 140, height: 12),
                ],
              ),
              if (customWorkFolderName != null &&
                  customWorkFolderName!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        customWorkFolderName!.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }

    return HeaderFloatingSurface(
      key: const ValueKey<String>('asmr_download_summary'),
      height: null,
      radius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            currentWork.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 16,
                color: asmrBlue,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  i18n.tr('asmr_download_summary_selected', {
                    'count': selectedLeafCount,
                    'size': formatAsmrDownloadSize(selectedTotalSizeBytes),
                  }),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (customWorkFolderName != null &&
              customWorkFolderName!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    customWorkFolderName!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
