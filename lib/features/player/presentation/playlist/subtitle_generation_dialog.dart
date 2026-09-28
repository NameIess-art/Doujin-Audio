import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../../app/state/app_runtime_providers.dart';
import '../../application/playback_subtitle_service.dart';
import '../../application/subtitle_generation.dart';
import '../../application/subtitle_model_store.dart';

class SubtitleGenerationDialog extends ConsumerWidget {
  const SubtitleGenerationDialog({super.key, required this.service});

  final PlaybackSubtitleService service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([service, service.modelStore]),
      builder: (context, _) {
        final job = service.generationJob;
        if (job == null) return const SizedBox.shrink();
        final running = job.status == SubtitleGenerationStatus.running;
        final progress = job.progress;
        final model = service.modelStore.snapshot(
          job.kind == SubtitleDraftKind.script
              ? SubtitleModelStore.japaneseCtc
              : SubtitleModelStore.translation,
        );
        final downloading =
            running && progress?.stage == 'download' && model.active;
        final stageKey = switch (progress?.stage) {
          'download' => 'subtitle_stage_download',
          'decoding' => 'subtitle_stage_decoding',
          'loading' => 'subtitle_stage_loading',
          'matching' => 'subtitle_stage_matching',
          'translating' => 'subtitle_stage_translating',
          'saving' => 'subtitle_stage_saving',
          _ => 'subtitle_generating',
        };
        final resultKey = switch (job.status) {
          SubtitleGenerationStatus.noMatch => 'subtitle_no_reliable_match',
          SubtitleGenerationStatus.cancelled => 'subtitle_task_cancelled',
          SubtitleGenerationStatus.failed => 'subtitle_task_failed',
          _ => 'subtitle_generation_ready',
        };
        return AlertDialog(
          title: Text(
            i18n.tr(
              job.kind == SubtitleDraftKind.script
                  ? 'subtitle_script_generate'
                  : 'subtitle_translate',
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                path.basename(job.trackPath),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 14),
              Text(i18n.tr(running ? stageKey : resultKey)),
              if (job.status == SubtitleGenerationStatus.failed &&
                  job.errorMessage != null) ...[
                const SizedBox(height: 8),
                SelectableText(
                  job.errorMessage!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (running) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  key: const ValueKey('subtitle_generation_progress'),
                  value: downloading
                      ? model.fraction
                      : progress == null ||
                            progress.stage == 'decoding' ||
                            progress.stage == 'loading' ||
                            progress.stage == 'saving'
                      ? null
                      : progress.fraction,
                ),
                const SizedBox(height: 8),
                Text(
                  downloading
                      ? i18n.tr('subtitle_model_download_progress', {
                          'received': (model.received / 1048576)
                              .toStringAsFixed(1),
                          'total': (model.total / 1048576).toStringAsFixed(1),
                        })
                      : progress?.message.isNotEmpty == true
                      ? progress!.message
                      : i18n.tr(stageKey),
                ),
              ],
            ],
          ),
          actions: [
            if (running) ...[
              TextButton(
                onPressed:
                    job.cancellationRequested || progress?.stage == 'saving'
                    ? null
                    : service.cancelGeneration,
                child: Text(i18n.tr('subtitle_pause_task')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(i18n.tr('subtitle_run_in_background')),
              ),
            ] else ...[
              TextButton(
                onPressed: () {
                  service.clearGenerationJob();
                  Navigator.pop(context);
                },
                child: Text(i18n.tr('close')),
              ),
            ],
          ],
        );
      },
    );
  }
}
