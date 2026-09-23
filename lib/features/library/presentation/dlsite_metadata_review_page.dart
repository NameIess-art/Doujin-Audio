import 'library_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
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
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/audio_detail_repository.dart';
import 'folder_cover_selector.dart';

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
    this.editing = false,
  }) : assert(
         editing ||
             initialCandidates != null ||
             rjCode != null ||
             searchTitles.length > 0,
       );

  const DlsiteMetadataReviewPage.edit({super.key, required this.detail})
    : rjCode = null,
      searchTitles = const <String>[],
      batchIndex = null,
      batchTotal = null,
      allowSkip = false,
      missingOnly = false,
      initialSaveCover = false,
      initialCandidates = null,
      canNavigatePrevious = false,
      canNavigateNext = false,
      onBatchNavigate = null,
      onCompleted = null,
      editing = true;

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
  final bool editing;

  @override
  ConsumerState<DlsiteMetadataReviewPage> createState() =>
      _DlsiteMetadataReviewPageState();
}

class _DlsiteMetadataReviewPageState
    extends ConsumerState<DlsiteMetadataReviewPage> {
  final GlobalKey _headerKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  double _headerHeight = 0;
  final _titleController = TextEditingController();
  final _folderNameController = TextEditingController();
  final _rjCodeController = TextEditingController();
  final _circleController = TextEditingController();
  final _voiceActorsController = TextEditingController();
  final _tagsController = TextEditingController();
  final _releaseDateController = TextEditingController();
  final _durationController = TextEditingController();
  final _ratingController = TextEditingController();

  DlsiteMetadata? _metadata;
  AudioDetail? _editingDetail;
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
    if (widget.editing) {
      _initializeEditor();
    } else if (widget.initialCandidates != null) {
      _initializeWithCandidates(widget.initialCandidates!);
    } else {
      unawaited(_fetch());
    }
  }

  @override
  void didUpdateWidget(DlsiteMetadataReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final workChanged =
        widget.detail.target != oldWidget.detail.target ||
        widget.detail != oldWidget.detail ||
        widget.batchIndex != oldWidget.batchIndex ||
        widget.rjCode != oldWidget.rjCode ||
        widget.initialCandidates != oldWidget.initialCandidates ||
        !listEquals(widget.searchTitles, oldWidget.searchTitles);

    if (workChanged) {
      _saving = false;
      if (widget.editing) {
        _initializeEditor();
      } else if (widget.initialCandidates != null) {
        setState(() {
          _initializeWithCandidates(widget.initialCandidates!);
        });
      } else {
        unawaited(_fetch());
      }
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _titleController.dispose();
    _folderNameController.dispose();
    _rjCodeController.dispose();
    _circleController.dispose();
    _voiceActorsController.dispose();
    _tagsController.dispose();
    _releaseDateController.dispose();
    _durationController.dispose();
    _ratingController.dispose();
    super.dispose();
  }

  void _initializeWithCandidates(List<DlsiteMetadata> candidates) {
    _candidates = candidates;
    _candidateIndex = 0;
    _error = null;
    _editingDetail = null;
    _saving = false;
    if (candidates.isNotEmpty) {
      final metadata = candidates[0];
      _populateFields(metadata);
      _metadata = metadata;
      _loading = false;
      _saveCover =
          widget.initialSaveCover &&
          widget.detail.target.isLibraryRootFolder &&
          metadata.coverUrl != null;
    } else {
      _metadata = null;
      _loading = false;
    }
  }

  void _initializeEditor() {
    final detail = widget.detail;
    final metadata = DlsiteMetadata(
      rjCode: detail.rjCode,
      workTitle: detail.workTitle,
      circleName: detail.circleName,
      voiceActors: detail.voiceActors,
      tags: detail.tags,
      releaseDate: detail.releaseDate,
      duration: detail.duration,
      salesCount: detail.salesCount,
      rating: detail.rating,
    );
    _folderNameController.text = PathDisplay.fileName(detail.target.targetPath);
    _populateFields(metadata);
    _metadata = metadata;
    _editingDetail = detail;
    _candidates = <DlsiteMetadata>[metadata];
    _loading = false;
    _saveCover = false;
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
    _populateFields(metadata);
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

  void _populateFields(DlsiteMetadata metadata) {
    _rjCodeController.text = metadata.rjCode;
    _titleController.text = metadata.workTitle;
    _circleController.text = metadata.circleName;
    _voiceActorsController.text = metadata.voiceActors.join('\uFF0C');
    _tagsController.text = metadata.tags.join('\uFF0C');
    _releaseDateController.text = metadata.releaseDate == null
        ? ''
        : formatDateYmd(metadata.releaseDate!);
    _durationController.text = metadata.duration == null
        ? ''
        : formatDurationHms(metadata.duration!);
    _ratingController.text = formatLibraryLikeRating(metadata.rating);
  }

  Future<void> _apply() async {
    final metadata = _metadata;
    if (metadata == null || _saving) return;
    setState(() {
      _saving = true;
    });
    final edited = metadata.copyWith(
      rjCode: widget.editing
          ? _rjCodeController.text.trim().toUpperCase()
          : metadata.rjCode,
      workTitle: _titleController.text.trim(),
      circleName: _circleController.text.trim(),
      voiceActors: AudioDetail.normalizeList(
        _voiceActorsController.text.split(RegExp(r'[,，]')),
      ),
      tags: AudioDetail.normalizeList(
        _tagsController.text.split(RegExp(r'[,，]')),
      ),
      releaseDate: parseDateYmd(_releaseDateController.text.trim()),
      duration: parseDurationCompact(_durationController.text.trim()),
      rating: _ratingController.text.trim().isEmpty
          ? null
          : double.tryParse(_ratingController.text.trim()),
    );

    if (widget.editing) {
      await _saveEdits(edited);
      return;
    }

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

  Future<void> _saveEdits(DlsiteMetadata edited) async {
    try {
      var detail = _editingDetail ?? widget.detail;
      var backupFailed = false;
      final folderName = _folderNameController.text.trim();
      if (folderName.isEmpty) {
        throw const FormatException('Folder name cannot be empty.');
      }
      if (folderName != PathDisplay.fileName(detail.target.targetPath)) {
        final renameResult = await ref
            .read(audioPathCoordinatorProvider)
            .renameAudioDetailTargetToName(detail, folderName);
        detail = renameResult.detail;
        _editingDetail = detail;
        backupFailed = renameResult.backupFailed;
      }
      final saveResult = await ref
          .read(uiOperationServiceProvider)
          .run<AudioDetailSaveResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_save_failed',
            task: (_) => ref
                .read(libraryFacadeProvider)
                .saveAudioDetail(
                  detail.copyWith(
                    rjCode: edited.rjCode,
                    workTitle: edited.workTitle,
                    circleName: edited.circleName,
                    voiceActors: edited.voiceActors,
                    tags: edited.tags,
                    releaseDate: edited.releaseDate,
                    duration: edited.duration,
                    rating: edited.rating,
                  ),
                ),
          );
      if (!mounted) return;
      if (backupFailed || saveResult.documentFailed) {
        showAppSnackBar(
          context,
          ProviderScope.containerOf(context, listen: false)
              .read(appLanguageProviderInstanceProvider)
              .tr('audio_detail_backup_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
      _finish(DlsiteMetadataReviewResult.applied(saveResult.detail, false));
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppSnackBar(
        context,
        ProviderScope.containerOf(context, listen: false)
            .read(appLanguageProviderInstanceProvider)
            .tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  void _handleCoverSelected(String coverPath) {
    final detail = _editingDetail ?? widget.detail;
    setState(() {
      _editingDetail = detail.copyWith(
        cardCoverPath: coverPath,
        cardCoverSelected: true,
      );
    });
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
    final editingDetail = _editingDetail ?? widget.detail;
    final library = ref.read(libraryFacadeProvider);
    final coverUrl = !widget.editing && widget.detail.target.isLibraryRootFolder
        ? metadata?.coverUrl
        : null;
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(coverImageResolutionProvider),
    );

    final bottomInset = MediaQuery.paddingOf(context).bottom + 78;
    final cs = Theme.of(context).colorScheme;
    final reviewTitle = widget.editing
        ? i18n.tr('audio_detail_edit_info')
        : i18n.tr('dlsite_review_title');
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

    final defaultHeaderHeight = MediaQuery.paddingOf(context).top + 135.0;
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : defaultHeaderHeight;
    final listTopPadding = effectiveHeaderHeight + 8;

    final hasBatchNavigation = widget.onBatchNavigate != null ||
        (widget.batchIndex != null && widget.batchTotal != null);
    final hasCandidateNavigation = _candidates.length > 1 && !_loading;

    final Widget? headerTrailing = hasCandidateNavigation
        ? HeaderActionPill(
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
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                onPressed: _candidateIndex >= _candidates.length - 1 ||
                        _saving
                    ? null
                    : () => _showCandidate(_candidateIndex + 1),
                tooltip: i18n.tr('next'),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          )
        : null;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: PageHeaderInset(
        topInset: listTopPadding,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(child: _loading
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
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        20,
                        listTopPadding,
                        20,
                        bottomInset,
                      ),
                      children: [
                        if (widget.editing &&
                            editingDetail.target.isLibraryRootFolder) ...[
                          FolderCoverSelector(
                            key: ValueKey<String>(
                              'metadata_edit_cover_${editingDetail.target.targetPath}',
                            ),
                            folderPath: editingDetail.target.targetPath,
                            initialCoverPath: library
                                .resolvedCoverPathForFolder(
                                  editingDetail.target.targetPath,
                                ),
                            compactNavigation: true,
                            showLabel: false,
                            onCoverSelected: _handleCoverSelected,
                          ),
                          const SizedBox(height: 20),
                        ],
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
                        if (widget.editing)
                          _ReviewTextField(
                            key: const ValueKey<String>(
                              'metadata_edit_audio_detail_folder_name',
                            ),
                            controller: _folderNameController,
                            label: i18n.tr('audio_detail_folder_name'),
                          ),
                        _ReviewTextField(
                          key: widget.editing
                              ? const ValueKey<String>(
                                  'metadata_edit_audio_detail_work_title',
                                )
                              : null,
                          controller: _titleController,
                          label: i18n.tr('audio_detail_work_title'),
                        ),
                        if (widget.editing)
                          _ReviewTextField(
                            key: const ValueKey<String>(
                              'metadata_edit_audio_detail_rj_code',
                            ),
                            controller: _rjCodeController,
                            label: i18n.tr('audio_detail_rj_code'),
                          )
                        else if ((metadata?.rjCode.trim().isNotEmpty ??
                            false)) ...[
                          _ReviewInfoLine(
                            label: i18n.tr('audio_detail_rj_code'),
                            value: metadata!.rjCode.trim(),
                          ),
                          const SizedBox(height: 12),
                        ],
                        _ReviewTextField(
                          key: widget.editing
                              ? const ValueKey<String>(
                                  'metadata_edit_audio_detail_circle_name',
                                )
                              : null,
                          controller: _circleController,
                          label: i18n.tr('audio_detail_circle_name'),
                        ),
                        _ReviewTextField(
                          key: widget.editing
                              ? const ValueKey<String>(
                                  'metadata_edit_audio_detail_voice_actors',
                                )
                              : null,
                          controller: _voiceActorsController,
                          label: i18n.tr('audio_detail_voice_actors'),
                          hint: i18n.tr('audio_detail_multi_hint'),
                        ),
                        _ReviewTextField(
                          key: widget.editing
                              ? const ValueKey<String>(
                                  'metadata_edit_audio_detail_tags',
                                )
                              : null,
                          controller: _tagsController,
                          label: i18n.tr('audio_detail_tags'),
                          hint: i18n.tr('audio_detail_multi_hint'),
                        ),
                        _ReviewTextField(
                          key: widget.editing
                              ? const ValueKey<String>(
                                  'metadata_edit_audio_detail_release_date',
                                )
                              : null,
                          controller: _releaseDateController,
                          label: i18n.tr('audio_detail_release_date'),
                          hint: 'YYYY-MM-DD',
                        ),
                        _ReviewTextField(
                          key: widget.editing
                              ? const ValueKey<String>(
                                  'metadata_edit_card_info_duration',
                                )
                              : null,
                          controller: _durationController,
                          label: i18n.tr('card_info_duration'),
                          hint: 'HH:MM:SS',
                        ),
                        _ReviewTextField(
                          key: widget.editing
                              ? const ValueKey<String>(
                                  'metadata_edit_audio_detail_rating',
                                )
                              : null,
                          controller: _ratingController,
                          label: i18n.tr('audio_detail_rating'),
                        ),
                      ],
                    )),
            ),
            if (hasBatchNavigation && !_loading)
              Positioned(
                left: 16,
                bottom: 16 + MediaQuery.paddingOf(context).bottom,
                child: AppPageContentTransition(
                  child: HeaderFloatingSurface(
                    key: const ValueKey<String>('dlsite_review_work_navigation'),
                    height: 46,
                    radius: 23,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const ValueKey<String>('dlsite_review_previous_work'),
                          visualDensity: VisualDensity.compact,
                          iconSize: 20,
                          onPressed: !widget.canNavigatePrevious || _saving
                              ? null
                              : () => _navigateWork(-1),
                          tooltip: i18n.tr('previous'),
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        if (widget.batchIndex != null && widget.batchTotal != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              '${widget.batchIndex}/${widget.batchTotal}',
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        IconButton(
                          key: const ValueKey<String>('dlsite_review_next_work'),
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
                ),
              ),
            if (_metadata != null)
              Positioned(
                right: 16,
                bottom: 16 + MediaQuery.paddingOf(context).bottom,
                child: AppPageContentTransition(
                  child: _ReviewConfirmButton(
                    saving: _saving,
                    onTap: _apply,
                    label: i18n.tr(
                      widget.editing ? 'save' : 'confirm',
                    ),
                  ),
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
                  icon: widget.editing
                      ? Icons.edit_note_rounded
                      : Icons.rate_review_rounded,
                  leading: const BackButton(),
                  title: reviewTitle,
                  trailing: headerTrailing,
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
      ),
    );
  }
}

class _ReviewConfirmButton extends StatelessWidget {
  const _ReviewConfirmButton({
    required this.saving,
    required this.onTap,
    required this.label,
  });

  final bool saving;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
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
                Text(
                  label,
                  style: TextStyle(
                    color: cs.onPrimary,
                    fontWeight: FontWeight.w700,
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
