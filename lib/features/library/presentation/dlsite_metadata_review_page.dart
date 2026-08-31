import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/top_page_header.dart';

enum DlsiteMetadataReviewOutcome { applied, confirmed, skipped }

class DlsiteMetadataReviewResult {
  const DlsiteMetadataReviewResult.applied(this.detail, this.saveCover)
    : outcome = DlsiteMetadataReviewOutcome.applied,
      metadata = null;

  const DlsiteMetadataReviewResult.confirmed(this.metadata, this.saveCover)
    : outcome = DlsiteMetadataReviewOutcome.confirmed,
      detail = null;

  const DlsiteMetadataReviewResult.skipped([this.saveCover])
    : outcome = DlsiteMetadataReviewOutcome.skipped,
      detail = null,
      metadata = null;

  final DlsiteMetadataReviewOutcome outcome;
  final AudioDetail? detail;
  final DlsiteMetadata? metadata;
  final bool? saveCover;

  bool get isApplied => outcome == DlsiteMetadataReviewOutcome.applied;
  bool get isConfirmed => outcome == DlsiteMetadataReviewOutcome.confirmed;
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
    this.initialCandidates,
    this.canNavigatePrevious = false,
    this.canNavigateNext = false,
    this.onBatchNavigate,
    this.onCompleted,
  }) : assert(
         initialCandidates != null || rjCode != null || searchTitles.length > 0,
       );

  final AudioDetail detail;
  final String? rjCode;
  final List<String> searchTitles;
  final int? batchIndex;
  final int? batchTotal;
  final bool allowSkip;
  final bool missingOnly;
  final bool initialSaveCover;
  final List<DlsiteMetadata>? initialCandidates;
  final bool canNavigatePrevious;
  final bool canNavigateNext;
  final ValueChanged<int>? onBatchNavigate;
  final ValueChanged<DlsiteMetadataReviewResult>? onCompleted;

  @override
  ConsumerState<DlsiteMetadataReviewPage> createState() =>
      _DlsiteMetadataReviewPageState();
}

