import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/dlsite_metadata.dart';

class DlsiteMetadataReviewForm extends StatelessWidget {
  const DlsiteMetadataReviewForm({
    super.key,
    required this.editing,
    required this.metadata,
    required this.folderNameController,
    required this.rjCodeController,
    required this.titleController,
    required this.circleController,
    required this.voiceActorsController,
    required this.tagsController,
    required this.releaseDateController,
    required this.durationController,
    required this.ratingController,
  });
  final bool editing;
  final DlsiteMetadata? metadata;
  final TextEditingController folderNameController;
  final TextEditingController rjCodeController;
  final TextEditingController titleController;
  final TextEditingController circleController;
  final TextEditingController voiceActorsController;
  final TextEditingController tagsController;
  final TextEditingController releaseDateController;
  final TextEditingController durationController;
  final TextEditingController ratingController;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (editing)
          _ReviewTextField(
            key: const ValueKey<String>(
              'metadata_edit_audio_detail_folder_name',
            ),
            controller: folderNameController,
            label: i18n.tr('audio_detail_folder_name'),
          ),
        _ReviewTextField(
          key: editing
              ? const ValueKey<String>('metadata_edit_audio_detail_work_title')
              : null,
          controller: titleController,
          label: i18n.tr('audio_detail_work_title'),
        ),
        if (editing)
          _ReviewTextField(
            key: const ValueKey<String>('metadata_edit_audio_detail_rj_code'),
            controller: rjCodeController,
            label: i18n.tr('audio_detail_rj_code'),
          )
        else if ((metadata?.rjCode.trim().isNotEmpty ?? false)) ...[
          _ReviewInfoLine(
            label: i18n.tr('audio_detail_rj_code'),
            value: metadata!.rjCode.trim(),
          ),
          const SizedBox(height: 12),
        ],
        _ReviewTextField(
          key: editing
              ? const ValueKey<String>('metadata_edit_audio_detail_circle_name')
              : null,
          controller: circleController,
          label: i18n.tr('audio_detail_circle_name'),
        ),
        _ReviewTextField(
          key: editing
              ? const ValueKey<String>(
                  'metadata_edit_audio_detail_voice_actors',
                )
              : null,
          controller: voiceActorsController,
          label: i18n.tr('audio_detail_voice_actors'),
          hint: i18n.tr('audio_detail_multi_hint'),
        ),
        _ReviewTextField(
          key: editing
              ? const ValueKey<String>('metadata_edit_audio_detail_tags')
              : null,
          controller: tagsController,
          label: i18n.tr('audio_detail_tags'),
          hint: i18n.tr('audio_detail_multi_hint'),
        ),
        _ReviewTextField(
          key: editing
              ? const ValueKey<String>(
                  'metadata_edit_audio_detail_release_date',
                )
              : null,
          controller: releaseDateController,
          label: i18n.tr('audio_detail_release_date'),
          hint: 'YYYY-MM-DD',
        ),
        _ReviewTextField(
          key: editing
              ? const ValueKey<String>('metadata_edit_card_info_duration')
              : null,
          controller: durationController,
          label: i18n.tr('card_info_duration'),
          hint: 'HH:MM:SS',
        ),
        _ReviewTextField(
          key: editing
              ? const ValueKey<String>('metadata_edit_audio_detail_rating')
              : null,
          controller: ratingController,
          label: i18n.tr('audio_detail_rating'),
        ),
      ],
    );
  }
}

class _ReviewInfoLine extends StatelessWidget {
  const _ReviewInfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.confirmation_number_rounded,
            size: 18,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewTextField extends StatelessWidget {
  const _ReviewTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 3,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
