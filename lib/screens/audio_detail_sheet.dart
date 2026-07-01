import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../services/audio_state_services.dart';
import '../services/audio_detail_repository.dart';
import '../services/ui_operation_service.dart';
import '../services/path_display.dart';
import '../widgets/app_feedback.dart';
import '../widgets/async_cover_image.dart';
import '../widgets/operation_feedback.dart';
import 'dlsite_metadata_review_page.dart';
import '../widgets/app_transitions.dart';

const _multiValueSeparator = '\uFF0C';

Future<void> showAudioDetailSheet(
  BuildContext context,
  AudioDetailTarget target,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => AudioDetailSheet(target: target),
  );
}

class AudioDetailSheet extends StatefulWidget {
  const AudioDetailSheet({super.key, required this.target});

  final AudioDetailTarget target;

  @override
  State<AudioDetailSheet> createState() => _AudioDetailSheetState();
}

class _AudioDetailSheetState extends State<AudioDetailSheet> {
  late AudioDetailTarget _target = widget.target;
  AudioDetail? _detail;
  Object? _loadError;
  bool _loading = true;
  bool _runningAction = false;
  _AudioDetailField? _savingField;

  UiOperationScope get _operationScope => UiOperationScope.audioDetail(
    '${_target.targetType.dbValue}|${_target.targetPath}',
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final result = await UiOperationService.instance
          .run<AudioDetailLoadResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_title',
            task: (_) => context.read<AudioProvider>().loadAudioDetail(_target),
          );
      if (!mounted) return;
      setState(() {
        _detail = result.detail;
        _loading = false;
      });
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