class _DlsiteMetadataReviewPageState
    extends ConsumerState<DlsiteMetadataReviewPage> {
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 0;
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
    final initialCandidates = widget.initialCandidates;
    if (initialCandidates != null) {
      _showCandidate(0, initialCandidates);
      return;
    }
    try {
      final candidates = await ref
          .read(uiOperationServiceProvider)
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

    if (widget.onCompleted != null) {
      _finish(DlsiteMetadataReviewResult.confirmed(edited, _saveCover));
      return;
    }

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
      final result = await ref
          .read(uiOperationServiceProvider)
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
      _finish(DlsiteMetadataReviewResult.applied(result.detail, _saveCover));
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
    _finish(DlsiteMetadataReviewResult.skipped(_saveCover));
  }

  void _navigateWork(int offset) {
    if (_saving) return;
    widget.onBatchNavigate?.call(offset);
  }

  void _finish(DlsiteMetadataReviewResult result) {
    final onCompleted = widget.onCompleted;
    if (onCompleted != null) {
      onCompleted(result);
      return;
    }
    Navigator.of(context).pop(result);
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

    final bottomInset = MediaQuery.paddingOf(context).bottom + 78;
    final cs = Theme.of(context).colorScheme;
    final reviewTitle = widget.batchIndex == null || widget.batchTotal == null
        ? i18n.tr('dlsite_review_title')
        : '${i18n.tr('dlsite_review_title')} · ${i18n.tr('batch_metadata_progress', {'current': widget.batchIndex, 'total': widget.batchTotal})}';
    final targetName = PathDisplay.fileName(widget.detail.target.targetPath);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final h = box.size.height;
        if (h > 0 && (_headerHeight == 0 || (h - _headerHeight).abs() > 0.5)) {
          setState(() => _headerHeight = h);
        }
      }
    });

    final defaultHeaderHeight = MediaQuery.paddingOf(context).top + 110.0;
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : defaultHeaderHeight;
    final listTopPadding = effectiveHeaderHeight + 8;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Stack(
        children: [
          Positioned.fill(
            child: _loading
                ? SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      listTopPadding,
                      20,
                      bottomInset,
                    ),
                    child: const OperationSkeletonList(itemCount: 7),
                  )
                : _error != null
                ? Padding(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      listTopPadding,
                      20,
                      bottomInset,
                    ),
                    child: _DlsiteErrorView(
                      onRetry: _fetch,
                      onSkip: widget.allowSkip ? _skip : null,
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      listTopPadding,
                      20,
                      bottomInset,
                    ),
                    children: [
                      if (coverUrl != null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: AspectRatio(
                            aspectRatio: kStandardCoverAspectRatio,
                            child: RetryingNetworkImage(
                              url: coverUrl,
                              fit: BoxFit.cover,
                              cacheWidth: coverCacheWidth,
                              useDefaultCacheWidth: coverCacheWidth != null,
                              loadingBuilder: (_) => CoverLoadingArtwork(
                                placeholder: CoverFallbackArtwork(
                                  seed: coverUrl,
                                ),
                              ),
                              fallbackBuilder: (_) =>
                                  CoverFallbackArtwork(seed: coverUrl),
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
                    ],
                  ),
          ),
          if (_metadata != null && widget.allowSkip)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              child: Row(
                children: [
                  if (widget.onBatchNavigate != null) ...[
                    HeaderFloatingSurface(
                      key: const ValueKey<String>(
                        'dlsite_review_work_navigation',
                      ),
                      height: 46,
                      radius: 23,
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: const ValueKey<String>(
                              'dlsite_review_previous_work',
                            ),
                            visualDensity: VisualDensity.compact,
                            iconSize: 20,
                            onPressed: !widget.canNavigatePrevious || _saving
                                ? null
                                : () => _navigateWork(-1),
                            tooltip: i18n.tr('previous'),
                            icon: const Icon(Icons.chevron_left_rounded),
                          ),
                          IconButton(
                            key: const ValueKey<String>(
                              'dlsite_review_next_work',
                            ),
                            visualDensity: VisualDensity.compact,
                            iconSize: 20,
                            onPressed: !widget.canNavigateNext || _saving
                                ? null
                                : () => _navigateWork(1),
                            tooltip: i18n.tr('next'),
                            icon: const Icon(Icons.chevron_right_rounded),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: HeaderFloatingSurface(
                      key: const ValueKey<String>('dlsite_review_skip'),
                      height: 46,
                      radius: 23,
                      padding: EdgeInsets.zero,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(23),
                          onTap: _saving ? null : _skip,
                          child: Center(
                            child: Text(
                              i18n.tr('skip'),
                              style: TextStyle(
                                color: cs.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ReviewConfirmButton(saving: _saving, onTap: _apply),
                  ),
                ],
              ),
            ),
          if (_metadata != null && !widget.allowSkip)
            Positioned(
              right: 16,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              child: SizedBox(
                width: 112,
                child: _ReviewConfirmButton(saving: _saving, onTap: _apply),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: KeyedSubtree(
              key: const ValueKey<String>('dlsite_review_header'),
              child: TopPageHeader(
                key: _headerKey,
                icon: Icons.rate_review_rounded,
                leading: const BackButton(),
                title: reviewTitle,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_candidates.length > 1 && !_loading)
                      HeaderActionPill(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            iconSize: 20,
                            onPressed: _candidateIndex <= 0 || _saving
                                ? null
                                : () => _showCandidate(_candidateIndex - 1),
                            tooltip: i18n.tr('previous'),
                            icon: const Icon(Icons.chevron_left_rounded),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              '${_candidateIndex + 1}/${_candidates.length}',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            iconSize: 20,
                            onPressed:
                                _candidateIndex >= _candidates.length - 1 ||
                                    _saving
                                ? null
                                : () => _showCandidate(_candidateIndex + 1),
                            tooltip: i18n.tr('next'),
                            icon: const Icon(Icons.chevron_right_rounded),
                          ),
                        ],
                      ),
                  ],
                ),
                additionalChild: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: HeaderFloatingSurface(
                    key: const ValueKey<String>('dlsite_review_target_name'),
                    height: null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    child: Text(
                      targetName,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewConfirmButton extends StatelessWidget {
  const _ReviewConfirmButton({required this.saving, required this.onTap});

  final bool saving;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return HeaderFloatingSurface(
      key: const ValueKey<String>('dlsite_review_confirm'),
      height: 46,
      radius: 23,
      padding: EdgeInsets.zero,
      child: Material(
        color: cs.primary,
        borderRadius: BorderRadius.circular(23),
        child: InkWell(
          borderRadius: BorderRadius.circular(23),
          onTap: saving ? null : onTap,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (saving)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.onPrimary,
                    ),
                  )
                else
                  Icon(Icons.check_rounded, size: 18, color: cs.onPrimary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    i18n.tr('confirm'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
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
