import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../services/path_display.dart';
import '../widgets/app_feedback.dart';
import 'dlsite_metadata_review_page.dart';

const _multiValueSeparator = '\uFF0C';

Future<void> showAudioDetailSheet(
  BuildContext context,
  AudioDetailTarget target,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final result = await context.read<AudioProvider>().loadAudioDetail(
        _target,
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
      final result = await context
          .read<AudioProvider>()
          .renameAudioDetailTargetToName(detail, targetName);
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
      final result = await context.read<AudioProvider>().saveAudioDetail(
        nextDetail,
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
    final normalizedRjCode = AudioDetail.findRjCodeInText(detail.rjCode);
    final searchTitles = _dlsiteTitleSearchCandidates(detail);
    if (normalizedRjCode == null && searchTitles.isEmpty) {
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_fetch_missing_query'),
        tone: AppFeedbackTone.warning,
      );
      return;
    }
    final confirmed = await _confirmAction(
      title: i18n.tr('audio_detail_fetch_info'),
      message: i18n.tr('audio_detail_fetch_confirm'),
      confirmLabel: i18n.tr('audio_detail_fetch_info'),
    );
    if (!confirmed || !mounted) return;

    final updated = await Navigator.of(context).push<AudioDetail>(
      MaterialPageRoute(
        builder: (_) => DlsiteMetadataReviewPage(
          detail: detail,
          rjCode: normalizedRjCode,
          searchTitles: normalizedRjCode == null
              ? searchTitles
              : const <String>[],
        ),
      ),
    );
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
      final result = await context
          .read<AudioProvider>()
          .renameAudioDetailTarget(detail);
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
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_loadError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  i18n.tr('audio_detail_load_failed'),
                  style: TextStyle(color: cs.error),
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
              ..._AudioDetailField.values.expand(
                (field) => [
                  _AudioDetailRow(
                    label: field.label(i18n, detail),
                    value: field.displayValue(detail, i18n),
                    labelStyle: labelStyle,
                    busy: _savingField == field,
                    onTap: () => _editField(field),
                  ),
                  if (field != _AudioDetailField.values.last)
                    const Divider(height: 1),
                ],
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

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null || _images.isEmpty || _pageController == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(i18n.tr('audio_detail_cover_image'), style: labelStyle),
        const SizedBox(height: 10),
        ClipRRect(
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
                      return Image.file(
                        File(_images[index]),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => DecoratedBox(
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                          ),
                          child: Icon(
                            Icons.image_not_supported_rounded,
                            color: cs.onSurfaceVariant,
                            size: 42,
                          ),
                        ),
                      );
                    },
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
  }
}

class _AudioDetailRow extends StatelessWidget {
  const _AudioDetailRow({
    required this.label,
    required this.value,
    required this.labelStyle,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final String value;
  final TextStyle? labelStyle;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: value.isEmpty ? cs.onSurfaceVariant : cs.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 24,
              height: 24,
              child: busy
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : Icon(
                      Icons.edit_rounded,
                      size: 18,
                      color: cs.onSurfaceVariant,
                    ),
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
  tags;

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
    };
  }

  List<String> readList(AudioDetail detail) {
    return switch (this) {
      _AudioDetailField.voiceActors => detail.voiceActors,
      _AudioDetailField.tags => detail.tags,
      _ => const <String>[],
    };
  }

  String displayValue(AudioDetail detail, AppLanguageProvider i18n) {
    final value = isMulti
        ? readList(detail).join(_multiValueSeparator)
        : readText(detail);
    return value.isEmpty ? i18n.tr('audio_detail_empty') : value;
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
    };
  }
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

List<String> _dlsiteTitleSearchCandidates(AudioDetail detail) {
  final seen = <String>{};
  final candidates = <String>[
    _targetDisplayName(detail.target),
    detail.workTitle,
  ];
  return candidates
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty && seen.add(value))
      .toList(growable: false);
}
