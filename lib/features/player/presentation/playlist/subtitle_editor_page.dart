import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/subtitle_parser.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/page_header_inset.dart';
import '../../../../core/widgets/swipe_reveal_card.dart';
import '../../../../core/widgets/top_page_header.dart';
import '../playback_providers.dart';

class SubtitleEditorPage extends ConsumerStatefulWidget {
  const SubtitleEditorPage({super.key, required this.trackPath});

  final String trackPath;

  @override
  ConsumerState<SubtitleEditorPage> createState() => _SubtitleEditorPageState();
}

class _SubtitleEditorPageState extends ConsumerState<SubtitleEditorPage> {
  List<SubtitleCue>? _cues;
  bool _saving = false;
  bool _dirty = false;
  bool _confirmingExit = false;
  // Ignore dialogs opened before a save, including results after it completes.
  int _saveGeneration = 0;
  String? _errorKey;

  bool get _canSave {
    final cues = _cues;
    if (!_dirty || _saving || cues == null) return false;
    for (var index = 0; index < cues.length; index++) {
      final cue = cues[index];
      if (cue.text.trim().isEmpty ||
          cue.end <= cue.start ||
          (index > 0 && cue.start < cues[index - 1].end)) {
        return false;
      }
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final track = await ref
          .read(playbackSubtitleServiceProvider)
          .load(widget.trackPath);
      if (!mounted) return;
      setState(() => _cues = track?.cues.toList() ?? <SubtitleCue>[]);
    } catch (_) {
      if (mounted) setState(() => _errorKey = 'subtitle_load_failed');
    }
  }

