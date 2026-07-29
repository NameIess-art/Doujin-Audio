import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/operation_feedback.dart';

enum DlsiteMetadataReviewOutcome { applied, skipped }

class DlsiteMetadataReviewResult {
  const DlsiteMetadataReviewResult.applied(this.detail, this.saveCover)
    : outcome = DlsiteMetadataReviewOutcome.applied;

  const DlsiteMetadataReviewResult.skipped([this.saveCover])
    : outcome = DlsiteMetadataReviewOutcome.skipped,
      detail = null;

  final DlsiteMetadataReviewOutcome outcome;
  final AudioDetail? detail;
  final bool? saveCover;

  bool get isApplied => outcome == DlsiteMetadataReviewOutcome.applied;
}

class DlsiteMetadataReviewPage extends ConsumerStatefulWidget {
  const DlsiteMetadataReviewPage({
    super.key,
    required this.detail,
    this.rjCode,
    this.searchTitles = const <String>[],
    this.batchIndex,
    this.batchTotal,
    this.allowSkip = false,
    this.missingOnly = false,
    this.initialSaveCover = true,
  }) : assert(rjCode != null || searchTitles.length > 0);

  final AudioDetail detail;
  final String? rjCode;
  final List<String> searchTitles;
  final int? batchIndex;
  final int? batchTotal;
  final bool allowSkip;
  final bool missingOnly;
  final bool initialSaveCover;

  @override
  ConsumerState<DlsiteMetadataReviewPage> createState() =>
      _DlsiteMetadataReviewPageState();
}

