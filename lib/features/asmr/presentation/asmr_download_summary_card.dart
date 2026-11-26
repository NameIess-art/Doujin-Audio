import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/path_display.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/shimmer_loading.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/asmr_download_selection.dart';
import '../domain/asmr_models.dart';

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
    this.fileGroups = const {},
    this.onToggleFileGroup,
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
  final Map<AsmrDownloadFileGroup, bool?> fileGroups;
  final ValueChanged<AsmrDownloadFileGroup>? onToggleFileGroup;
  final bool hasActiveTask;
  final VoidCallback? onViewTasks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final toggleFileGroup = onToggleFileGroup;
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
                color: cs.primary,
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
            ],
          ),
          if (fileGroups.isNotEmpty) ...[
            const SizedBox(height: 4),
            appNoPointerInkTheme(
              context: context,
              androidPressHighlight: true,
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final group in AsmrDownloadFileGroup.values)
                    FilterChip(
                      key: ValueKey('asmr_download_file_group_${group.name}'),
                      shape: const StadiumBorder(),
                      label: Text(switch (group) {
                        AsmrDownloadFileGroup.all => i18n.tr('select_all'),
                        AsmrDownloadFileGroup.image => i18n.tr(
                          'asmr_download_file_group_image',
                        ),
                        _ => group.name,
                      }),
                      labelStyle: theme.chipTheme.labelStyle?.copyWith(
                        fontSize: theme.textTheme.labelSmall?.fontSize,
                      ),
                      color: appChipColor(
                        colorScheme: cs,
                        platform: theme.platform,
                        background: cs.surface,
                        selectedBackground: cs.secondaryContainer,
                      ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      padding: EdgeInsets.zero,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                      showCheckmark: false,
                      selected: fileGroups[group] == true,
                      onSelected:
                          fileGroups[group] == null || toggleFileGroup == null
                          ? null
                          : (_) => toggleFileGroup(group),
                    ),
                ],
              ),
            ),
          ],
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
