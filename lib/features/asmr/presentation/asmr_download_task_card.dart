import 'package:flutter/material.dart';

import '../../../app/localization/app_language_provider.dart';
import '../application/asmr_download_models.dart';
import '../../../app/theme/app_design_tokens.dart';

import 'asmr_download_format.dart';

class AsmrDownloadTaskCard extends StatelessWidget {
  const AsmrDownloadTaskCard({
    super.key,
    required this.task,
    required this.i18n,
    required this.onOpen,
    required this.onTogglePause,
    required this.onRemove,
  });

  final AsmrDownloadTaskSnapshot task;
  final AppLanguageProvider i18n;
  final VoidCallback onOpen;
  final VoidCallback onTogglePause;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final retryAttempt = task.isActive
        ? task.fileRetryAttempts.values.fold<int?>(
            null,
            (highest, attempt) =>
                highest == null || attempt > highest ? attempt : highest,
          )
        : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
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
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (task.status != AsmrDownloadTaskStatus.completed &&
                      task.status != AsmrDownloadTaskStatus.failed)
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          task.status == AsmrDownloadTaskStatus.paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                        ),
                        iconSize: 22,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                        tooltip: task.status == AsmrDownloadTaskStatus.paused
                            ? i18n.tr('resume')
                            : i18n.tr('pause'),
                        onPressed: onTogglePause,
                      ),
                    ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      key: ValueKey<String>(
                        'asmr_download_remove_task_${task.work.id}',
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.delete_outline_rounded),
                      iconSize: 22,
                      color: cs.error.withValues(alpha: 0.8),
                      tooltip: i18n.tr('asmr_download_remove_task'),
                      onPressed: onRemove,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: task.progress,
                  minHeight: 6,
                  color: asmrBlue,
                  backgroundColor: asmrBlue.withValues(alpha: 0.2),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    retryAttempt == null
                        ? _statusText(i18n, task.status)
                        : i18n.tr('asmr_download_status_retrying', {
                            'attempt': retryAttempt,
                            'max': task.automaticFileRetryCount,
                          }),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${formatAsmrDownloadSize(task.downloadedBytes)} / ${formatAsmrDownloadSize(task.totalBytes)}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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
