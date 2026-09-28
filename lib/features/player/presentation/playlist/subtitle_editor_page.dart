import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/subtitle_parser.dart';
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
    final cue = _cues![index];
    var text = cue.text;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final nextText = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.tr('subtitle_edit_text')),
        content: TextFormField(
          initialValue: cue.text,
          onChanged: (value) => text = value,
          autofocus: true,
          minLines: 2,
          maxLines: 8,
          decoration: InputDecoration(hintText: i18n.tr('subtitle_edit_text')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(i18n.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.trim()),
            child: Text(i18n.tr('save')),
          ),
        ],
      ),
    );
    if (!mounted ||
        nextText == null ||
        nextText.isEmpty ||
        nextText == cue.text) {
      return;
    }
    setState(() {
      _cues![index] = SubtitleCue(
        start: cue.start,
        end: cue.end,
        text: nextText,
      );
      _dirty = true;
    });
  }

  Future<void> _editTime(int index) async {
    final cue = _cues![index];
    final hasTime = cue.end > cue.start;
    var startText = hasTime ? _formatTime(cue.start) : '';
    var endText = hasTime ? _formatTime(cue.end) : '';
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    String? validationError;
    final next = await showDialog<(Duration, Duration)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
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
        next == null ||
        (next.$1 == cue.start && next.$2 == cue.end)) {
      return;
    }
    setState(() {
      _cues![index] = SubtitleCue(start: next.$1, end: next.$2, text: cue.text);
      _dirty = true;
    });
  }

  void _insertAfter(SubtitleCue cue) {
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
    final index = _cues?.indexOf(cue) ?? -1;
    if (index < 0) return;
    setState(() {
      _cues!.removeAt(index);
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(playbackSubtitleServiceProvider)
          .saveEditedSubtitle(widget.trackPath, _cues!);
      if (!mounted) return;
      setState(() => _dirty = false);
      showAppSnackBar(
        context,
        ref.read(appLanguageProviderInstanceProvider).tr('subtitle_saved'),
        tone: AppFeedbackTone.success,
        icon: Icons.check_circle_rounded,
      );
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
    } finally {
      if (mounted) setState(() => _saving = false);
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
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final contentTopInset = AppPageHeaderMetrics.contentTopInset(context);
    return Scaffold(
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
                                        onTap: () => _editText(index),
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
                                      onTap: () => _editTime(index),
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
                leading: BackButton(color: cs.onSurface),
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
  }
}