  Future<void> _editText(int index) async {
    if (_saving) return;
    final generation = _saveGeneration;
    String normalizeLines(String value) => value
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');

    final cue = _cues![index];
    var text = cue.text;
    final original = cue.originalText;
    final bilingual =
        original != null &&
        original.trim().isNotEmpty &&
        (cue.text == original || cue.text.startsWith('$original\n'));
    var originalText = bilingual ? original : '';
    var translatedText = bilingual && cue.text != original
        ? cue.text.substring(original.length + 1)
        : '';
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final next = await showAppDialog<({String text, String? originalText})>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(i18n.tr('subtitle_edit_text')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (bilingual) ...[
                TextFormField(
                  key: const ValueKey('subtitle_original_text'),
                  initialValue: originalText,
                  onChanged: (value) => originalText = value,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 8,
                  decoration: InputDecoration(
                    labelText: i18n.tr('subtitle_original_text'),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('subtitle_translated_text'),
                  initialValue: translatedText,
                  onChanged: (value) => translatedText = value,
                  minLines: 2,
                  maxLines: 8,
                  decoration: InputDecoration(
                    labelText: i18n.tr('subtitle_translated_text'),
                  ),
                ),
              ] else
                TextFormField(
                  initialValue: cue.text,
                  onChanged: (value) => text = value,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 8,
                  decoration: InputDecoration(
                    hintText: i18n.tr('subtitle_edit_text'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(i18n.tr('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final source = normalizeLines(originalText);
              final translated = normalizeLines(translatedText);
              var combined = text.trim();
              if (bilingual) {
                combined = translated.isEmpty ? source : '$source\n$translated';
              }
              if (combined.isEmpty || (bilingual && source.isEmpty)) return;
              Navigator.pop(context, (
                text: combined,
                originalText: bilingual ? source : null,
              ));
            },
            child: Text(i18n.tr('save')),
          ),
        ],
      ),
    );
    if (!mounted ||
        _saving ||
        generation != _saveGeneration ||
        next == null ||
        (next.text == cue.text && next.originalText == cue.originalText)) {
      return;
    }
    final currentIndex = _cues!.indexOf(cue);
    if (currentIndex < 0) return;
    setState(() {
      _cues![currentIndex] = SubtitleCue(
        start: cue.start,
        end: cue.end,
        text: next.text,
        originalText: next.originalText,
      );
      _dirty = true;
    });
  }

  Future<void> _editTime(int index) async {
    if (_saving) return;
    final generation = _saveGeneration;
    final cue = _cues![index];
    final hasTime = cue.end > cue.start;
    var startText = hasTime ? _formatTime(cue.start) : '';
    var endText = hasTime ? _formatTime(cue.end) : '';
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    String? validationError;
    final next = await showAppDialog<(Duration, Duration)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AppAlertDialog(
          title: Text(i18n.tr('subtitle_edit_time')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: startText,
                onChanged: (value) => startText = value,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                  labelText: i18n.tr('subtitle_start_time'),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: endText,
                onChanged: (value) => endText = value,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                  labelText: i18n.tr('subtitle_end_time'),
                  errorText: validationError,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(i18n.tr('cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (_saving ||
                    generation != _saveGeneration ||
                    _cues!.indexOf(cue) != index) {
                  return;
                }
                final start = _parseTime(startText);
                final end = _parseTime(endText);
                final previousEnd = index == 0
                    ? Duration.zero
                    : _cues![index - 1].end;
                final nextStart =
                    index + 1 == _cues!.length ||
                        _cues![index + 1].end <= _cues![index + 1].start
                    ? null
                    : _cues![index + 1].start;
                if (start == null ||
                    end == null ||
                    start < previousEnd ||
                    end <= start ||
                    (nextStart != null && end > nextStart)) {
                  setDialogState(
                    () => validationError = i18n.tr('subtitle_invalid_time'),
                  );
                  return;
                }
                Navigator.pop(context, (start, end));
              },
              child: Text(i18n.tr('save')),
            ),
          ],
        ),
      ),
    );
    if (!mounted ||
        _saving ||
        generation != _saveGeneration ||
        next == null ||
        (next.$1 == cue.start && next.$2 == cue.end)) {
      return;
    }
    final currentIndex = _cues!.indexOf(cue);
    if (currentIndex < 0) return;
    setState(() {
      _cues![currentIndex] = SubtitleCue(
        start: next.$1,
        end: next.$2,
        text: cue.text,
        originalText: cue.originalText,
      );
      _dirty = true;
    });
  }

  void _insertAfter(SubtitleCue cue) {
    if (_saving) return;
    final index = _cues?.indexOf(cue) ?? -1;
    if (index < 0) return;
    setState(() {
      _cues!.insert(
        index + 1,
        SubtitleCue(start: cue.end, end: cue.end, text: ''),
      );
      _dirty = true;
    });
  }

  void _deleteCue(SubtitleCue cue) {
    if (_saving) return;
    final index = _cues?.indexOf(cue) ?? -1;
    if (index < 0) return;
    setState(() {
      _cues!.removeAt(index);
      _dirty = true;
    });
  }

  Future<bool> _save() async {
    if (!_canSave) return false;
    setState(() {
      _saving = true;
      _saveGeneration++;
    });
    try {
      await ref
          .read(playbackSubtitleServiceProvider)
          .saveEditedSubtitle(widget.trackPath, List.of(_cues!));
      if (!mounted) return false;
      setState(() => _dirty = false);
      showAppSnackBar(
        context,
        ref.read(appLanguageProviderInstanceProvider).tr('subtitle_saved'),
        tone: AppFeedbackTone.success,
        icon: Icons.check_circle_rounded,
      );
      return true;
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('subtitle_save_failed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.error_outline_rounded,
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _requestExit() async {
    if (_saving || _confirmingExit) return;
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    _confirmingExit = true;
    try {
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      final save = await showAppDialog<bool>(
        context: context,
        builder: (dialogContext) => AppAlertDialog(
          title: Text(i18n.tr('subtitle_unsaved_title')),
          content: Text(i18n.tr('subtitle_unsaved_message')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(i18n.tr('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(i18n.tr('discard_changes')),
            ),
            FilledButton(
              onPressed: _canSave
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: Text(i18n.tr('save')),
            ),
          ],
        ),
      );
      if (!mounted || save == null) return;
      if (save && !await _save()) return;
      if (!mounted) return;
      setState(() => _dirty = false);
      // Let PopScope observe the clean draft before completing navigation.
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    } finally {
      _confirmingExit = false;
    }
  }

  static String _formatTime(Duration value) {
    final ms = value.inMilliseconds;
    return '${(ms ~/ 3600000).toString().padLeft(2, '0')}:${((ms ~/ 60000) % 60).toString().padLeft(2, '0')}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}';
  }

  static Duration? _parseTime(String value) {
    final match = RegExp(
      r'^(\d+):(\d{2}):(\d{2})[.,](\d{3})$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final minutes = int.parse(match[2]!);
    final seconds = int.parse(match[3]!);
    if (minutes > 59 || seconds > 59) return null;
    return Duration(
      hours: int.parse(match[1]!),
      minutes: minutes,
      seconds: seconds,
      milliseconds: int.parse(match[4]!),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final contentTopInset = AppPageHeaderMetrics.contentTopInset(context);
    final page = Scaffold(
      body: PageHeaderInset(
        topInset: contentTopInset,
        child: Stack(
          children: [
            Positioned.fill(
              child: _errorKey != null
                  ? Center(child: Text(i18n.tr(_errorKey!)))
                  : _cues == null
                  ? const Center(child: CircularProgressIndicator.adaptive())
                  : _cues!.isEmpty
                  ? Center(
                      child: Text(
                        i18n.tr(
                          _dirty
                              ? 'subtitle_all_removed'
                              : 'subtitle_no_content',
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(16, contentTopInset, 16, 16),
                      itemCount: _cues!.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final cue = _cues![index];
                        final needsText = cue.text.trim().isEmpty;
                        final needsTime = cue.end <= cue.start;
                        return SwipeRevealCard(
                          key: ObjectKey(cue),
                          enabled: !_saving,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          closedColor: cs.surfaceContainerLow,
                          onRemove: () => _deleteCue(cue),
                          actionLabel: i18n.tr('subtitle_delete_cue'),
                          removeTooltip: i18n.tr('subtitle_delete_cue'),
                          onLeadingAction: () => _insertAfter(cue),
                          leadingActionLabel: i18n.tr('subtitle_add_below'),
                          leadingActionTooltip: i18n.tr('subtitle_add_below'),
                          leadingActionIcon: Icons.add_rounded,
                          child: Material(
                            color: cs.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: InkWell(
                                        key: ValueKey('subtitle_text_$index'),
                                        borderRadius: BorderRadius.circular(12),
                                        onTap: _saving
                                            ? null
                                            : () => _editText(index),
                                        child: Padding(
                                          padding: const EdgeInsets.all(14),
                                          child: Text(
                                            needsText
                                                ? i18n.tr('subtitle_new_text')
                                                : cue.text,
                                            style: needsText
                                                ? TextStyle(
                                                    color: cs.onSurfaceVariant,
                                                  )
                                                : null,
                                          ),
                                        ),
                                      ),
                                    ),
                                    InkWell(
                                      key: ValueKey('subtitle_time_$index'),
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: _saving
                                          ? null
                                          : () => _editTime(index),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: needsTime
                                            ? Text(i18n.tr('subtitle_new_time'))
                                            : Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  Text(_formatTime(cue.start)),
                                                  Text(_formatTime(cue.end)),
                                                ],
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (needsText || needsTime)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      0,
                                      14,
                                      12,
                                    ),
                                    child: Text(
                                      i18n.tr('subtitle_complete_cue'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                icon: Icons.edit_note_rounded,
                title: i18n.tr('subtitle_edit'),
                leading: BackButton(
                  color: cs.onSurface,
                  onPressed: _saving ? null : _requestExit,
                ),
                trailing: IconButton(
                  tooltip: i18n.tr('save'),
                  onPressed: _canSave ? _save : null,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return PopScope<void>(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _requestExit();
      },
      child: page,
    );
  }
}
