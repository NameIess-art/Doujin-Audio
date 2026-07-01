import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../services/audio_state_services.dart';
import '../services/ui_operation_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/async_cover_image.dart';
import '../widgets/operation_feedback.dart';

enum DlsiteMetadataReviewOutcome { applied, skipped }

class DlsiteMetadataReviewResult {
  const DlsiteMetadataReviewResult.applied(this.detail)
    : outcome = DlsiteMetadataReviewOutcome.applied;

  const DlsiteMetadataReviewResult.skipped()
    : outcome = DlsiteMetadataReviewOutcome.skipped,
      detail = null;

  final DlsiteMetadataReviewOutcome outcome;
  final AudioDetail? detail;

  bool get isApplied => outcome == DlsiteMetadataReviewOutcome.applied;
}

class DlsiteMetadataReviewPage extends StatefulWidget {
  const DlsiteMetadataReviewPage({
    super.key,
    required this.detail,
    this.rjCode,
    this.searchTitles = const <String>[],
    this.batchIndex,
    this.batchTotal,
    this.allowSkip = false,
    this.missingOnly = false,
  }) : assert(rjCode != null || searchTitles.length > 0);

  final AudioDetail detail;
  final String? rjCode;
  final List<String> searchTitles;
  final int? batchIndex;
  final int? batchTotal;
  final bool allowSkip;
  final bool missingOnly;

  @override
  State<DlsiteMetadataReviewPage> createState() =>
      _DlsiteMetadataReviewPageState();
}

class _DlsiteMetadataReviewPageState extends State<DlsiteMetadataReviewPage> {
  final _titleController = TextEditingController();
  final _circleController = TextEditingController();
  final _voiceActorsController = TextEditingController();
  final _tagsController = TextEditingController();
  final _releaseDateController = TextEditingController();
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
              final provider = context.read<AudioProvider>();
              final rjCode = widget.rjCode;
              return rjCode != null
                  ? <DlsiteMetadata>[
                      await provider.fetchPreferredMetadata(rjCode),
                    ]
                  : provider.searchPreferredMetadataByTitles(
                      widget.searchTitles,
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
    _salesController.text = metadata.salesCount?.toString() ?? '';
    _ratingController.text = _formatRatingValue(metadata.rating);
    setState(() {
      _candidateIndex = nextIndex;
      _candidates = nextCandidates;
      _metadata = metadata;
      _loading = false;
      _saveCover =
          widget.detail.target.isLibraryRootFolder && metadata.coverUrl != null;
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
      salesCount: _salesController.text.trim().isEmpty
          ? null
          : int.tryParse(_salesController.text.trim()),
      rating: _ratingController.text.trim().isEmpty
          ? null
          : double.tryParse(_ratingController.text.trim()),
    );

    try {
      final result = await UiOperationService.instance
          .run<DlsiteMetadataApplyResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_save_failed',
            task: (_) => context.read<AudioProvider>().applyDlsiteMetadata(
              widget.detail,
              edited,
              saveCover: _saveCover,
              missingOnly: widget.missingOnly,
            ),
          );
      if (!mounted) return;
      if (result.coverFailed) {
        showAppSnackBar(
          context,
          context.read<AppLanguageProvider>().tr('dlsite_cover_save_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
      Navigator.of(
        context,
      ).pop(DlsiteMetadataReviewResult.applied(result.detail));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
      });
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  void _skip() {
    if (_saving) return;
    Navigator.of(context).pop(const DlsiteMetadataReviewResult.skipped());
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final metadata = _metadata;
    final coverUrl = widget.detail.target.isLibraryRootFolder
        ? metadata?.coverUrl
        : null;
    final coverCacheWidth = coverCacheWidthForResolution(
      context.select<AudioProvider, CoverImageResolution>(
        (provider) => provider.coverImageResolution,
      ),
    );

    return Scaffold(
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
                      borderRadius: BorderRadius.circular(14),
                      child: AspectRatio(
                        aspectRatio: 4 / 3,
                        child: RetryingNetworkImage(
                          url: coverUrl,
                          fit: BoxFit.cover,
                          cacheWidth: coverCacheWidth,
                          useDefaultCacheWidth: coverCacheWidth != null,
                          loadingBuilder: (context, child, loadingProgress) =>
                              loadingProgress == null
                              ? child
                              : CoverLoadingArtwork(
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
    final i18n = context.watch<AppLanguageProvider>();
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
