import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/path_display.dart';
import '../domain/asmr_models.dart';
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
    this.selectedHasUnknownSize = false,
    this.customWorkFolderName,
    this.destinationRoot,
    this.allSelected = false,
    this.onToggleSelectAll,
    this.hasActiveTask = false,
    this.onViewTasks,
  });

  final AsmrWork? work;
  final String? initialRjCode;
  final int selectedLeafCount;
  final int selectedTotalSizeBytes;
  final bool selectedHasUnknownSize;
  final String? customWorkFolderName;
  final String? destinationRoot;
  final bool allSelected;
  final VoidCallback? onToggleSelectAll;
  final bool hasActiveTask;
  final VoidCallback? onViewTasks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final primaryColor = Theme.of(context).colorScheme.primary;
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

    final displayPath =
        customWorkFolderName != null && customWorkFolderName!.trim().isNotEmpty
        ? customWorkFolderName!.trim()
        : destinationRoot != null && destinationRoot!.trim().isNotEmpty
        ? PathDisplay.displayPathFor(destinationRoot!.trim())
        : null;

    return HeaderFloatingSurface(
      key: const ValueKey<String>('asmr_download_summary'),
      height: null,
      radius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasActiveTask) ...[
            Container(
              key: const ValueKey<String>('asmr_download_active_notice_banner'),
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.downloading_rounded,
                    size: 16,
                    color: cs.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      i18n.tr('asmr_download_active_notice'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (onViewTasks != null)
                    TextButton(
                      key: const ValueKey<String>(
                        'asmr_download_active_notice_view_tasks',
                      ),
                      onPressed: onViewTasks,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(i18n.tr('asmr_download_view_tasks')),
                    ),
                ],
              ),
            ),
          ],
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
                color: primaryColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  i18n.tr('asmr_download_summary_selected', {
                    'count': selectedLeafCount,
                    'size': selectedHasUnknownSize
                        ? i18n.tr('asmr_download_size_unknown')
                        : formatMediaFileSize(selectedTotalSizeBytes),
                  }),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onToggleSelectAll != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  key: const ValueKey<String>(
                    'asmr_download_toggle_select_all',
                  ),
                  onPressed: onToggleSelectAll,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    i18n.tr(allSelected ? 'deselect_all' : 'select_all'),
                  ),
                ),
              ],
            ],
          ),
          if (currentWork.resources.any(
            (resource) => resource.source == AsmrCatalogSource.japaneseAsmr,
          )) ...[
            const SizedBox(height: 8),
            Text(
              i18n.tr('asmr_download_hls_notice'),
              key: const ValueKey<String>('asmr_download_hls_notice'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          if (displayPath != null) ...[
            const SizedBox(height: 6),
            Row(
              key: const ValueKey<String>('asmr_download_destination_path'),
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    displayPath,
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
