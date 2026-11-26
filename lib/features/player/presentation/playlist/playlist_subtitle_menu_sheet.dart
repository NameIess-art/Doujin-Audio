import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/app_buttons.dart';
import 'package:path/path.dart' as path;

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/logging/app_log_service.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/translation/translation_service_settings.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_entry_ink_well.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/confirm_action_dialog.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../../library/application/work_text_service.dart';
import '../../../library/presentation/library_providers.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_subtitle_service.dart';
import '../../application/subtitle_model_store.dart';
import '../../application/subtitle_generation.dart';
import '../playback_providers.dart';
import 'subtitle_editor_page.dart';
import 'subtitle_model_download_dialog.dart';
import 'subtitle_generation_dialog.dart';

Future<void> showSubtitleMenuBottomSheet({
  required BuildContext context,
  required PlaybackSessionSnapshot session,
  required VoidCallback? onToggleGlobalSubtitle,
}) {
  return AppBottomSheet.show<void>(
    context: context,
    builder: (sheetContext) => ClipRect(
      child: SubtitleMenuSheet(
        session: session,
        onToggleGlobalSubtitle: onToggleGlobalSubtitle,
      ),
    ),
  );
}

class SubtitleMenuSheet extends ConsumerStatefulWidget {
  const SubtitleMenuSheet({
    super.key,
    required this.session,
    this.onToggleGlobalSubtitle,
    this.generationUnavailableReason,
  });

  final PlaybackSessionSnapshot session;
  final VoidCallback? onToggleGlobalSubtitle;
  final String? Function()? generationUnavailableReason;

  @override
  ConsumerState<SubtitleMenuSheet> createState() => _SubtitleMenuSheetState();
}

class _SubtitleMenuSheetState extends ConsumerState<SubtitleMenuSheet> {
  final GlobalKey _menuKey = GlobalKey();
  bool _importing = false;
  bool _importingSubtitleFile = false;
  String? _checkingModelKey;
  List<WorkTextFile>? _scriptFiles;
  List<({String sourcePath, String name})>? _subtitleFiles;
  bool _subtitleBusy = false;
  double? _selectionMenuHeight;
  late PlaybackSubtitleService _subtitles;
  int _availableSubtitleCount = 0;
  int _subtitleCountRequestId = 0;
  String? _observedTrackPath;
  Duration? _observedOffset;
  (String, String?, String?)? _availableSubtitleCountKey;

  PlaybackSessionSnapshot get _liveSession {
    final asyncSession = ref.read(
      playbackSessionStateProvider(widget.session.id),
    );
    if (asyncSession.hasValue && asyncSession.value != null) {
      return asyncSession.value!;
    }
    if (!asyncSession.hasError) {
      return ref
              .read(playbackFacadeProvider)
              .sessionSnapshotById(widget.session.id) ??
          widget.session;
    }
    return widget.session;
  }

  String get _currentTrackPath => _liveSession.currentTrackPath;

  @override
  void initState() {
    super.initState();
    _subtitles = ref.read(playbackSubtitleServiceProvider)
      ..addListener(_handleSubtitleServiceChanged);
    final trackPath = _currentTrackPath;
    _observedTrackPath = trackPath;
    _observedOffset = trackPath.isEmpty
        ? Duration.zero
        : _subtitles.getOffset(trackPath);
    if (trackPath.isNotEmpty) {
      if (!_subtitles.hasResult(trackPath)) {
        unawaited(_subtitles.load(trackPath));
      }
      _updateAvailableSubtitleCount();
    }
  }

  @override
  void didUpdateWidget(SubtitleMenuSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextPath = _currentTrackPath;
    if (_observedTrackPath != nextPath) {
      _handleTrackChanged(nextPath);
    }
  }

  void _handleTrackChanged(String trackPath) {
    _observedTrackPath = trackPath;
    _subtitleFiles = null;
    _scriptFiles = null;
    _availableSubtitleCount = 0;
    if (trackPath.isNotEmpty && !_subtitles.hasResult(trackPath)) {
      unawaited(_subtitles.load(trackPath));
    }
    _updateAvailableSubtitleCount();
  }

  @override
  void dispose() {
    _subtitles.removeListener(_handleSubtitleServiceChanged);
    super.dispose();
  }

  (String, String?, String?) _subtitleCountKeyFor(String trackPath) => (
    trackPath,
    trackPath.isEmpty ? null : _subtitles.customPathFor(trackPath),
    trackPath.isEmpty ? null : _subtitles.trackSync(trackPath)?.sourcePath,
  );

  void _handleSubtitleServiceChanged() {
    if (_subtitles.generationJob?.status == SubtitleGenerationStatus.running) {
      return;
    }
    final trackPath = _currentTrackPath;
    final nextOffset = trackPath.isEmpty
        ? Duration.zero
        : _subtitles.getOffset(trackPath);
    final nextKey = _subtitleCountKeyFor(trackPath);
    if (nextOffset != _observedOffset &&
        nextKey == _availableSubtitleCountKey) {
      _observedOffset = nextOffset;
      return;
    }
    _observedOffset = nextOffset;
    _updateAvailableSubtitleCount();
  }

