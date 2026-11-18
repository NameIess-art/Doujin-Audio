import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/theme/app_design_tokens.dart';
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
  });

  final AsmrDownloadTaskSnapshot task;
  final AppLanguageProvider i18n;
  final VoidCallback onOpen;
  final VoidCallback? onTogglePause;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final primaryColor = Theme.of(context).colorScheme.primary;
    final retryAttempt = task.isActive
        ? task.fileRetryAttempts.values.fold<int?>(
            null,
            (highest, attempt) =>
                highest == null || attempt > highest ? attempt : highest,
          )
        : null;

    final card = Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusSection),
        side: BorderSide(
          color: cs.outlineVariant.withValues(
            alpha: tokens.standardBorderAlpha,
          ),
        ),
      ),
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
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          task.status == AsmrDownloadTaskStatus.failed
                              ? Icons.refresh_rounded
                              : task.status == AsmrDownloadTaskStatus.paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                        ),
                        iconSize: 22,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                        tooltip: task.status == AsmrDownloadTaskStatus.failed
                            ? i18n.tr('retry')
                            : task.status == AsmrDownloadTaskStatus.paused
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
                        'asmr_download_remove_task_${task.work.workKey}',
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
                  color: primaryColor,
                  backgroundColor: primaryColor.withValues(alpha: 0.2),
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
                      '${formatMediaFileSize(task.downloadedBytes)} / ${formatAsmrDownloadTotalSize(total: task.totalBytes, unknown: task.hasUnknownFileSizes, unknownLabel: i18n.tr('asmr_download_size_unknown'), estimate: task.estimatedTotalBytes)}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (defaultTargetPlatform == TargetPlatform.windows) {
      void showKeyboardMenu() {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        _showContextMenu(
          context,
          box.localToGlobal(box.size.center(Offset.zero)),
        );
      }

      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f10, shift: true):
              showKeyboardMenu,
          const SingleActivator(LogicalKeyboardKey.contextMenu):
              showKeyboardMenu,
        },
        child: Focus(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onSecondaryTapDown: (details) =>
                _showContextMenu(context, details.globalPosition),
            child: card,
          ),
        ),
      );
    }
    return card;
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
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

    final action = await showUnifiedContextMenu<VoidCallback>(
      context: context,
      globalPosition: globalPosition,
      entries: [
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
      ],
    );
    action?.call();
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