class _DlsiteMetadataReviewPageState
    extends ConsumerState<DlsiteMetadataReviewPage> {
  final _titleController = TextEditingController();
  final _circleController = TextEditingController();
  final _voiceActorsController = TextEditingController();
  final _tagsController = TextEditingController();
  final _releaseDateController = TextEditingController();
  final _durationController = TextEditingController();
  final _salesController = TextEditingController();
  final _ratingController = TextEditingController();

  DlsiteMetadata? _metadata;
  List<DlsiteMetadata> _candidates = const <DlsiteMetadata>[];
  int _candidateIndex = 0;
  Object? _error;
  bool _loading = true;
  bool _saving = false;
  bool _saveCover = true;

  UiOperationScope get _operationScope => UiOperationScope.metadataReview(
    '${widget.detail.target.targetType.dbValue}|${widget.detail.target.targetPath}',
  );

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _circleController.dispose();
    _voiceActorsController.dispose();
    _tagsController.dispose();
    _releaseDateController.dispose();
    _durationController.dispose();
    _salesController.dispose();
    _ratingController.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
      _metadata = null;
      _candidates = const <DlsiteMetadata>[];
      _candidateIndex = 0;
    });
    try {
      final candidates = await UiOperationService.instance
          .run<List<DlsiteMetadata>>(
            scope: _operationScope,
            labelKey: 'dlsite_review_title',
            task: (_) async {
              final library = ref.read(libraryFacadeProvider);
              final language = ref
                  .read(settingsRepositoryProvider)
                  .slice
                  .state
                  .dlsiteMetadataLanguage
                  .resolve(
                    ProviderScope.containerOf(
                      context,
                      listen: false,
                    ).read(appLanguageProviderInstanceProvider).language,
                  );
              final rjCode = widget.rjCode;
              return rjCode != null
                  ? <DlsiteMetadata>[
                      await library.fetchPreferredMetadata(
                        rjCode,
                        language: language,
                      ),
                    ]
                  : library.searchPreferredMetadataByTitles(
                      widget.searchTitles,
                      language: language,
                    );
            },
          );
      if (!mounted) return;
      _showCandidate(0, candidates);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _showCandidate(int index, [List<DlsiteMetadata>? candidates]) {
    final nextCandidates = candidates ?? _candidates;
    if (nextCandidates.isEmpty) return;
    final nextIndex = index.clamp(0, nextCandidates.length - 1).toInt();
    final metadata = nextCandidates[nextIndex];
    _titleController.text = metadata.workTitle;
    _circleController.text = metadata.circleName;
    _voiceActorsController.text = metadata.voiceActors.join('\uFF0C');
    _tagsController.text = metadata.tags.join('\uFF0C');
    _releaseDateController.text = _formatDateValue(metadata.releaseDate);
    _durationController.text = metadata.duration == null
        ? ''
        : formatDurationHms(metadata.duration!);
    _salesController.text = metadata.salesCount?.toString() ?? '';
    _ratingController.text = _formatRatingValue(metadata.rating);
    setState(() {
      _candidateIndex = nextIndex;
      _candidates = nextCandidates;
      _metadata = metadata;
      _loading = false;
      _saveCover =
          widget.initialSaveCover &&
          widget.detail.target.isLibraryRootFolder &&
          metadata.coverUrl != null;
    });
  }

  Future<void> _apply() async {
    final metadata = _metadata;
    if (metadata == null || _saving) return;
    setState(() {
      _saving = true;
    });
    final edited = metadata.copyWith(
      workTitle: _titleController.text.trim(),
      circleName: _circleController.text.trim(),
      voiceActors: AudioDetail.normalizeList(
        _voiceActorsController.text.split('\uFF0C'),
      ),
      tags: AudioDetail.normalizeList(_tagsController.text.split('\uFF0C')),
      releaseDate: _parseDateValue(_releaseDateController.text.trim()),
      duration: _parseDurationValue(_durationController.text.trim()),
      salesCount: _salesController.text.trim().isEmpty
          ? null
          : int.tryParse(_salesController.text.trim()),
      rating: _ratingController.text.trim().isEmpty
          ? null
          : double.tryParse(_ratingController.text.trim()),
    );

    try {
      final language = ref
          .read(settingsRepositoryProvider)
          .slice
          .state
          .dlsiteMetadataLanguage
          .resolve(
            ProviderScope.containerOf(
              context,
              listen: false,
            ).read(appLanguageProviderInstanceProvider).language,
          );
      final result = await UiOperationService.instance
          .run<DlsiteMetadataApplyResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_save_failed',
            task: (_) => ref
                .read(libraryFacadeProvider)
                .applyDlsiteMetadata(
                  widget.detail,
                  edited,
                  saveCover: _saveCover,
                  language: language,
                  missingOnly: widget.missingOnly,
                ),
          );
      if (!mounted) return;
      if (result.coverFailed) {
        showAppSnackBar(
          context,
          ProviderScope.containerOf(context, listen: false)
              .read(appLanguageProviderInstanceProvider)
              .tr('dlsite_cover_save_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
      Navigator.of(
        context,
      ).pop(DlsiteMetadataReviewResult.applied(result.detail, _saveCover));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
      });
      showAppSnackBar(
        context,
        ProviderScope.containerOf(context, listen: false)
            .read(appLanguageProviderInstanceProvider)
            .tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  void _skip() {
    if (_saving) return;
    Navigator.of(context).pop(DlsiteMetadataReviewResult.skipped(_saveCover));
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final metadata = _metadata;
    final coverUrl = widget.detail.target.isLibraryRootFolder
        ? metadata?.coverUrl
        : null;
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(coverImageResolutionProvider),
    );

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Text(
          widget.batchIndex == null || widget.batchTotal == null
              ? i18n.tr('dlsite_review_title')
              : '${i18n.tr('dlsite_review_title')} · ${i18n.tr('batch_metadata_progress', {'current': widget.batchIndex, 'total': widget.batchTotal})}',
        ),
        actions: [
          if (widget.allowSkip)
            TextButton(
              onPressed: _saving ? null : _skip,
              child: Text(i18n.tr('skip')),
            ),
          if (_candidates.length > 1 && !_loading)
            IconButton(
              onPressed: _candidateIndex <= 0 || _saving
                  ? null
                  : () => _showCandidate(_candidateIndex - 1),
              tooltip: i18n.tr('previous'),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
          if (_candidates.length > 1 && !_loading)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text('${_candidateIndex + 1}/${_candidates.length}'),
              ),
            ),
          if (_candidates.length > 1 && !_loading)
            IconButton(
              onPressed: _candidateIndex >= _candidates.length - 1 || _saving
                  ? null
                  : () => _showCandidate(_candidateIndex + 1),
              tooltip: i18n.tr('next'),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: OperationSkeletonList(itemCount: 7),
              )
            : _error != null
            ? _DlsiteErrorView(
                onRetry: _fetch,
                onSkip: widget.allowSkip ? _skip : null,
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  if (coverUrl != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: AspectRatio(
                        aspectRatio: 4 / 3,
                        child: RetryingNetworkImage(
                          url: coverUrl,
                          fit: BoxFit.cover,
                          cacheWidth: coverCacheWidth,
                          useDefaultCacheWidth: coverCacheWidth != null,
                          loadingBuilder: (_) => CoverLoadingArtwork(
                            placeholder: CoverFallbackArtwork(
                              seed: coverUrl,
                              showIcon: false,
                            ),
                          ),
                          fallbackBuilder: (_) => CoverFallbackArtwork(
                            seed: coverUrl,
                            icon: Icons.image_not_supported_rounded,
                            iconSize: 48,
                          ),
                        ),
                      ),
                    ),
                    SwitchListTile(
                      value: _saveCover,
                      onChanged: (value) => setState(() {
                        _saveCover = value;
                      }),
                      contentPadding: EdgeInsets.zero,
                      title: Text(i18n.tr('dlsite_save_cover')),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _ReviewTextField(
                    controller: _titleController,
                    label: i18n.tr('audio_detail_work_title'),
                  ),
                  if ((metadata?.rjCode.trim().isNotEmpty ?? false)) ...[
                    _ReviewInfoLine(
                      label: i18n.tr('audio_detail_rj_code'),
                      value: metadata!.rjCode.trim(),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _ReviewTextField(
                    controller: _circleController,
                    label: i18n.tr('audio_detail_circle_name'),
                  ),
                  _ReviewTextField(
                    controller: _voiceActorsController,
                    label: i18n.tr('audio_detail_voice_actors'),
                    hint: i18n.tr('audio_detail_multi_hint'),
                  ),
                  _ReviewTextField(
                    controller: _tagsController,
                    label: i18n.tr('audio_detail_tags'),
                    hint: i18n.tr('audio_detail_multi_hint'),
                  ),
                  _ReviewTextField(
                    controller: _releaseDateController,
                    label: i18n.tr('audio_detail_release_date'),
                    hint: 'YYYY-MM-DD',
                  ),
                  _ReviewTextField(
                    controller: _durationController,
                    label: i18n.tr('card_info_duration'),
                    hint: 'HH:MM:SS',
                  ),
                  _ReviewTextField(
                    controller: _salesController,
                    label: i18n.tr('audio_detail_sales_count'),
                  ),
                  _ReviewTextField(
                    controller: _ratingController,
                    label: i18n.tr('audio_detail_rating'),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _saving ? null : _apply,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(i18n.tr('confirm')),
                  ),
                ],
              ),
      ),
    );
  }
}

String _formatDateValue(DateTime? value) {
  if (value == null) return '';
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

DateTime? _parseDateValue(String value) {
  if (value.isEmpty) return null;
  final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(value);
  if (match == null) return DateTime.tryParse(value);
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  return DateTime(year, month, day);
}

Duration? _parseDurationValue(String value) {
  if (value.isEmpty) return null;
  final parts = value.split(':').map(int.tryParse).toList(growable: false);
  if (parts.length < 2 ||
      parts.length > 3 ||
      parts.any((part) => part == null)) {
    return null;
  }
  final values = parts.cast<int>();
  if (values.any((part) => part < 0) ||
      values.skip(1).any((part) => part >= 60)) {
    return null;
  }
  final seconds = values.length == 3
      ? values[0] * 3600 + values[1] * 60 + values[2]
      : values[0] * 60 + values[1];
  return seconds > 0 ? Duration(seconds: seconds) : null;
}

String _formatRatingValue(double? value) {
  if (value == null || value <= 0) return '';
  return value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 1);
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

class _DlsiteErrorView extends StatelessWidget {
  const _DlsiteErrorView({required this.onRetry, this.onSkip});

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
