import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/music_track.dart';
import '../application/audio_detail_repository.dart';
import '../application/library_facade.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import 'dlsite_metadata_review_page.dart';
import '../../../core/widgets/app_transitions.dart';

part 'audio_detail_cover_widgets.dart';
part 'audio_detail_field_widgets.dart';
part 'audio_detail_fetch_dialog.dart';

const _multiValueSeparator = '\uFF0C';

Future<void> showAudioDetailSheet(
  BuildContext context,
  AudioDetailTarget target,
) {
  return AppBottomSheet.show<void>(
    context: context,
    builder: (_) => AudioDetailSheet(target: target),
  );
}

class AudioDetailSheet extends ConsumerStatefulWidget {
  const AudioDetailSheet({
    super.key,
    required this.target,
    this.durationCalculator,
  });

  final AudioDetailTarget target;
  @visibleForTesting
  final Future<Duration?> Function(LibraryFacade facade, String targetPath)?
  durationCalculator;

  @override
  ConsumerState<AudioDetailSheet> createState() => _AudioDetailSheetState();
}

class _AudioDetailSheetState extends ConsumerState<AudioDetailSheet> {
  late AudioDetailTarget _target = widget.target;
  AudioDetail? _detail;
  Duration? _calculatedDuration;
  Object? _loadError;
  bool _loading = true;
  bool _runningAction = false;
  bool _calculatingDuration = false;
  int _durationCalculationGeneration = 0;
  _AudioDetailField? _savingField;

  UiOperationScope get _operationScope => UiOperationScope.audioDetail(
    '${_target.targetType.dbValue}|${_target.targetPath}',
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<Duration?> _calculateAutomaticDuration(
    LibraryFacade libraryFacade,
    AudioDetail detail,
  ) {
    if (detail.duration != null) {
      return Future<Duration?>.value();
    }
    return widget.durationCalculator?.call(libraryFacade, _target.targetPath) ??
        libraryFacade.calculateMissingLibraryDuration(_target.targetPath);
  }

  void _startAutomaticDurationCalculation(
    LibraryFacade libraryFacade,
    AudioDetail detail,
  ) {
    final generation = ++_durationCalculationGeneration;
    final target = _target;
    if (detail.duration != null) {
      if (_calculatingDuration || _calculatedDuration != null) {
        setState(() {
          _calculatingDuration = false;
          _calculatedDuration = null;
        });
      }
      return;
    }
    if (!_calculatingDuration) {
      setState(() {
        _calculatingDuration = true;
      });
    }
    unawaited(() async {
      try {
        final calculatedDuration = await _calculateAutomaticDuration(
          libraryFacade,
          detail,
        );
        if (!mounted ||
            generation != _durationCalculationGeneration ||
            _target != target) {
          return;
        }
        setState(() {
          _calculatedDuration = calculatedDuration;
          _calculatingDuration = false;
        });
      } catch (error, stackTrace) {
        AppLogService.warning(
          'audio_detail_duration_calculation_failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (!mounted ||
            generation != _durationCalculationGeneration ||
            _target != target) {
          return;
        }
        setState(() {
          _calculatingDuration = false;
        });
        final i18n = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(appLanguageProviderInstanceProvider);
        showAppSnackBar(
          context,
          i18n.tr('audio_detail_duration_calculation_failed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.warning_amber_rounded,
        );
      }
    }());
  }

  Future<void> _load() async {
    try {
      final libraryFacade = ref.read(libraryFacadeProvider);
      final result = await ref
          .read(uiOperationServiceProvider)
          .run<AudioDetailLoadResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_title',
            task: (_) => libraryFacade.loadAudioDetail(_target),
          );

      if (!mounted) return;
      setState(() {
        _detail = result.detail;
        _loading = false;
      });
      _startAutomaticDurationCalculation(libraryFacade, result.detail);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  Future<void> _editField(_AudioDetailField field) async {
    final detail = _detail;
    if (detail == null || _savingField != null || _runningAction) return;

    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final initialValue = field.isMulti
        ? field.readList(detail).join(_multiValueSeparator)
        : field.readText(detail);
    var editedValue =
        field == _AudioDetailField.rjCode && initialValue.trim().isEmpty
        ? 'RJ'
        : initialValue;
    final value = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AppDialog(
          title: i18n.tr('audio_detail_edit_title', {
            'name': field.label(i18n, detail),
          }),
          icon: Icons.edit_rounded,
          content: TextFormField(
            initialValue: editedValue,
            autofocus: true,
            minLines: 1,
            maxLines: field.isMulti ? 3 : 1,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: field.isMulti
                  ? i18n.tr('audio_detail_multi_hint')
                  : null,
            ),
            onChanged: (value) => editedValue = value,
            onFieldSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: AppDialogActions(
            children: [
              AppSecondaryButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                label: i18n.tr('cancel'),
              ),
              AppPrimaryButton(
                onPressed: () => Navigator.of(dialogContext).pop(editedValue),
                label: MaterialLocalizations.of(dialogContext).saveButtonLabel,
              ),
            ],
          ),
        );
      },
    );
    if (value == null || !mounted) return;

    if (field == _AudioDetailField.targetName) {
      await _renameTargetToName(detail, value);
      return;
    }

    final nextDetail = field.apply(detail, value);
    await _saveField(field, nextDetail);
  }