    final i18n = context.read<AppLanguageProvider>();
    final initialValue = field.isMulti
        ? field.readList(detail).join(_multiValueSeparator)
        : field.readText(detail);
    final controller = TextEditingController(
      text: field == _AudioDetailField.rjCode && initialValue.trim().isEmpty
          ? 'RJ'
          : initialValue,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            i18n.tr('audio_detail_edit_title', {
              'name': field.label(i18n, detail),
            }),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: field.isMulti ? 3 : 1,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: field.isMulti
                  ? i18n.tr('audio_detail_multi_hint')
                  : null,
            ),
            onSubmitted: (_) => Navigator.of(context).pop(controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(i18n.tr('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: Text(MaterialLocalizations.of(context).saveButtonLabel),
            ),
          ],
        );
      },
    );
    controller.dispose();
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
      final result = await UiOperationService.instance
          .run<AudioDetailRenameResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_rename_folder_from_title',
            task: (_) => context
                .read<AudioProvider>()
                .renameAudioDetailTargetToName(detail, targetName),
          );
      if (!mounted) return;
      setState(() {
        _target = result.detail.target;
        _detail = result.detail;
        _savingField = null;
        _runningAction = false;
      });
      final i18n = context.read<AppLanguageProvider>();
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
        context.read<AppLanguageProvider>().tr('audio_detail_rename_failed'),
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
      final result = await UiOperationService.instance
          .run<AudioDetailSaveResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_save_failed',
            task: (_) =>
                context.read<AudioProvider>().saveAudioDetail(nextDetail),
          );
      if (!mounted) return;
      setState(() {
        _detail = result.detail;
        _savingField = null;
      });
      final i18n = context.read<AppLanguageProvider>();
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _savingField = null;
      });
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  Future<void> _confirmFetchInfo(AudioDetail detail) async {
    final i18n = context.read<AppLanguageProvider>();
    final query = context.read<AudioProvider>().buildDlsiteMetadataQuery(
      detail,
    );
    if (!query.hasQuery) {
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_fetch_missing_query'),
        tone: AppFeedbackTone.warning,
      );
      return;
    }
    final scope = await showDialog<_AudioDetailFetchScope>(
      context: context,
      builder: (context) => const _AudioDetailFetchScopeDialog(),
    );
    if (scope == null || !mounted) return;

    final result = await Navigator.of(context).push<DlsiteMetadataReviewResult>(
      buildAppPageRoute(
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
    final i18n = context.read<AppLanguageProvider>();
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
      final result = await UiOperationService.instance
          .run<AudioDetailRenameResult>(
            scope: _operationScope,
            labelKey: 'audio_detail_rename_folder_from_title',
            task: (_) =>
                context.read<AudioProvider>().renameAudioDetailTarget(detail),
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
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(i18n.tr('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);
    final detail = _detail;

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
                      child: FilledButton.tonalIcon(
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
                      child: FilledButton.tonalIcon(
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
                _FolderCoverSelector(folderPath: _target.targetPath),
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
                _AudioDetailField.salesCount,
                _AudioDetailField.rating,
              ].map(
                (field) => _AudioDetailRow(
                  label: field.label(i18n, detail),
                  values: field.readValues(detail),
                  labelStyle: labelStyle,
                  busy: _savingField == field,
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

class _FolderCoverSelector extends StatefulWidget {
  const _FolderCoverSelector({required this.folderPath});

  final String folderPath;

  @override
  State<_FolderCoverSelector> createState() => _FolderCoverSelectorState();
}

class _FolderCoverSelectorState extends State<_FolderCoverSelector> {
  static const Duration _commitDelay = Duration(seconds: 1);

  PageController? _pageController;
  List<String> _images = const <String>[];
  bool _loading = true;
  bool _saving = false;
  Object? _error;
  int _currentIndex = 0;
  Timer? _commitTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _commitTimer?.cancel();
    _pageController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final provider = context.read<AudioProvider>();
      final images = await provider.discoverImagesInFolder(widget.folderPath);
      if (!mounted) return;
      if (images.isEmpty) {
        setState(() {
          _images = const <String>[];
          _loading = false;
        });
        return;
      }

      final currentCover = await provider.coverPathFutureForFolder(
        widget.folderPath,
      );
      if (!mounted) return;
      var initialIndex = 0;
      if (currentCover != null) {
        final foundIndex = images.indexOf(currentCover);
        if (foundIndex >= 0) {
          initialIndex = foundIndex;
        }
      }
      final controller = PageController(initialPage: initialIndex);
      _pageController?.dispose();
      setState(() {
        _images = images;
        _currentIndex = initialIndex;
        _pageController = controller;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _handlePageChanged(int index) {
    if (index < 0 || index >= _images.length) return;
    setState(() {
      _currentIndex = index;
    });
    _commitTimer?.cancel();
    _commitTimer = Timer(_commitDelay, () {
      unawaited(_commitSelection(index));
    });
  }

  Future<void> _commitSelection(int index) async {
    if (!mounted || index < 0 || index >= _images.length) return;
    setState(() {
      _saving = true;
    });
    try {
      await context.read<AudioProvider>().setFolderManualCover(
        widget.folderPath,
        _images[index],
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Widget _buildCoverReveal(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 650),
      reverseDuration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);

    if (_loading) {
      return _buildCoverReveal(
        Column(
          key: const ValueKey('audio_detail_cover_loading'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(i18n.tr('audio_detail_cover_image'), style: labelStyle),
            const SizedBox(height: 10),
            Card(
              key: const ValueKey('audio_detail_cover_placeholder'),
              margin: EdgeInsets.zero,
              color: cs.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: const AspectRatio(
                aspectRatio: 1.45,
                child: SizedBox.expand(),
              ),
            ),
          ],
        ),
      );
    }
    if (_error != null || _images.isEmpty || _pageController == null) {
      return const SizedBox.shrink();
    }
    final coverCacheWidth = coverCacheWidthForResolution(
      context.select<AudioProvider, CoverImageResolution>(
        (provider) => provider.coverImageResolution,
      ),
    );

    final content = Column(
      key: const ValueKey('audio_detail_cover_loaded'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(i18n.tr('audio_detail_cover_image'), style: labelStyle),
        const SizedBox(height: 10),
        ClipRRect(
          key: const ValueKey('audio_detail_cover_content'),
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 1.45,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest),
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _images.length,
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (context, index) {
                      return RetryingFileImage(
                        path: _images[index],
                        fit: BoxFit.cover,
                        cacheWidth: coverCacheWidth,
                        useDefaultCacheWidth: coverCacheWidth != null,
                        fallbackBuilder: (_) => CoverFallbackArtwork(
                          seed: _images[index],
                          icon: Icons.image_not_supported_rounded,
                          iconSize: 42,
                        ),
                      );
                    },
                  ),
                ),
                if (!const bool.fromEnvironment('dart.library.html') &&
                    Platform.isWindows &&
                    _images.length > 1)
                  Positioned.fill(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: IconButton.filledTonal(
                            onPressed: () {
                              _pageController?.previousPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOutCubic,
                              );
                            },
                            icon: const Icon(
                              Icons.chevron_left_rounded,
                              size: 32,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: IconButton.filledTonal(
                            onPressed: () {
                              _pageController?.nextPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOutCubic,
                              );
                            },
                            icon: const Icon(
                              Icons.chevron_right_rounded,
                              size: 32,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: _saving ? 1 : 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            '${_currentIndex + 1} / ${_images.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            i18n.tr('audio_detail_cover_swipe_hint'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    return _buildCoverReveal(content);
  }
}

class _AudioDetailRow extends StatelessWidget {
  const _AudioDetailRow({
    required this.label,
    required this.values,
    required this.labelStyle,
    required this.busy,
    required this.onTap,
    this.isCapsule = false,
    this.onCopy,
  });

  final String label;
  final List<String> values;
  final TextStyle? labelStyle;
  final bool busy;
  final VoidCallback onTap;
  final bool isCapsule;
  final void Function(String)? onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final emptyText = context.read<AppLanguageProvider>().tr('audio_detail_empty');
    final displayValues = values.isEmpty || (values.length == 1 && values.first.isEmpty) 
        ? [emptyText]
        : values;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: labelStyle),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  onPressed: onTap,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: Size.zero,
                  ),
                  icon: Icon(Icons.edit_rounded, color: cs.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (isCapsule)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: displayValues.map((v) => _DetailCapsule(
                text: v,
                onLongPress: onCopy != null && v != emptyText ? () => onCopy!(v) : null,
              )).toList(),
            )
          else
            Text(
              displayValues.join('\uFF0C'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: displayValues.first == emptyText ? cs.onSurfaceVariant : cs.onSurface,
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailCapsule extends StatelessWidget {
  const _DetailCapsule({required this.text, this.onLongPress});

  final String text;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _copyText(BuildContext context, String value) async {
  final text = value.trim();
  if (text.isEmpty) {
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) {
    return;
  }
  final i18n = context.read<AppLanguageProvider>();
  showAppSnackBar(
    context,
    i18n.tr('copied_to_clipboard', {'value': text}),
    tone: AppFeedbackTone.success,
    icon: Icons.copy_rounded,
  );
}

enum _AudioDetailFetchScope { all, missing }

class _AudioDetailFetchScopeDialog extends StatelessWidget {
  const _AudioDetailFetchScopeDialog();

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.download_rounded, color: cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    i18n.tr('audio_detail_fetch_scope_title'),
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              tileColor: cs.surfaceContainer,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.select_all_rounded),
              title: Text(i18n.tr('batch_metadata_all')),
              onTap: () =>
                  Navigator.of(context).pop(_AudioDetailFetchScope.all),
            ),
            const SizedBox(height: 4),
            ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              tileColor: cs.surfaceContainer,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.playlist_add_check_rounded),
              title: Text(i18n.tr('metadata_scope_missing')),
              onTap: () =>
                  Navigator.of(context).pop(_AudioDetailFetchScope.missing),
            ),
          ],
        ),
      ),
    );
  }
}

enum _AudioDetailField {
  targetName,
  rjCode,
  workTitle,
  circleName,
  voiceActors,
  tags,
  releaseDate,
  salesCount,
  rating;

  bool get isMulti =>
      this == _AudioDetailField.voiceActors || this == _AudioDetailField.tags;

  String label(AppLanguageProvider i18n, AudioDetail detail) {
    return switch (this) {
      _AudioDetailField.targetName =>
        detail.target.isLibraryRootFolder
            ? i18n.tr('audio_detail_folder_name')
            : i18n.tr('audio_detail_file_name'),
      _AudioDetailField.rjCode => i18n.tr('audio_detail_rj_code'),
      _AudioDetailField.workTitle => i18n.tr('audio_detail_work_title'),
      _AudioDetailField.circleName => i18n.tr('audio_detail_circle_name'),
      _AudioDetailField.voiceActors => i18n.tr('audio_detail_voice_actors'),
      _AudioDetailField.tags => i18n.tr('audio_detail_tags'),
      _AudioDetailField.releaseDate => i18n.tr('audio_detail_release_date'),
      _AudioDetailField.salesCount => i18n.tr('audio_detail_sales_count'),
      _AudioDetailField.rating => i18n.tr('audio_detail_rating'),
    };
  }

  String readText(AudioDetail detail) {
    return switch (this) {
      _AudioDetailField.targetName => _targetDisplayName(detail.target),
      _AudioDetailField.rjCode => detail.rjCode,
      _AudioDetailField.workTitle => detail.workTitle,
      _AudioDetailField.circleName => detail.circleName,
      _AudioDetailField.voiceActors => detail.voiceActors.join(
        _multiValueSeparator,
      ),
      _AudioDetailField.tags => detail.tags.join(_multiValueSeparator),
      _AudioDetailField.releaseDate => _formatDateValue(detail.releaseDate),
      _AudioDetailField.salesCount => detail.salesCount?.toString() ?? '',
      _AudioDetailField.rating => _formatRatingValue(detail.rating),
    };
  }

  List<String> readList(AudioDetail detail) {
    return switch (this) {
      _AudioDetailField.voiceActors => detail.voiceActors,
      _AudioDetailField.tags => detail.tags,
      _ => const <String>[],
    };
  }

  List<String> readValues(AudioDetail detail) {
    return isMulti ? readList(detail) : [readText(detail)];
  }

  AudioDetail apply(AudioDetail detail, String rawValue) {
    final trimmed = rawValue.trim();
    return switch (this) {
      _AudioDetailField.targetName => detail,
      _AudioDetailField.rjCode => detail.copyWith(
        rjCode: trimmed.toUpperCase(),
      ),
      _AudioDetailField.workTitle => detail.copyWith(workTitle: trimmed),
      _AudioDetailField.circleName => detail.copyWith(circleName: trimmed),
      _AudioDetailField.voiceActors => detail.copyWith(
        voiceActors: _splitMultiValue(rawValue),
      ),
      _AudioDetailField.tags => detail.copyWith(
        tags: _splitMultiValue(rawValue),
      ),
      _AudioDetailField.releaseDate => detail.copyWith(
        releaseDate: _parseDateValue(trimmed),
      ),
      _AudioDetailField.salesCount => detail.copyWith(
        salesCount: trimmed.isEmpty ? null : int.tryParse(trimmed),
      ),
      _AudioDetailField.rating => detail.copyWith(
        rating: trimmed.isEmpty ? null : double.tryParse(trimmed),
      ),
    };
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
  final rounded = value.toStringAsFixed(
    value.truncateToDouble() == value ? 0 : 1,
  );
  return rounded;
}

String _targetDisplayName(AudioDetailTarget target) {
  return target.isLibraryRootFolder
      ? PathDisplay.folderName(target.targetPath)
      : PathDisplay.fileName(target.targetPath, withoutExtension: true);
}

List<String> _splitMultiValue(String rawValue) {
  return AudioDetail.normalizeList(rawValue.split(_multiValueSeparator));
}

bool _looksLikeRjCode(String value) {
  return value.isEmpty || RegExp(r'^RJ\d+$').hasMatch(value);
}
