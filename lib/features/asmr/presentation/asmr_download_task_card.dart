import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_entry_ink_well.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../application/asmr_download_models.dart';

import 'asmr_download_format.dart';

class AsmrDownloadTaskCard extends StatelessWidget {
  const AsmrDownloadTaskCard({
    super.key,
    required this.task,
    required this.i18n,
    required this.onOpen,
    required this.onTogglePause,
    required this.onRemove,
    this.progressSection,
  });

  final AsmrDownloadTaskSnapshot task;
  final AppLanguageProvider i18n;
  final VoidCallback onOpen;
  final VoidCallback? onTogglePause;
  final VoidCallback? onRemove;
  final Widget? progressSection;

  static int? highestRetryAttempt(AsmrDownloadTaskSnapshot task) {
    if (!task.isActive) return null;
    return task.fileRetryAttempts.values.fold<int?>(
      null,
      (highest, attempt) =>
          highest == null || attempt > highest ? attempt : highest,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(tokens.radiusCard),
      side: BorderSide(
        color: cs.outlineVariant.withValues(alpha: tokens.standardBorderAlpha),
      ),
    );
    ButtonStyle actionStyle(Color foregroundColor) => appIconButtonStyle(
      IconButton.styleFrom(
        foregroundColor: foregroundColor,
        fixedSize: const Size.square(36),
        minimumSize: const Size.square(36),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
    final card = Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: shape,
      child: AppEntryInkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      task.work.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (task.status != AsmrDownloadTaskStatus.completed)
                    IconButton(
                      style: actionStyle(
                        task.status == AsmrDownloadTaskStatus.failed
                            ? cs.error
                            : cs.onSurfaceVariant,
                      ),
                      icon: Icon(
                        task.status == AsmrDownloadTaskStatus.failed
                            ? Icons.refresh_rounded
                            : task.status == AsmrDownloadTaskStatus.paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                      iconSize: 22,
                      tooltip: task.status == AsmrDownloadTaskStatus.failed
                          ? i18n.tr('retry')
                          : task.status == AsmrDownloadTaskStatus.paused
                          ? i18n.tr('resume')
                          : i18n.tr('pause'),
                      onPressed: onTogglePause,
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: ValueKey<String>(
                      'asmr_download_remove_task_${task.work.workKey}',
                    ),
                    style: actionStyle(cs.error),
                    icon: const Icon(Icons.delete_outline_rounded),
                    iconSize: 22,
                    tooltip: i18n.tr('asmr_download_remove_task'),
                    onPressed: onRemove,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              progressSection ??
                  AsmrDownloadTaskProgressSection(
                    status: task.status,
                    progress: task.progress,
                    downloadedBytes: task.downloadedBytes,
                    totalBytes: task.totalBytes,
                    hasUnknownFileSizes: task.hasUnknownFileSizes,
                    estimatedTotalBytes: task.estimatedTotalBytes,
                    retryAttempt: highestRetryAttempt(task),
                    automaticFileRetryCount: task.automaticFileRetryCount,
                    failedFiles: task.failedFiles,
                    errorMessage: task.error,
                    i18n: i18n,
                  ),
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: defaultTargetPlatform == TargetPlatform.windows
          ? UnifiedContextMenuRegion(
              buildEntries: _buildContextMenuEntries,
              shape: shape,
              child: card,
            )
          : card,
    );
  }

  List<UnifiedMenuEntry<VoidCallback>> _buildContextMenuEntries() {
    final pauseResumeLabel = task.status == AsmrDownloadTaskStatus.failed
        ? i18n.tr('retry')
        : task.status == AsmrDownloadTaskStatus.paused
        ? i18n.tr('resume')
        : i18n.tr('pause');
    final pauseResumeIcon = task.status == AsmrDownloadTaskStatus.failed
        ? Icons.refresh_rounded
        : task.status == AsmrDownloadTaskStatus.paused
        ? Icons.play_arrow_rounded
        : Icons.pause_rounded;

    return [
      UnifiedMenuEntry.action(
        value: onOpen,
        label: i18n.tr('asmr_download_details_title'),
        icon: Icons.info_outline_rounded,
      ),
      if (task.status != AsmrDownloadTaskStatus.completed)
        UnifiedMenuEntry.action(
          value: onTogglePause ?? () {},
          label: pauseResumeLabel,
          icon: pauseResumeIcon,
          enabled: onTogglePause != null,
        ),
      UnifiedMenuEntry.action(
        value: onRemove ?? () {},
        label: i18n.tr('asmr_download_remove_task'),
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: onRemove != null,
      ),
    ];
  }
}

class AsmrDownloadTaskProgressSection extends StatelessWidget {
  const AsmrDownloadTaskProgressSection({
    super.key,
    required this.status,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.hasUnknownFileSizes,
    required this.estimatedTotalBytes,
    required this.retryAttempt,
    required this.automaticFileRetryCount,
    this.failedFiles = 0,
    this.errorMessage,
    required this.i18n,
  });

  final AsmrDownloadTaskStatus status;
  final double? progress;
  final int downloadedBytes;
  final int totalBytes;
  final bool hasUnknownFileSizes;
  final int? estimatedTotalBytes;
  final int? retryAttempt;
  final int automaticFileRetryCount;
  final int failedFiles;
  final String? errorMessage;
  final AppLanguageProvider i18n;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isFailed = status == AsmrDownloadTaskStatus.failed;
    final indicatorColor = isFailed ? cs.error : cs.primary;
    final trimmedError = errorMessage?.trim();
    final failedSummary = isFailed
        ? <String>[
            if (failedFiles > 0)
              i18n.tr('asmr_download_failed_files_count', {
                'count': failedFiles,
              }),
            if (trimmedError != null && trimmedError.isNotEmpty) trimmedError,
          ].join(' · ')
        : '';
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              color: indicatorColor,
              backgroundColor: indicatorColor.withValues(alpha: 0.2),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  retryAttempt == null
                      ? _statusText(i18n, status)
                      : i18n.tr('asmr_download_status_retrying', {
                          'attempt': retryAttempt,
                          'max': automaticFileRetryCount,
                        }),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: isFailed ? cs.error : cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${formatMediaFileSize(downloadedBytes)} / ${formatAsmrDownloadTotalSize(total: totalBytes, unknown: hasUnknownFileSizes, unknownLabel: i18n.tr('asmr_download_size_unknown'), estimate: estimatedTotalBytes)}',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (failedSummary.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              failedSummary,
              key: const ValueKey<String>('asmr_download_task_error_summary'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _statusText(AppLanguageProvider i18n, AsmrDownloadTaskStatus status) {
  switch (status) {
    case AsmrDownloadTaskStatus.preparing:
      return i18n.tr('asmr_download_status_preparing');
    case AsmrDownloadTaskStatus.downloading:
      return i18n.tr('asmr_download_status_downloading');
    case AsmrDownloadTaskStatus.paused:
      return i18n.tr('asmr_download_status_paused');
    case AsmrDownloadTaskStatus.completed:
      return i18n.tr('asmr_download_status_completed');
    case AsmrDownloadTaskStatus.failed:
      return i18n.tr('asmr_download_status_failed');
    case AsmrDownloadTaskStatus.idle:
      return i18n.tr('asmr_download_status_idle');
  }
}
