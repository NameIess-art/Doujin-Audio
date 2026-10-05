import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_transitions.dart';
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
  bool _importing = false;
  SubtitleModelSpec? _checkingModel;

  @override
  void initState() {
    super.initState();
    final trackPath = widget.session.currentTrackPath;
    if (trackPath.isNotEmpty) {
      final subtitles = ref.read(playbackSubtitleServiceProvider);
      if (!subtitles.hasResult(trackPath)) {
        unawaited(subtitles.load(trackPath));
      }
    }
  }

  String _formatOffset(Duration offset) {
    final seconds = offset.inMilliseconds / 1000.0;
    if (offset == Duration.zero) return '0.0s';
    final sign = seconds > 0 ? '+' : '';
    return '$sign${seconds.toStringAsFixed(1)}s';
  }

  Future<void> _pickSubtitleFile(
    BuildContext context,
    PlaybackSubtitleService subtitles,
  ) async {
    if (_importing ||
        subtitles.generationJob?.status == SubtitleGenerationStatus.running) {
      return;
    }
    setState(() => _importing = true);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final trackPath = widget.session.currentTrackPath;

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
      final overwrite = await _confirmSubtitleOverwrite(subtitles);
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
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _showGeneration(PlaybackSubtitleService subtitles) async {
    if (subtitles.generationJob == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => SubtitleGenerationDialog(service: subtitles),
    );
  }

  Future<void> _pickScriptFile(PlaybackSubtitleService subtitles) async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      final target = ref
          .read(libraryFacadeProvider)
          .audioDetailTargetForPath(widget.session.currentTrackPath);
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
      setState(() => _importing = false);
      if (files.isEmpty) {
        showAppSnackBar(
          context,
          i18n.tr('script_text_not_found'),
          tone: AppFeedbackTone.warning,
          icon: Icons.info_outline_rounded,
        );
        return;
      }
      final selected = await showDialog<WorkTextFile>(
        context: context,
        builder: (dialogContext) {
          final theme = Theme.of(dialogContext);
          final cs = theme.colorScheme;
          return SimpleDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.dialog),
              side: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.35),
                width: 0.5,
              ),
            ),
            backgroundColor: cs.surfaceContainerHigh,
            surfaceTintColor: Colors.transparent,
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: cs.primaryContainer.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.text_snippet_rounded,
                        color: cs.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i18n.tr('subtitle_script_generate'),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            i18n.tr('subtitle_script_hint'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      visualDensity: VisualDensity.compact,
                      color: cs.onSurfaceVariant,
                      tooltip: i18n.tr('cancel'),
                      onPressed: () => Navigator.pop(dialogContext),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Divider(
                  height: 1,
                  thickness: 0.5,
                  color: cs.outlineVariant.withValues(alpha: 0.35),
                ),
              ],
            ),
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.45,
                ),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    dialogContext,
                  ).copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                      for (final file in files) () {
                        final displayPath = file.relativePath.isEmpty
                            ? file.name
                            : file.relativePath;
                        final ext = path.extension(file.name).toLowerCase();
                        final isMd = ext == '.md';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Material(
                            color: cs.surfaceContainerHighest.withValues(
                              alpha: 0.4,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: cs.outlineVariant.withValues(
                                  alpha: 0.3,
                                ),
                                width: 0.5,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              splashColor: cs.primary.withValues(alpha: 0.16),
                              hoverColor: cs.primary.withValues(alpha: 0.08),
                              onTap: () => Navigator.pop(dialogContext, file),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 11,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: isMd
                                            ? cs.secondaryContainer.withValues(
                                                alpha: 0.7,
                                              )
                                            : cs.tertiaryContainer.withValues(
                                                alpha: 0.7,
                                              ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Center(
                                        child: Text(
                                          isMd ? 'MD' : 'TXT',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            color: isMd
                                                ? cs.onSecondaryContainer
                                                : cs.onTertiaryContainer,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        displayPath,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: cs.onSurface,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.arrow_forward_ios_rounded,
                                      size: 13,
                                      color: cs.onSurfaceVariant.withValues(
                                        alpha: 0.6,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }(),
                    ],
                  ),
                ),
              ),
            ),
          ],
          );
        },
      );
      if (!mounted || selected == null) return;
      final selectedPath = selected.path;
      if (path.extension(selected.name).toLowerCase() == '.txt' &&
          await subtitles.isTimedSubtitleFile(selectedPath)) {
        if (!mounted) return;
        await _pickTimedScript(
          subtitles,
          selectedPath,
          fileName: selected.name,
        );
        return;
      }
      if (!mounted) return;
      if (subtitles.hasKnownSubtitle(widget.session.currentTrackPath)) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(i18n.tr('subtitle_script_existing_title')),
            content: Text(i18n.tr('subtitle_script_existing_hint')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(i18n.tr('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(i18n.tr('subtitle_script_continue')),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
      }
      if (!mounted) return;
      if (!await _confirmModelDownload(SubtitleModelStore.japaneseCtc)) return;
      final settings = ref.read(subtitleSettingsProvider.notifier);
      final sessionId = widget.session.id;
      if (subtitles.startScriptGeneration(
        widget.session.currentTrackPath,
        selectedPath,
        onApplied: () => settings.ensureSubtitlesEnabled(sessionId),
      )) {
        await _showGeneration(subtitles);
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
    required String fileName,
  }) async {
    setState(() => _importing = true);
    try {
      final overwrite = await _confirmSubtitleOverwrite(subtitles);
      if (overwrite == null) return;
      final imported = await subtitles.importSubtitle(
        widget.session.currentTrackPath,
        selectedPath,
        fileName: fileName,
        overwrite: overwrite,
      );
      if (!mounted) return;
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      if (imported != null) {
        ref
            .read(subtitleSettingsProvider.notifier)
            .ensureSubtitlesEnabled(widget.session.id);
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
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<bool?> _confirmSubtitleOverwrite(
    PlaybackSubtitleService subtitles,
  ) async {
    final exists = await subtitles.hasLocalSubtitleFile(
      widget.session.currentTrackPath,
    );
    if (!mounted) return null;
    if (!exists) return false;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(i18n.tr('subtitle_import_overwrite_title')),
        content: Text(i18n.tr('subtitle_import_overwrite_hint')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(i18n.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(i18n.tr('subtitle_import_overwrite')),
          ),
        ],
      ),
    );
    return confirmed == true ? true : null;
  }

  Future<void> _translateSubtitle(SubtitleLanguage language) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    if (language == SubtitleLanguage.unknown) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(i18n.tr('subtitle_source_confirm_japanese')),
          content: Text(i18n.tr('subtitle_source_confirm_japanese_hint')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(i18n.tr('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(i18n.tr('confirm')),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    final targetLanguage = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final cs = theme.colorScheme;
        return SimpleDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.dialog),
            side: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.35),
              width: 0.5,
            ),
          ),
          backgroundColor: cs.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.translate_rounded,
                      color: cs.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          i18n.tr('subtitle_choose_language'),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          i18n.tr('subtitle_translate_hint'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    visualDensity: VisualDensity.compact,
                    color: cs.onSurfaceVariant,
                    tooltip: i18n.tr('cancel'),
                    onPressed: () => Navigator.pop(dialogContext),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(
                height: 1,
                thickness: 0.5,
                color: cs.outlineVariant.withValues(alpha: 0.35),
              ),
            ],
          ),
          children: [
            () {
              final isZh = i18n.locale.languageCode == 'zh';
              final isEn = i18n.locale.languageCode == 'en';
              final zhSubtitle = isZh
                  ? 'Chinese (Simplified)'
                  : '中文（简体）';
              final enSubtitle = isEn
                  ? '英语'
                  : 'English';
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Material(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: cs.outlineVariant.withValues(alpha: 0.3),
                          width: 0.5,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        splashColor: cs.primary.withValues(alpha: 0.16),
                        hoverColor: cs.primary.withValues(alpha: 0.08),
                        onTap: () => Navigator.pop(dialogContext, 'zh'),
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
                                  color: cs.primary.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Center(
                                  child: Text(
                                    'ZH',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: cs.primary,
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
                                      i18n.tr('subtitle_language_zh'),
                                      style: theme.textTheme.bodyLarge?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      zhSubtitle,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.arrow_forward_ios_rounded,
                                size: 14,
                                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Material(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: cs.outlineVariant.withValues(alpha: 0.3),
                          width: 0.5,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        splashColor: cs.secondary.withValues(alpha: 0.16),
                        hoverColor: cs.secondary.withValues(alpha: 0.08),
                        onTap: () => Navigator.pop(dialogContext, 'en'),
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
                                  color: cs.secondary.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Center(
                                  child: Text(
                                    'EN',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: cs.secondary,
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
                                      i18n.tr('subtitle_language_en'),
                                      style: theme.textTheme.bodyLarge?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      enSubtitle,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.arrow_forward_ios_rounded,
                                size: 14,
                                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }(),
          ],
        );
      },
    );
    if (!mounted || targetLanguage == null) return;
    if (!await _confirmModelDownload(SubtitleModelStore.translation)) return;
    final subtitles = ref.read(playbackSubtitleServiceProvider);
    final settings = ref.read(subtitleSettingsProvider.notifier);
    final sessionId = widget.session.id;
    if (subtitles.startTranslationGeneration(
      widget.session.currentTrackPath,
      targetLanguage,
      sourceJapaneseConfirmed: language == SubtitleLanguage.unknown,
      onApplied: () => settings.ensureSubtitlesEnabled(sessionId),
    )) {
      await _showGeneration(subtitles);
    }
  }

  Future<bool> _confirmModelDownload(SubtitleModelSpec spec) async {
    final store = ref.read(playbackSubtitleServiceProvider).modelStore;
    setState(() => _checkingModel = spec);
    late final SubtitleModelStatus status;
    try {
      status = await store.status(spec);
    } finally {
      if (mounted) setState(() => _checkingModel = null);
    }
    if (!mounted) return false;
    if (status.ready) return true;
    final downloaded = await showDialog<bool>(
      context: context,
      builder: (_) =>
          SubtitleModelDownloadDialog(store: store, spec: spec, status: status),
    );
    return mounted && downloaded == true;
  }

  void _adjustOffset(PlaybackSubtitleService subtitles, int deltaMs) {
    final trackPath = widget.session.currentTrackPath;
    final currentOffset = subtitles.getOffset(trackPath);
    final nextMs = (currentOffset.inMilliseconds + deltaMs).clamp(
      -60000,
      60000,
    );
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    unawaited(
      subtitles.setTrackOffset(trackPath, Duration(milliseconds: nextMs)),
    );
  }

  void _resetOffset(PlaybackSubtitleService subtitles) {
    final trackPath = widget.session.currentTrackPath;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    unawaited(subtitles.setTrackOffset(trackPath, Duration.zero));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    final subtitles = ref.watch(playbackSubtitleServiceProvider);
    final subtitleSettings = ref.watch(subtitleSettingsProvider);

    final trackPath = widget.session.currentTrackPath;
    final showSubtitles = subtitleSettings.isShowEnabled(widget.session.id);
    final globalSubtitles = subtitleSettings.isGlobalEnabled(widget.session.id);

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
            !(generationBusy && generationJob?.trackPath == trackPath);
        final generateEnabled =
            importEnabled &&
            !generationBusy &&
            _checkingModel == null &&
            generationUnavailableKey == null;
        final translateEnabled =
            generateEnabled &&
            activeTrack?.cues.isNotEmpty == true &&
            subtitleLanguage != SubtitleLanguage.other;
        final isOffsetZero = activeOffset == Duration.zero;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Title Row
                  Row(
                    children: [
                      Icon(
                        Icons.subtitles_rounded,
                        color: cs.primary,
                        size: 24,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        i18n.tr('subtitles'),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Switches Card
                  Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
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
                            showSubtitles
                                ? i18n.tr('turn_off_subtitle')
                                : i18n.tr('turn_on_subtitle'),
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
                                  widget.onToggleGlobalSubtitle?.call();
                                },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Import Subtitle Card
                  Container(
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
                          key: const ValueKey('subtitle_import_tile'),
                          enabled: importEnabled,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          leading: _importing
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
                          subtitle: Text(
                            activeTrack != null
                                ? i18n.tr('subtitle_loaded_file', {
                                    'file': path.basename(
                                      activeTrack.sourcePath,
                                    ),
                                  })
                                : i18n.tr('import_subtitle_hint'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: importEnabled
                                  ? cs.onSurfaceVariant
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
                          key: const ValueKey('subtitle_script_tile'),
                          enabled: generateEnabled,
                          leading: Icon(
                            Icons.text_snippet_rounded,
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
                          subtitle: Text(
                            i18n.tr(
                              generationUnavailableKey ??
                                  'subtitle_script_hint',
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: generateEnabled
                                  ? cs.onSurfaceVariant
                                  : cs.onSurface.withValues(alpha: 0.38),
                            ),
                          ),
                          trailing:
                              _checkingModel?.name ==
                                  SubtitleModelStore.japaneseCtc.name
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
                              ? () => _pickScriptFile(subtitles)
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
                          subtitle: Text(
                            i18n.tr(
                              generationUnavailableKey ??
                                  (subtitleLanguage == SubtitleLanguage.other
                                      ? 'subtitle_non_japanese'
                                      : 'subtitle_translate_hint'),
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: translateEnabled
                                  ? cs.onSurfaceVariant
                                  : cs.onSurface.withValues(alpha: 0.38),
                            ),
                          ),
                          trailing:
                              _checkingModel?.name ==
                                  SubtitleModelStore.translation.name
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
                                  color: translateEnabled
                                      ? null
                                      : cs.onSurface.withValues(alpha: 0.38),
                                ),
                          onTap: translateEnabled
                              ? () => _translateSubtitle(subtitleLanguage)
                              : null,
                        ),
                        if (generationJob != null)
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
                                'subtitle_no_reliable_match',
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
                        Row(
                          children: [
                            Icon(
                              Icons.sync_rounded,
                              size: 20,
                              color: !hasSubtitle
                                  ? cs.onSurface.withValues(alpha: 0.38)
                                  : cs.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              i18n.tr('subtitle_sync'),
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: !hasSubtitle
                                    ? cs.onSurface.withValues(alpha: 0.38)
                                    : null,
                              ),
                            ),
                            const Spacer(),
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
    final cs = Theme.of(context).colorScheme;
    final enabled = onPressed != null;

    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
      ),
      onPressed: onPressed,
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          fontSize: isReset ? 12 : 11,
          fontWeight: isReset ? FontWeight.bold : FontWeight.w600,
        ),
      ),
    );
  }
}
