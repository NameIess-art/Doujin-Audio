import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../../app/localization/app_language_provider.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_dialog.dart';
import '../application/video_conversion_runner.dart';

Future<void> showVideoConversionResultDialog(
  BuildContext context, {
  required VideoConversionResult result,
  required AppLanguageProvider i18n,
  String? videoPath,
}) {
  final isSuccess = result.status == VideoConversionStatus.success;
  final outputPath = result.outputPath;

  return showAppDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final cs = theme.colorScheme;
      final resolvedAccentColor = isSuccess ? cs.primary : cs.error;

      return AppDialog(
        title: i18n.tr(
          isSuccess
              ? 'video_conversion_completed'
              : 'video_conversion_failed_title',
        ),
        icon: isSuccess
            ? Icons.check_circle_outline_rounded
            : Icons.error_outline_rounded,
        accentColor: resolvedAccentColor,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isSuccess) ...[
              if (videoPath != null && videoPath.isNotEmpty) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.movie_outlined,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        path.basename(videoPath),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: AppRadius.borderMedium,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.audio_file_rounded,
                          size: 16,
                          color: cs.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            outputPath != null ? path.basename(outputPath) : '',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (outputPath != null) ...[
                      const SizedBox(height: 6),
                      SelectableText(
                        outputPath,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ] else ...[
              Text(
                result.errorMessage?.isNotEmpty == true
                    ? result.errorMessage!
                    : i18n.tr('conversion_failed'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        actions: FilledButton(
          onPressed: () => Navigator.of(dialogContext).maybePop(),
          child: Text(i18n.tr('done')),
        ),
      );
    },
  );
}