  void _updateAvailableSubtitleCount() {
    final trackPath = _currentTrackPath;
    _availableSubtitleCountKey = _subtitleCountKeyFor(trackPath);
    _observedOffset = trackPath.isEmpty
        ? Duration.zero
        : _subtitles.getOffset(trackPath);
    if (trackPath.isEmpty) {
      if (_availableSubtitleCount != 0) {
        setState(() => _availableSubtitleCount = 0);
      }
      return;
    }
    final requestId = ++_subtitleCountRequestId;
    _subtitles
        .availableSubtitleFiles(trackPath)
        .then((files) {
          if (!mounted || requestId != _subtitleCountRequestId) return;
          if (_currentTrackPath != trackPath) return;
          if (_availableSubtitleCount != files.length) {
            setState(() => _availableSubtitleCount = files.length);
          }
        })
        .catchError((_) {
          if (!mounted || requestId != _subtitleCountRequestId) return;
          if (_currentTrackPath != trackPath) return;
          if (_availableSubtitleCount != 0) {
            setState(() => _availableSubtitleCount = 0);
          }
        });
  }

  String _formatOffset(Duration offset) {
    final seconds = offset.inMilliseconds / 1000.0;
    if (offset == Duration.zero) return '0.0s';
    final sign = seconds > 0 ? '+' : '';
    return '$sign${seconds.toStringAsFixed(1)}s';
  }