  Future<void> _renameTargetToName(
    AudioDetail detail,
    String targetName,
  ) async {
    setState(() {
      _savingField = _AudioDetailField.targetName;
      _runningAction = true;
    });
    try {
      final result = await ref
          .read(uiOperationServiceProvider)
          .run<AudioDetailRenameResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_rename_folder_from_title',
            task: (_) => ref
                .read(audioPathCoordinatorProvider)
                .renameAudioDetailTargetToName(detail, targetName),
          );
      if (!mounted) return;
      setState(() {
        _target = result.detail.target;
        _detail = result.detail;
        _savingField = null;
        _runningAction = false;
      });
      final i18n = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appLanguageProviderInstanceProvider);
      if (result.backupFailed) {
        showAppSnackBar(
          context,
          i18n.tr('audio_detail_backup_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _savingField = null;
        _runningAction = false;
      });
      showAppSnackBar(
        context,
        ProviderScope.containerOf(context, listen: false)
            .read(appLanguageProviderInstanceProvider)
            .tr('audio_detail_rename_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  Future<void> _saveField(
    _AudioDetailField field,
    AudioDetail nextDetail,
  ) async {
    setState(() {
      _savingField = field;
    });
    try {
      final libraryFacade = ref.read(libraryFacadeProvider);
      final result = await ref
          .read(uiOperationServiceProvider)
          .run<AudioDetailSaveResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_save_failed',
            task: (_) => libraryFacade.saveAudioDetail(nextDetail),
          );
      if (!mounted) return;
      setState(() {
        _detail = result.detail;
        if (field == _AudioDetailField.duration) {
          _calculatedDuration = null;
        }
        _savingField = null;
      });
      if (field == _AudioDetailField.duration) {
        _startAutomaticDurationCalculation(libraryFacade, result.detail);
      }
      final i18n = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appLanguageProviderInstanceProvider);
      if (field == _AudioDetailField.rjCode &&
          !_looksLikeRjCode(result.detail.rjCode)) {
        showAppSnackBar(
          context,
          i18n.tr('audio_detail_rj_format_hint'),
          tone: AppFeedbackTone.warning,
        );
      }
      if (result.backupFailed) {
        showAppSnackBar(
          context,
          i18n.tr('audio_detail_backup_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
      if (result.coverPortabilitySkipped) {
        showAppSnackBar(
          context,
          i18n.tr('audio_detail_cover_portability_skipped'),
          tone: AppFeedbackTone.warning,
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _savingField = null;
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

  Future<void> _confirmFetchInfo(AudioDetail detail) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final query = ref
        .read(libraryFacadeProvider)
        .buildDlsiteMetadataQuery(detail);
    if (!query.hasQuery) {
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_fetch_missing_query'),
        tone: AppFeedbackTone.warning,
      );
      return;
    }
    final scope = await showAppDialog<_AudioDetailFetchScope>(
      context: context,
      builder: (context) => const _AudioDetailFetchScopeDialog(),
    );
    if (scope == null || !mounted) return;

    final result = await Navigator.of(context).push<DlsiteMetadataReviewResult>(
      buildAppPageRoute(
        context: context,
        style: AppPageTransitionStyle.sharedAxisZ,
        child: DlsiteMetadataReviewPage(
          detail: detail,
          rjCode: query.rjCode,
          searchTitles: query.searchTitles,
          missingOnly: scope == _AudioDetailFetchScope.missing,
        ),
      ),
    );
    final updated = result?.detail;
    if (updated == null || !mounted) return;
    setState(() {
      _detail = updated;
      _target = updated.target;
    });
  }

  Future<void> _confirmRename(AudioDetail detail) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    if (detail.workTitle.trim().isEmpty) {
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_rename_missing_title'),
        tone: AppFeedbackTone.warning,
      );
      return;
    }
    final confirmed = await _confirmAction(
      title: _renameWorkTitleLabel(detail, i18n),
      message: i18n.tr('audio_detail_rename_confirm'),
      confirmLabel: i18n.tr('confirm'),
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _runningAction = true;
    });
    try {
      final result = await ref
          .read(uiOperationServiceProvider)
          .run<AudioDetailRenameResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_rename_folder_from_title',
            task: (_) => ref
                .read(audioPathCoordinatorProvider)
                .renameAudioDetailTarget(detail),
          );
      if (!mounted) return;
      setState(() {
        _target = result.detail.target;
        _detail = result.detail;
        _runningAction = false;
      });
      showAppSnackBar(
        context,
        result.backupFailed
            ? i18n.tr('audio_detail_backup_failed')
            : i18n.tr('audio_detail_rename_done'),
        tone: result.backupFailed
            ? AppFeedbackTone.warning
            : AppFeedbackTone.success,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _runningAction = false;
      });
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_rename_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  Future<bool> _confirmAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return showConfirmActionDialog(
      context: context,
      title: title,
      message: message,
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: confirmLabel,
      icon: Icons.drive_file_rename_outline_rounded,
      confirmIcon: Icons.check_rounded,
      isDestructive: false,
    );
  }

  @override
  void dispose() {
    _durationCalculationGeneration++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);
    final detail = _detail;
    final libraryFacade = ref.read(libraryFacadeProvider);
    final track = ref.watch(libraryTrackProvider(_target.targetPath));
    final coverGeneration = ref.watch(coverGenerationProvider);

    Duration? duration = detail?.duration ?? _calculatedDuration;
    if (duration == null && !_target.isLibraryRootFolder) {
      final trackDuration = track?.duration;
      if (trackDuration != null && trackDuration > Duration.zero) {
        duration = trackDuration;
      }
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.68,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    i18n.tr('audio_detail_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _target.isLibraryRootFolder
                  ? i18n.tr('audio_detail_library_root')
                  : i18n.tr('audio_detail_single_file'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 2),
            Text(
              PathDisplay.displayPathFor(_target.targetPath),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const OperationSkeletonList(
                itemCount: 5,
                showHeader: false,
                padding: EdgeInsets.symmetric(vertical: 6),
              )
            else if (_loadError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: OperationStatusBanner(
                  label: i18n.tr('audio_detail_load_failed'),
                  error: _loadError,
                  onRetry: () => unawaited(_load()),
                ),
              )
            else if (detail != null) ...[
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _runningAction
                            ? null
                            : () => _confirmFetchInfo(detail),
                        icon: const Icon(Icons.cloud_download_rounded),
                        label: Text(
                          i18n.tr('audio_detail_fetch_info'),
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _runningAction
                            ? null
                            : () => _confirmRename(detail),
                        icon: const Icon(Icons.drive_file_rename_outline),
                        label: Text(
                          _renameWorkTitleLabel(detail, i18n),
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_target.isLibraryRootFolder) ...[
                _FolderCoverSelector(
                  key: ValueKey('${_target.targetPath}:$coverGeneration'),
                  folderPath: _target.targetPath,
                  initialCoverPath: libraryFacade.resolvedCoverPathForFolder(
                    _target.targetPath,
                  ),
                  onCoverSelected: (coverPath) {
                    setState(() {
                      _detail = _detail?.copyWith(
                        cardCoverPath: coverPath,
                        cardCoverSelected: true,
                      );
                    });
                  },
                ),
                const SizedBox(height: 12),
              ] else ...[
                _SingleFileCoverPreview(filePath: _target.targetPath),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 12),
              Text(
                i18n.tr('asmr_detail_basic_info'),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 8),
              ...[
                _AudioDetailField.targetName,
                _AudioDetailField.rjCode,
                _AudioDetailField.workTitle,
                _AudioDetailField.circleName,
                _AudioDetailField.voiceActors,
                _AudioDetailField.tags,
              ].map(
                (field) => _AudioDetailRow(
                  label: field.label(i18n, detail),
                  values: field.readValues(detail),
                  labelStyle: labelStyle,
                  busy: _savingField == field,
                  onTap: () => _editField(field),
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                i18n.tr('asmr_detail_other'),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 8),
              ...[
                _AudioDetailField.releaseDate,
                _AudioDetailField.duration,
                _AudioDetailField.salesCount,
                _AudioDetailField.rating,
              ].map(
                (field) => _AudioDetailRow(
                  label: field.label(i18n, detail),
                  values: field.readValues(detail, fallbackDuration: duration),
                  labelStyle: labelStyle,
                  busy:
                      _savingField == field ||
                      (field == _AudioDetailField.duration &&
                          _calculatingDuration),
                  onTap: () => _editField(field),
                  onCopy: (val) => _copyText(context, val),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _renameWorkTitleLabel(AudioDetail detail, AppLanguageProvider i18n) {
  return detail.target.isLibraryRootFolder
      ? i18n.tr('audio_detail_rename_folder_from_title')
      : i18n.tr('audio_detail_rename_file_from_title');
}