  Future<void> _pickExistingSubtitle(PlaybackSubtitleService subtitles) async {
    if (_importing ||
        _subtitleBusy ||
        subtitles.generationJob?.status == SubtitleGenerationStatus.running) {
      return;
    }
    final menuHeight = _menuKey.currentContext?.size?.height;
    final trackPath = _currentTrackPath;
    setState(() => _subtitleBusy = true);
    try {
      final files = await subtitles.availableSubtitleFiles(trackPath);
      if (!mounted || _currentTrackPath != trackPath) return;
      if (files.isEmpty) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('subtitle_selection_empty'),
          tone: AppFeedbackTone.warning,
          icon: Icons.subtitles_off_rounded,
        );
        return;
      }
      setState(() {
        _subtitleFiles = files;
        _selectionMenuHeight = menuHeight;
        _availableSubtitleCount = files.length;
      });
    } catch (_) {
      if (mounted && _currentTrackPath == trackPath) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('subtitle_load_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
    } finally {
      if (mounted) setState(() => _subtitleBusy = false);
    }
  }

  Future<void> _selectSubtitleFile(
    PlaybackSubtitleService subtitles,
    String sourcePath,
  ) async {
    if (_subtitleBusy ||
        subtitles.generationJob?.status == SubtitleGenerationStatus.running) {
      return;
    }
    final trackPath = _currentTrackPath;
    final sessionId = widget.session.id;
    setState(() => _subtitleBusy = true);
    try {
      await subtitles.selectSubtitleFile(trackPath, sourcePath);
      if (!mounted ||
          _currentTrackPath != trackPath ||
          widget.session.id != sessionId) {
        return;
      }
      ref
          .read(subtitleSettingsProvider.notifier)
          .ensureSubtitlesEnabled(sessionId);
      setState(() => _subtitleFiles = null);
      showAppSnackBar(
        context,
        ref.read(appLanguageProviderInstanceProvider).tr('subtitle_selected'),
        tone: AppFeedbackTone.success,
        icon: Icons.check_circle_rounded,
      );
    } catch (_) {
      if (mounted &&
          _currentTrackPath == trackPath &&
          widget.session.id == sessionId) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('subtitle_load_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
    } finally {
      if (mounted) setState(() => _subtitleBusy = false);
    }
  }

  Future<void> _pickSubtitleFile(
    BuildContext context,
    PlaybackSubtitleService subtitles,
  ) async {
    if (_importing ||
        subtitles.generationJob?.status == SubtitleGenerationStatus.running) {
      return;
    }
    setState(() {
      _importing = true;
      _importingSubtitleFile = true;
    });
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final trackPath = _currentTrackPath;

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'lrc',
          'srt',
          'vtt',
          'webvtt',
          'ass',
          'ssa',
          'txt',
        ],
      );
      if (!mounted) return;
      final selected = result?.files.singleOrNull;
      final identifier = selected?.identifier;
      final selectedPath = identifier?.startsWith('content://') == true
          ? identifier
          : selected?.path;
      if (selectedPath == null || selectedPath.isEmpty) return;
      final overwrite = await _confirmSubtitleOverwrite(subtitles, trackPath);
      if (overwrite == null) return;
      final track = await subtitles.importSubtitle(
        trackPath,
        selectedPath,
        fileName: selected?.name,
        overwrite: overwrite,
      );
      if (!mounted || !context.mounted) return;

      if (track != null) {
        ref
            .read(subtitleSettingsProvider.notifier)
            .ensureSubtitlesEnabled(widget.session.id);
        _updateAvailableSubtitleCount();
        showAppSnackBar(
          context,
          i18n.tr('subtitle_imported'),
          tone: AppFeedbackTone.success,
          icon: Icons.check_circle_rounded,
        );
      } else {
        showAppSnackBar(
          context,
          i18n.tr('subtitle_import_failed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _importingSubtitleFile = false;
        });
      }
    }
  }

  Future<void> _showGeneration(PlaybackSubtitleService subtitles) async {
    if (subtitles.generationJob == null) return;
    await showAppDialog<void>(
      context: context,
      builder: (_) => SubtitleGenerationDialog(service: subtitles),
    );
  }

  Future<void> _pickScriptFile() async {
    if (_importing) return;
    final menuHeight = _menuKey.currentContext?.size?.height;
    setState(() => _importing = true);
    try {
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      final target = ref
          .read(libraryFacadeProvider)
          .audioDetailTargetForPath(_currentTrackPath);
      final folderPath = target.isLibraryRootFolder
          ? target.targetPath
          : PathMatcher.parentPath(target.targetPath);
      final files = folderPath == null
          ? const <WorkTextFile>[]
          : (await ref
                    .read(workTextServiceProvider)
                    .findWorkTextFiles(folderPath))
                .where((file) {
                  final extension = path.extension(file.name).toLowerCase();
                  return extension == '.txt' || extension == '.md';
                })
                .toList(growable: false);
      if (!mounted) return;
      if (files.isEmpty) {
        showAppSnackBar(
          context,
          i18n.tr('script_text_not_found'),
          tone: AppFeedbackTone.warning,
          icon: Icons.warning_amber_rounded,
        );
        return;
      }
      setState(() {
        _scriptFiles = files;
        _selectionMenuHeight = menuHeight;
      });
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('subtitle_task_failed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _selectScriptFile(
    PlaybackSubtitleService subtitles,
    WorkTextFile selected,
  ) async {
    if (_importing || _scriptFiles == null) return;
    setState(() {
      _importing = true;
      _scriptFiles = null;
    });
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final trackPath = _currentTrackPath;
    try {
      final selectedPath = selected.path;
      if (path.extension(selected.name).toLowerCase() == '.txt' &&
          await subtitles.isTimedSubtitleFile(selectedPath)) {
        if (!mounted) return;
        await _pickTimedScript(
          subtitles,
          selectedPath,
          trackPath: trackPath,
          fileName: selected.name,
        );
        return;
      }
      if (!mounted) return;
      if (_importing) {
        setState(() => _importing = false);
      }
      if (subtitles.hasKnownSubtitle(trackPath)) {
        final confirmed = await showConfirmActionDialog(
          context: context,
          title: i18n.tr('subtitle_script_existing_title'),
          message: i18n.tr('subtitle_script_existing_hint'),
          cancelLabel: i18n.tr('cancel'),
          confirmLabel: i18n.tr('subtitle_script_continue'),
          isDestructive: false,
        );
        if (!mounted || !confirmed) return;
      }
      if (!mounted) return;
      if (!await _confirmModelsDownload(
        const <SubtitleModelSpec>[SubtitleModelStore.japaneseCtc],
        checkKey: 'script',
      )) {
        return;
      }
      final downloadingInBackground = subtitles.modelStore
          .snapshot(SubtitleModelStore.japaneseCtc)
          .active;
      final settings = ref.read(subtitleSettingsProvider.notifier);
      final sessionId = widget.session.id;
      if (subtitles.startScriptGeneration(
        trackPath,
        selectedPath,
        onApplied: () => settings.ensureSubtitlesEnabled(sessionId),
      )) {
        if (!downloadingInBackground) {
          await _showGeneration(subtitles);
        }
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('subtitle_task_failed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _pickTimedScript(
    PlaybackSubtitleService subtitles,
    String selectedPath, {
    required String trackPath,
    required String fileName,
  }) async {
    final overwrite = await _confirmSubtitleOverwrite(subtitles, trackPath);
    if (overwrite == null) return;
    if (mounted) setState(() => _importingSubtitleFile = true);
    final Object? imported;
    try {
      imported = await subtitles.importSubtitle(
        trackPath,
        selectedPath,
        fileName: fileName,
        overwrite: overwrite,
      );
    } finally {
      if (mounted) setState(() => _importingSubtitleFile = false);
    }
    if (!mounted) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    if (imported != null) {
      ref
          .read(subtitleSettingsProvider.notifier)
          .ensureSubtitlesEnabled(widget.session.id);
      _updateAvailableSubtitleCount();
    }
    showAppSnackBar(
      context,
      i18n.tr(
        imported == null ? 'subtitle_import_failed' : 'subtitle_imported',
      ),
      tone: imported == null
          ? AppFeedbackTone.warning
          : AppFeedbackTone.success,
    );
  }

  Future<bool?> _confirmSubtitleOverwrite(
    PlaybackSubtitleService subtitles,
    String trackPath, {
    String messageKey = 'subtitle_import_overwrite_hint',
  }) async {
    final exists = await subtitles.hasLocalSubtitleFile(trackPath);
    if (!mounted) return null;
    if (!exists) return false;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('subtitle_import_overwrite_title'),
      message: i18n.tr(messageKey),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('subtitle_import_overwrite'),
      isDestructive: false,
    );
    return confirmed ? true : null;
  }

  Future<void> _translateSubtitle(SubtitleLanguage language) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    if (language == SubtitleLanguage.unknown) {
      final confirmed = await showConfirmActionDialog(
        context: context,
        title: i18n.tr('subtitle_source_confirm_japanese'),
        message: i18n.tr('subtitle_source_confirm_japanese_hint'),
        cancelLabel: i18n.tr('cancel'),
        confirmLabel: i18n.tr('confirm'),
        icon: Icons.translate_rounded,
        isDestructive: false,
      );
      if (!mounted || !confirmed) return;
    }
    final targetLanguage = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final cs = theme.colorScheme;
        final tokens = AppDesignTokens.of(dialogContext);
        final cardRadius = BorderRadius.circular(tokens.radiusCard);
        final isZh = i18n.locale.languageCode == 'zh';
        final isEn = i18n.locale.languageCode == 'en';
        final zhSubtitle = isZh ? 'Chinese (Simplified)' : '中文（简体）';
        final enSubtitle = isEn ? '英语' : 'English';

        Widget buildLanguageOption({
          required String code,
          required String badge,
          required Color badgeColor,
          required String title,
          required String subtitle,
        }) {
          return Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            shape: RoundedRectangleBorder(
              borderRadius: cardRadius,
              side: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: AppEntryInkWell(
              borderRadius: cardRadius,
              onTap: () => Navigator.pop(dialogContext, code),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(
                          tokens.radiusControl,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          badge,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: badgeColor,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final subtitlesForHint = ref.read(playbackSubtitleServiceProvider);
        final customTranslation = subtitlesForHint.translationService
            .usesCustomBackendFor(TextTranslationScene.subtitle);
        final customModel = subtitlesForHint.translationService.settings.model
            .trim();
        final translateHint = customTranslation
            ? i18n.tr('subtitle_translate_custom_hint', {
                'model': customModel.isEmpty
                    ? i18n.tr('translation_provider_custom')
                    : customModel,
              })
            : i18n.tr('subtitle_translate_hint');

        return AppDialog(
          title: i18n.tr('subtitle_choose_language'),
          icon: Icons.translate_rounded,
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                translateHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              buildLanguageOption(
                code: 'zh',
                badge: 'ZH',
                badgeColor: cs.primary,
                title: i18n.tr('subtitle_language_zh'),
                subtitle: zhSubtitle,
              ),
              const SizedBox(height: AppSpacing.sm),
              buildLanguageOption(
                code: 'en',
                badge: 'EN',
                badgeColor: cs.secondary,
                title: i18n.tr('subtitle_language_en'),
                subtitle: enSubtitle,
              ),
            ],
          ),
          actions: AppDialogActions(
            children: [
              AppSecondaryButton(
                onPressed: () => Navigator.pop(dialogContext),
                label: i18n.tr('cancel'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || targetLanguage == null) return;
    final subtitles = ref.read(playbackSubtitleServiceProvider);
    final settings = ref.read(subtitleSettingsProvider.notifier);
    final sessionId = widget.session.id;
    if (subtitles.startTranslationGeneration(
      _currentTrackPath,
      targetLanguage,
      sourceJapaneseConfirmed: language == SubtitleLanguage.unknown,
      onApplied: () => settings.ensureSubtitlesEnabled(sessionId),
    )) {
      await _showGeneration(subtitles);
    }
  }

  Future<void> _transcribeAudio(PlaybackSubtitleService subtitles) async {
    if (_importing ||
        _subtitleBusy ||
        _checkingModelKey != null ||
        subtitles.generationJob?.status == SubtitleGenerationStatus.running) {
      return;
    }
    final trackPath = _currentTrackPath;
    final sessionId = widget.session.id;
    try {
      final overwrite = await _confirmSubtitleOverwrite(
        subtitles,
        trackPath,
        messageKey: 'subtitle_transcribe_overwrite_hint',
      );
      if (overwrite == null || !mounted) return;
      final asrSpecs = subtitles.activeAsrModel.bundleSpecs;
      if (!await _confirmModelsDownload(
        asrSpecs,
        checkKey: 'transcribe',
        titleKey: 'subtitle_asr_model_download_title',
        messageKey: 'subtitle_asr_model_download_message',
      )) {
        return;
      }
      final downloadingInBackground = subtitles.modelStore
          .bundleSnapshot(asrSpecs)
          .active;
      final settings = ref.read(subtitleSettingsProvider.notifier);
      if (subtitles.startTranscriptionGeneration(
        trackPath,
        onApplied: () => settings.ensureSubtitlesEnabled(sessionId),
      )) {
        if (!downloadingInBackground) {
          await _showGeneration(subtitles);
        }
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'subtitle_transcribe_entry_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('subtitle_task_failed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.error_outline_rounded,
        );
      }
    }
  }

  Future<bool> _confirmModelsDownload(
    List<SubtitleModelSpec> specs, {
    required String checkKey,
    String titleKey = 'subtitle_model_download_title',
    String messageKey = 'subtitle_model_download_message',
  }) async {
    final store = ref.read(playbackSubtitleServiceProvider).modelStore;
    setState(() => _checkingModelKey = checkKey);
    late final SubtitleModelStatus status;
    try {
      status = await store.bundleStatus(specs);
    } finally {
      if (mounted) setState(() => _checkingModelKey = null);
    }
    if (!mounted) return false;
    if (status.ready) return true;
    final downloaded = await showAppDialog<bool>(
      context: context,
      builder: (_) => SubtitleModelDownloadDialog(
        store: store,
        specs: specs,
        status: status,
        titleKey: titleKey,
        messageKey: messageKey,
      ),
    );
    return mounted && downloaded == true;
  }

  void _adjustOffset(PlaybackSubtitleService subtitles, int deltaMs) {
    final trackPath = _currentTrackPath;
    final currentOffset = subtitles.getOffset(trackPath);
    final nextMs = (currentOffset.inMilliseconds + deltaMs).clamp(
      -60000,
      60000,
    );
    if (nextMs == currentOffset.inMilliseconds) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    unawaited(
      subtitles.setTrackOffset(trackPath, Duration(milliseconds: nextMs)),
    );
  }

  void _resetOffset(PlaybackSubtitleService subtitles) {
    final trackPath = _currentTrackPath;
    if (subtitles.getOffset(trackPath) == Duration.zero) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    unawaited(subtitles.setTrackOffset(trackPath, Duration.zero));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final subtitles = ref.watch(playbackSubtitleServiceProvider);
    final (showSubtitles, globalSubtitles) = ref.watch(
      subtitleSettingsProvider.select(
        (state) => (
          state.isShowEnabled(widget.session.id),
          state.isGlobalEnabled(widget.session.id),
        ),
      ),
    );
    final selectedTrackPath = ref.watch(
      playbackSessionStateProvider(
        widget.session.id,
      ).select((asyncSession) => asyncSession.value?.currentTrackPath),
    );
    final trackPath =
        selectedTrackPath ??
        (ref.read(playbackSessionStateProvider(widget.session.id)).hasError
            ? widget.session.currentTrackPath
            : ref
                      .read(playbackFacadeProvider)
                      .sessionSnapshotById(widget.session.id)
                      ?.currentTrackPath ??
                  widget.session.currentTrackPath);
    if (_observedTrackPath != trackPath) {
      _observedTrackPath = trackPath;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _currentTrackPath != trackPath) return;
        setState(() {
          _subtitleFiles = null;
          _scriptFiles = null;
          _availableSubtitleCount = 0;
        });
        if (trackPath.isNotEmpty && !_subtitles.hasResult(trackPath)) {
          unawaited(_subtitles.load(trackPath));
        }
        _updateAvailableSubtitleCount();
      });
    }

    return ListenableBuilder(
      listenable: subtitles,
      builder: (context, _) {
        final activeOffset = subtitles.getOffset(trackPath);
        final activeTrack = subtitles.trackSync(trackPath);
        final canEditSubtitle =
            activeTrack?.cues.isNotEmpty == true &&
            subtitles.canEditSubtitle(trackPath);
        final subtitleLanguage = subtitles.classifyCurrentSubtitle(trackPath);
        final generationJob = subtitles.generationJob;
        final generationBusy =
            generationJob?.status == SubtitleGenerationStatus.running;
        final generationUnavailableKey =
            widget.generationUnavailableReason == null
            ? subtitleGenerationUnavailableReason
            : widget.generationUnavailableReason!();
        final hasSubtitle =
            trackPath.isNotEmpty &&
            (activeTrack?.cues.isNotEmpty == true ||
                subtitles.hasKnownSubtitle(trackPath));
        final importEnabled =
            trackPath.isNotEmpty &&
            subtitles.canEditSubtitle(trackPath) &&
            !_importing &&
            !_subtitleBusy &&
            !(generationBusy && generationJob?.trackPath == trackPath);
        final selectionEnabled =
            trackPath.isNotEmpty &&
            !PathMatcher.isRemoteUri(trackPath) &&
            !_importing &&
            !_subtitleBusy &&
            !generationBusy &&
            _availableSubtitleCount > 1;
        final generateEnabled =
            importEnabled &&
            !generationBusy &&
            _checkingModelKey == null &&
            generationUnavailableKey == null;
        final translateEnabled =
            importEnabled &&
            !generationBusy &&
            _checkingModelKey == null &&
            activeTrack?.cues.isNotEmpty == true &&
            subtitleLanguage != SubtitleLanguage.other;
        final isOffsetZero = activeOffset == Duration.zero;
        final scriptFiles = _scriptFiles;
        final subtitleFiles = _subtitleFiles;
        final selectingFiles = scriptFiles != null || subtitleFiles != null;
        final selectionFiles =
            subtitleFiles ??
            scriptFiles
                ?.map(
                  (file) => (
                    sourcePath: file.path,
                    name: file.relativePath.isEmpty
                        ? file.name
                        : file.relativePath,
                  ),
                )
                .toList(growable: false) ??
            const <({String sourcePath, String name})>[];
        final selectionBusy = _subtitleBusy || generationBusy;
        const menuPadding = AppBottomSheet.contentPadding;
        Widget buildMenu({
          Key? key,
          required Widget header,
          required Widget body,
          FlexFit bodyFit = FlexFit.loose,
        }) => Padding(
          padding: menuPadding,
          child: Column(
            key: key,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 16),
              Flexible(fit: bodyFit, child: body),
            ],
          ),
        );

        Widget buildHeader({
          required bool selectingScript,
          bool selectingSubtitle = false,
        }) => ConstrainedBox(
          key: ValueKey(
            selectingSubtitle
                ? 'subtitle_selection_header'
                : selectingScript
                ? 'subtitle_script_header'
                : 'subtitle_menu_header',
          ),
          constraints: const BoxConstraints(minHeight: 48),
          child: AppBottomSheetHeader(
            icon: selectingScript
                ? Icons.text_snippet_rounded
                : Icons.subtitles_rounded,
            title: i18n.tr(
              selectingSubtitle
                  ? 'subtitle_select'
                  : selectingScript
                  ? 'subtitle_script_selection_title'
                  : 'subtitles',
            ),
            trailing: selectingScript || selectingSubtitle
                ? IconButton(
                    key: ValueKey(
                      selectingSubtitle
                          ? 'subtitle_selection_back'
                          : 'subtitle_script_back',
                    ),
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: i18n.tr('back'),
                    color: cs.primary,
                    onPressed: _subtitleBusy
                        ? null
                        : () => setState(() {
                            _scriptFiles = null;
                            _subtitleFiles = null;
                          }),
                  )
                : null,
          ),
        );
        final cardDecoration = BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: 0.35),
            width: 0.5,
          ),
        );
        final selectionContent = !selectingFiles
            ? null
            : ColoredBox(
                color:
                    theme.bottomSheetTheme.modalBackgroundColor ??
                    theme.bottomSheetTheme.backgroundColor ??
                    cs.surfaceContainerLow,
                child: SafeArea(
                  child: buildMenu(
                    key: ValueKey(
                      subtitleFiles != null
                          ? 'subtitle_file_selection'
                          : 'subtitle_script_selection',
                    ),
                    header: buildHeader(
                      selectingScript: scriptFiles != null,
                      selectingSubtitle: subtitleFiles != null,
                    ),
                    bodyFit: FlexFit.tight,
                    body: SingleChildScrollView(
                      key: ValueKey(
                        subtitleFiles != null
                            ? 'subtitle_files'
                            : 'subtitle_script_files',
                      ),
                      child: Theme(
                        data: AppEntryInkWell.entryTheme(context),
                        child: Container(
                          decoration: cardDecoration,
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              for (
                                var index = 0;
                                index < selectionFiles.length;
                                index++
                              ) ...[
                                if (index > 0)
                                  Divider(
                                    height: 1,
                                    thickness: 0.5,
                                    indent: 16,
                                    endIndent: 16,
                                    color: cs.outlineVariant.withValues(
                                      alpha: 0.35,
                                    ),
                                  ),
                                ListTile(
                                  key: subtitleFiles == null
                                      ? null
                                      : ValueKey(
                                          selectionFiles[index]
                                              .sourcePath,
                                        ),
                                  enabled:
                                      subtitleFiles == null ||
                                      !selectionBusy,
                                  titleAlignment:
                                      ListTileTitleAlignment.top,
                                  leading: Icon(
                                    subtitleFiles != null
                                        ? Icons.subtitles_rounded
                                        : Icons.text_snippet_rounded,
                                    color: cs.primary,
                                  ),
                                  title: Text(
                                    selectionFiles[index].name,
                                    style: theme.textTheme.bodyLarge
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  trailing:
                                      subtitleFiles != null &&
                                          selectionFiles[index]
                                                  .sourcePath ==
                                              activeTrack?.sourcePath
                                      ? Icon(
                                          Icons.check_rounded,
                                          color: cs.primary,
                                        )
                                      : null,
                                  onTap: selectionBusy
                                      ? null
                                      : subtitleFiles != null
                                      ? () => _selectSubtitleFile(
                                          subtitles,
                                          selectionFiles[index]
                                              .sourcePath,
                                        )
                                      : () => _selectScriptFile(
                                          subtitles,
                                          scriptFiles![index],
                                        ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ).withWindowsSmoothScroll(),
                  ),
                ),
              );

        final menu = SafeArea(
          child: buildMenu(
            header: buildHeader(selectingScript: false),
            body: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Switches Card
                  Theme(
                    data: AppEntryInkWell.entryTheme(context),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          decoration: cardDecoration,
                          child: Column(
                      children: [
                        SwitchListTile(
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(16),
                            ),
                          ),
                          secondary: Icon(
                            showSubtitles
                                ? Icons.subtitles_rounded
                                : Icons.subtitles_off_rounded,
                            color: !hasSubtitle
                                ? cs.onSurface.withValues(alpha: 0.38)
                                : (showSubtitles
                                      ? cs.primary
                                      : cs.onSurfaceVariant),
                          ),
                          title: Text(
                            i18n.tr('turn_on_subtitle'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: !hasSubtitle
                                  ? cs.onSurface.withValues(alpha: 0.38)
                                  : null,
                            ),
                          ),
                          value: showSubtitles,
                          onChanged: !hasSubtitle
                              ? null
                              : (_) {
                                  AppInteractionFeedback.trigger(
                                    AppInteractionFeedbackType.selection,
                                  );
                                  ref
                                      .read(subtitleSettingsProvider.notifier)
                                      .toggleShowSubtitles(widget.session.id);
                                },
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 16,
                          endIndent: 16,
                          color: cs.outlineVariant.withValues(alpha: 0.35),
                        ),
                        SwitchListTile(
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              bottom: Radius.circular(16),
                            ),
                          ),
                          secondary: Icon(
                            globalSubtitles
                                ? Icons.layers_rounded
                                : Icons.layers_clear_rounded,
                            color: !hasSubtitle
                                ? cs.onSurface.withValues(alpha: 0.38)
                                : (globalSubtitles
                                      ? cs.primary
                                      : cs.onSurfaceVariant),
                          ),
                          title: Text(
                            i18n.tr('subtitle_global_display'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: !hasSubtitle
                                  ? cs.onSurface.withValues(alpha: 0.38)
                                  : null,
                            ),
                          ),
                          value: globalSubtitles,
                          onChanged: !hasSubtitle
                              ? null
                              : (_) {
                                  AppInteractionFeedback.trigger(
                                    AppInteractionFeedbackType.selection,
                                  );
                                  widget.onToggleGlobalSubtitle?.call();
                                },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Import Subtitle Card
                  Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          key: const ValueKey('subtitle_select_tile'),
                          enabled: selectionEnabled,
                          leading: _subtitleBusy
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Icon(
                                  Icons.subtitles_rounded,
                                  color: selectionEnabled
                                      ? cs.primary
                                      : cs.onSurface.withValues(alpha: 0.38),
                                ),
                          title: Text(
                            i18n.tr('subtitle_select'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: selectionEnabled
                                  ? null
                                  : cs.onSurface.withValues(alpha: 0.38),
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                          ),
                          onTap: selectionEnabled
                              ? () => _pickExistingSubtitle(subtitles)
                              : null,
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 16,
                          endIndent: 16,
                          color: cs.outlineVariant.withValues(alpha: 0.35),
                        ),
                        ListTile(
                          key: const ValueKey('subtitle_import_tile'),
                          enabled: importEnabled,
                          leading: _importingSubtitleFile
                              ? SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: cs.primary,
                                  ),
                                )
                              : Icon(
                                  Icons.upload_file_rounded,
                                  color: importEnabled
                                      ? cs.primary
                                      : cs.onSurface.withValues(alpha: 0.38),
                                ),
                          title: Text(
                            i18n.tr('import_subtitle'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: importEnabled
                                  ? null
                                  : cs.onSurface.withValues(alpha: 0.38),
                            ),
                          ),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: importEnabled
                                ? null
                                : cs.onSurface.withValues(alpha: 0.38),
                          ),
                          onTap: !importEnabled
                              ? null
                              : () => _pickSubtitleFile(context, subtitles),
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 16,
                          endIndent: 16,
                          color: cs.outlineVariant.withValues(alpha: 0.35),
                        ),
                        ListTile(
                          key: const ValueKey('subtitle_transcribe_tile'),
                          enabled: generateEnabled,
                          leading: Icon(
                            Icons.graphic_eq_rounded,
                            color: generateEnabled
                                ? cs.primary
                                : cs.onSurface.withValues(alpha: 0.38),
                          ),
                          title: Text(
                            i18n.tr('subtitle_transcribe_generate'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: generateEnabled
                                  ? null
                                  : cs.onSurface.withValues(alpha: 0.38),
                            ),
                          ),
                          trailing: _checkingModelKey == 'transcribe'
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.chevron_right_rounded,
                                  size: 20,
                                  color: generateEnabled
                                      ? null
                                      : cs.onSurface.withValues(alpha: 0.38),
                                ),
                          onTap: generateEnabled
                              ? () => _transcribeAudio(subtitles)
                              : null,
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 16,
                          endIndent: 16,
                          color: cs.outlineVariant.withValues(alpha: 0.35),
                        ),
                        ListTile(
                          key: const ValueKey('subtitle_script_tile'),
                          enabled: generateEnabled,
                          leading: Icon(
                            Icons.auto_awesome_rounded,
                            color: generateEnabled
                                ? cs.primary
                                : cs.onSurface.withValues(alpha: 0.38),
                          ),
                          title: Text(
                            i18n.tr('subtitle_script_generate'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: generateEnabled
                                  ? null
                                  : cs.onSurface.withValues(alpha: 0.38),
                            ),
                          ),
                          trailing: _checkingModelKey == 'script'
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.chevron_right_rounded,
                                  size: 20,
                                  color: generateEnabled
                                      ? null
                                      : cs.onSurface.withValues(alpha: 0.38),
                                ),
                          onTap: generateEnabled ? _pickScriptFile : null,
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 16,
                          endIndent: 16,
                          color: cs.outlineVariant.withValues(alpha: 0.35),
                        ),
                        ListTile(
                          key: const ValueKey('subtitle_translate_tile'),
                          enabled: translateEnabled,
                          leading: Icon(
                            Icons.translate_rounded,
                            color: translateEnabled
                                ? cs.primary
                                : cs.onSurface.withValues(alpha: 0.38),
                          ),
                          title: Text(
                            i18n.tr('subtitle_translate'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: translateEnabled
                                  ? null
                                  : cs.onSurface.withValues(alpha: 0.38),
                            ),
                          ),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: translateEnabled
                                ? null
                                : cs.onSurface.withValues(alpha: 0.38),
                          ),
                          onTap: translateEnabled
                              ? () => _translateSubtitle(subtitleLanguage)
                              : null,
                        ),
                        if (generationJob != null) ...[
                          Divider(
                            height: 1,
                            thickness: 0.5,
                            indent: 16,
                            endIndent: 16,
                            color: cs.outlineVariant.withValues(alpha: 0.35),
                          ),
                          ListTile(
                            key: const ValueKey(
                              'subtitle_generation_status_tile',
                            ),
                            leading: const Icon(Icons.pending_actions_rounded),
                            title: Text(i18n.tr('subtitle_generation_status')),
                            subtitle: Text(switch (generationJob.status) {
                              SubtitleGenerationStatus.completed => i18n.tr(
                                'subtitle_generation_ready',
                              ),
                              SubtitleGenerationStatus.noMatch => i18n.tr(
                                generationJob.kind ==
                                        SubtitleDraftKind.transcription
                                    ? 'subtitle_no_speech_detected'
                                    : 'subtitle_no_reliable_match',
                              ),
                              SubtitleGenerationStatus.cancelled => i18n.tr(
                                'subtitle_task_cancelled',
                              ),
                              SubtitleGenerationStatus.failed => i18n.tr(
                                'subtitle_task_failed',
                              ),
                              SubtitleGenerationStatus.running =>
                                generationJob.progress?.message.isNotEmpty ==
                                        true
                                    ? generationJob.progress!.message
                                    : i18n.tr('subtitle_generating'),
                            }),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => _showGeneration(subtitles),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  ListTile(
                    key: const ValueKey('subtitle_edit_tile'),
                    enabled: canEditSubtitle,
                    tileColor: cs.surfaceContainerHighest.withValues(
                      alpha: 0.45,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    leading: Icon(
                      Icons.edit_note_rounded,
                      color: canEditSubtitle
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.38),
                    ),
                    title: Text(i18n.tr('subtitle_edit')),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: !canEditSubtitle
                        ? null
                        : () => Navigator.of(context).push(
                            buildAppPageRoute<void>(
                              context: context,
                              child: SubtitleEditorPage(trackPath: trackPath),
                            ),
                          ),
                  ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Subtitle Sync Controls Card
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.more_time_rounded,
                                  size: 20,
                                  color: !hasSubtitle
                                      ? cs.onSurface.withValues(alpha: 0.38)
                                      : cs.primary,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    i18n.tr('subtitle_sync'),
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: !hasSubtitle
                                          ? cs.onSurface.withValues(alpha: 0.38)
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: (!hasSubtitle || isOffsetZero)
                                    ? cs.surfaceContainerHighest
                                    : cs.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                i18n.tr('subtitle_offset_current', {
                                  'offset': _formatOffset(activeOffset),
                                }),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: !hasSubtitle
                                      ? cs.onSurface.withValues(alpha: 0.38)
                                      : (isOffsetZero
                                            ? cs.onSurfaceVariant
                                            : cs.onPrimaryContainer),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // Five Sync Buttons: [-0.5s] [-0.1s] [重置] [+0.1s] [+0.5s]
                        Row(
                          children: [
                            Expanded(
                              child: _SyncControlButton(
                                label: '-0.5s',
                                onPressed: !hasSubtitle
                                    ? null
                                    : () => _adjustOffset(subtitles, -500),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SyncControlButton(
                                label: '-0.1s',
                                onPressed: !hasSubtitle
                                    ? null
                                    : () => _adjustOffset(subtitles, -100),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SyncControlButton(
                                label: i18n.tr('subtitle_reset'),
                                isReset: true,
                                onPressed: (!hasSubtitle || isOffsetZero)
                                    ? null
                                    : () => _resetOffset(subtitles),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SyncControlButton(
                                label: '+0.1s',
                                onPressed: !hasSubtitle
                                    ? null
                                    : () => _adjustOffset(subtitles, 100),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SyncControlButton(
                                label: '+0.5s',
                                onPressed: !hasSubtitle
                                    ? null
                                    : () => _adjustOffset(subtitles, 500),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ).withWindowsSmoothScroll(),
          ),
        );
        final screenHeight = MediaQuery.sizeOf(context).height;
        final availableHeight =
            (screenHeight - MediaQuery.viewPaddingOf(context).vertical).clamp(
              0.0,
              screenHeight,
            );
        final effectiveSelectionHeight =
            !selectingFiles || _selectionMenuHeight == null
            ? null
            : availableHeight > 0
            ? _selectionMenuHeight!.clamp(0.0, availableHeight).toDouble()
            : _selectionMenuHeight;
        return PopScope(
          canPop: !selectingFiles,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && selectingFiles && !_subtitleBusy) {
              setState(() {
                _scriptFiles = null;
                _subtitleFiles = null;
              });
            }
          },
          child: SizedBox(
            key: _menuKey,
            height: effectiveSelectionHeight,
            child: AppMenuContentTransition(
              primary: menu,
              secondary: selectionContent,
            ),
          ),
        );
      },
    );
  }
}

class _SyncControlButton extends StatelessWidget {
  const _SyncControlButton({
    required this.label,
    required this.onPressed,
    this.isReset = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool isReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final enabled = onPressed != null;
    final isWindows = theme.platform == TargetPlatform.windows;
    final style = OutlinedButton.styleFrom(
      // Match the visible surface to the existing 48 px desktop tap target.
      minimumSize: Size(0, isWindows ? 48 : 42),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      tapTargetSize: isWindows ? MaterialTapTargetSize.shrinkWrap : null,
      shape: const StadiumBorder(),
      side: BorderSide(
        color: enabled
            ? (isReset
                  ? cs.primary.withValues(alpha: 0.6)
                  : cs.outlineVariant.withValues(alpha: 0.5))
            : cs.outlineVariant.withValues(alpha: 0.2),
        width: isReset && enabled ? 1.0 : 0.8,
      ),
      backgroundColor: isReset && enabled
          ? cs.primaryContainer.withValues(alpha: 0.35)
          : Colors.transparent,
      foregroundColor: enabled
          ? (isReset ? cs.primary : cs.onSurface)
          : cs.onSurface.withValues(alpha: 0.38),
    );

    return AppPillButton.outlined(
      style: style,
      onPressed: onPressed,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(
            fontSize: isReset ? 12 : 11,
            fontWeight: isReset ? FontWeight.bold : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
