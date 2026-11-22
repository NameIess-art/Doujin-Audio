import 'package:flutter/material.dart';

import '../../../../core/widgets/app_buttons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/subtitle_parser.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/app_edit_panel.dart';
import '../../../../core/widgets/app_entry_ink_well.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/mobile_overlay_inset.dart';
import '../../../../core/widgets/page_header_inset.dart';
import '../../../../core/widgets/swipe_reveal_card.dart';
import '../../../../core/widgets/top_page_header.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../application/playback_subtitle_service.dart';
import '../playback_providers.dart';
import '../../../../core/widgets/unified_popup_menu.dart';

class SubtitleEditorPage extends ConsumerStatefulWidget {
  const SubtitleEditorPage({super.key, required this.trackPath});

  final String trackPath;

  @override
  ConsumerState<SubtitleEditorPage> createState() => _SubtitleEditorPageState();
}

class _SubtitleEditorPageState extends ConsumerState<SubtitleEditorPage> {
  static final RegExp _lineBreakPattern = RegExp(r'\r?\n');
  static final RegExp _fullTimePattern = RegExp(
    r'^(\d+):(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?$',
  );
  static final RegExp _shortTimePattern = RegExp(
    r'^(\d+):(\d{2})(?:[.,](\d{1,3}))?$',
  );

  final ScrollController _scrollController = ScrollController();
  SubtitleTrack? _sourceTrack;
  List<SubtitleCue>? _cues;
  bool _saving = false;
  bool _dirty = false;
  bool _cuesValid = false;
  bool _confirmingExit = false;
  bool _highlightInvalid = false;
  // Ignore dialogs opened before a save, including results after it completes.
  int _saveGeneration = 0;
  int _editGeneration = 0;
  String? _errorKey;

  bool get _canSave => _dirty && !_saving && _cuesValid;

  int? _firstInvalidCueIndex() {
    final cues = _cues;
    if (cues == null) return null;
    final hasSameTiming = _sourceTrack?.hasSameCueTimings(cues) ?? false;
    for (var index = 0; index < cues.length; index++) {
      if (_isCueInvalidAt(cues, index, hasSameTiming: hasSameTiming)) {
        return index;
      }
    }
    return null;
  }

  bool _isCueInvalidAt(
    List<SubtitleCue> cues,
    int index, {
    required bool hasSameTiming,
  }) {
    final cue = cues[index];
    return cue.text.trim().isEmpty ||
        cue.start < Duration.zero ||
        cue.end <= cue.start ||
        (!hasSameTiming && index > 0 && cue.start < cues[index - 1].end);
  }

  void _recomputeCuesValid() {
    final cues = _cues;
    if (cues == null) {
      _cuesValid = false;
      return;
    }
    _cuesValid = _firstInvalidCueIndex() == null;
    if (_cuesValid) {
      _highlightInvalid = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final track = await ref
          .read(playbackSubtitleServiceProvider)
          .loadForEditing(widget.trackPath);
      if (!mounted) return;
      setState(() {
        _sourceTrack = track;
        _cues = track?.cues.toList() ?? <SubtitleCue>[];
        _recomputeCuesValid();
      });
    } catch (_) {
      if (mounted) setState(() => _errorKey = 'subtitle_load_failed');
    }
  }

  int _resolveCueIndex(int index, SubtitleCue cue) {
    final cues = _cues;
    if (cues == null) return -1;
    if (index >= 0 && index < cues.length && identical(cues[index], cue)) {
      return index;
    }
    return cues.indexOf(cue);
  }

  Future<void> _editText(int index, SubtitleCue cue) async {
    if (_saving || _resolveCueIndex(index, cue) < 0) return;
    final generation = _saveGeneration;
    String normalizeLines(String value) => value
        .split(_lineBreakPattern)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');

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
    final header = AppEditPanelHeader(
      title: i18n.tr('subtitle_edit_text'),
      icon: Icons.edit_note_rounded,
    );
    final next = await showAppInputPanel<({String text, String? originalText})>(
      context: context,
      header: header,
      preferredHeight: bilingual ? 320 : 240,
      builder: (context, height) => AppEditPanelForm(
        height: height,
        header: header,
        fields: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bilingual) ...[
              TextFormField(
                contextMenuBuilder: buildAppEditableTextMenu,
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
                contextMenuBuilder: buildAppEditableTextMenu,
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
                contextMenuBuilder: buildAppEditableTextMenu,
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
        cancelLabel: i18n.tr('cancel'),
        submitLabel: i18n.tr('save'),
        onCancel: () => Navigator.pop(context),
        onSubmit: () {
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
      ),
    );
    if (!mounted ||
        _saving ||
        generation != _saveGeneration ||
        next == null ||
        (next.text == cue.text && next.originalText == cue.originalText)) {
      return;
    }
    final currentIndex = _resolveCueIndex(index, cue);
    if (currentIndex < 0) return;
    setState(() {
      _cues![currentIndex] = SubtitleCue(
        start: cue.start,
        end: cue.end,
        text: next.text,
        originalText: next.originalText,
        assSourceLine: cue.assSourceLine,
      );
      _editGeneration++;
      _dirty = true;
      _recomputeCuesValid();
    });
  }

  (Duration, Duration) _suggestedRangeForIndex(int index) {
    final cues = _cues!;
    final previousEnd = index == 0 ? Duration.zero : cues[index - 1].end;
    final nextCue = index + 1 < cues.length ? cues[index + 1] : null;
    final start = previousEnd < Duration.zero ? Duration.zero : previousEnd;
    var end = start + const Duration(seconds: 2);
    if (nextCue != null && nextCue.start > start && nextCue.start < end) {
      end = nextCue.start;
    } else if (nextCue != null && nextCue.end > start && nextCue.end <= end) {
      final clampedMs = nextCue.end.inMilliseconds - 1;
      if (clampedMs > start.inMilliseconds) {
        end = Duration(milliseconds: clampedMs);
      }
    }
    return (start, end);
  }

  Future<void> _editTime(int index, SubtitleCue cue) async {
    if (_saving) return;
    final resolvedIndex = _resolveCueIndex(index, cue);
    if (resolvedIndex < 0) return;
    final generation = _saveGeneration;
    final hasTime = cue.end > cue.start;
    final suggested = hasTime ? null : _suggestedRangeForIndex(resolvedIndex);
    var startText = hasTime
        ? _formatTime(cue.start)
        : _formatTime(suggested!.$1);
    var endText = hasTime ? _formatTime(cue.end) : _formatTime(suggested!.$2);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    String? validationError;
    final header = AppEditPanelHeader(
      title: i18n.tr('subtitle_edit_time'),
      icon: Icons.schedule_rounded,
    );
    final next = await showAppInputPanel<(Duration, Duration)>(
      context: context,
      header: header,
      preferredHeight: 300,
      builder: (context, height) => StatefulBuilder(
        builder: (context, setDialogState) => AppEditPanelForm(
          height: height,
          header: header,
          fields: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                contextMenuBuilder: buildAppEditableTextMenu,
                initialValue: startText,
                onChanged: (value) => startText = value,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                  labelText: i18n.tr('subtitle_start_time'),
                  hintText: i18n.tr('subtitle_time_format_hint'),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                contextMenuBuilder: buildAppEditableTextMenu,
                initialValue: endText,
                onChanged: (value) => endText = value,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                  labelText: i18n.tr('subtitle_end_time'),
                  hintText: i18n.tr('subtitle_time_format_hint'),
                  errorText: validationError,
                ),
              ),
            ],
          ),
          cancelLabel: i18n.tr('cancel'),
          submitLabel: i18n.tr('save'),
          onCancel: () => Navigator.pop(context),
          onSubmit: () {
            final activeIndex = _resolveCueIndex(resolvedIndex, cue);
            if (_saving ||
                generation != _saveGeneration ||
                activeIndex != resolvedIndex) {
              return;
            }
            final start = _parseTime(startText);
            final end = _parseTime(endText);
            if (start == null || end == null) {
              setDialogState(
                () => validationError = i18n.tr('subtitle_invalid_format'),
              );
              return;
            }
            final previousEnd = activeIndex == 0
                ? Duration.zero
                : _cues![activeIndex - 1].end;
            final nextCue = activeIndex + 1 < _cues!.length
                ? _cues![activeIndex + 1]
                : null;
            final nextEnd = nextCue != null && nextCue.end > nextCue.start
                ? nextCue.end
                : null;
            if (start < previousEnd ||
                end <= start ||
                (nextEnd != null && end >= nextEnd)) {
              setDialogState(
                () => validationError = i18n.tr('subtitle_overlap_error'),
              );
              return;
            }
            Navigator.pop(context, (start, end));
          },
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
    final currentIndex = _resolveCueIndex(resolvedIndex, cue);
    if (currentIndex < 0) return;
    setState(() {
      _cues![currentIndex] = SubtitleCue(
        start: next.$1,
        end: next.$2,
        text: cue.text,
        originalText: cue.originalText,
        assSourceLine: cue.assSourceLine,
      );
      if (currentIndex + 1 < _cues!.length) {
        final nextCue = _cues![currentIndex + 1];
        if (nextCue.start < next.$2 && nextCue.end > next.$2) {
          _cues![currentIndex + 1] = SubtitleCue(
            start: next.$2,
            end: nextCue.end,
            text: nextCue.text,
            originalText: nextCue.originalText,
            assSourceLine: nextCue.assSourceLine,
          );
        }
      }
      _editGeneration++;
      _dirty = true;
      _recomputeCuesValid();
    });
  }

  void _insertCueAt(int insertIndex) {
    if (_saving || _cues == null) return;
    final clampedIndex = insertIndex.clamp(0, _cues!.length);
    final anchor = clampedIndex == 0
        ? Duration.zero
        : _cues![clampedIndex - 1].end;
    setState(() {
      _cues!.insert(
        clampedIndex,
        SubtitleCue(start: anchor, end: anchor, text: ''),
      );
      _editGeneration++;
      _dirty = true;
      _recomputeCuesValid();
    });
  }

  void _insertAfter(int index, SubtitleCue cue) {
    if (_saving) return;
    final resolvedIndex = _resolveCueIndex(index, cue);
    if (resolvedIndex < 0) return;
    _insertCueAt(resolvedIndex + 1);
  }

  void _insertBefore(int index, SubtitleCue cue) {
    if (_saving) return;
    final resolvedIndex = _resolveCueIndex(index, cue);
    if (resolvedIndex < 0) return;
    _insertCueAt(resolvedIndex);
  }

  void _appendCue() {
    if (_saving || _cues == null) return;
    final targetIndex = _cues!.length;
    _insertCueAt(targetIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : kAppMotionFast,
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _deleteCue(int index, SubtitleCue cue) {
    if (_saving) return;
    final resolvedIndex = _resolveCueIndex(index, cue);
    if (resolvedIndex < 0) return;
    final wasDirty = _dirty;
    final deleteEditGen = ++_editGeneration;
    setState(() {
      if (_cues!.length == 1) {
        // The outgoing list can still build its final row while fading.
        _cues = [];
      } else {
        _cues!.removeAt(resolvedIndex);
      }
      _dirty = true;
      _recomputeCuesValid();
    });
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('subtitle_cue_deleted'),
      actionLabel: i18n.tr('undo'),
      onAction: () {
        if (!mounted || _saving || _cues == null) return;
        setState(() {
          final restoreIndex = resolvedIndex.clamp(0, _cues!.length);
          _cues!.insert(restoreIndex, cue);
          if (_editGeneration == deleteEditGen) {
            _dirty = wasDirty;
          }
          _editGeneration++;
          _recomputeCuesValid();
        });
      },
    );
  }

  void _scrollToFirstInvalidCue() {
    final invalidIndex = _firstInvalidCueIndex();
    if (invalidIndex == null) return;
    setState(() => _highlightInvalid = true);
    if (_scrollController.hasClients && _cues != null && _cues!.isNotEmpty) {
      final maxExtent = _scrollController.position.maxScrollExtent;
      final estimatedOffset = _cues!.length <= 1
          ? 0.0
          : (invalidIndex / (_cues!.length - 1)) * maxExtent;
      _scrollController.animateTo(
        estimatedOffset.clamp(0.0, maxExtent),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : kAppMotionFast,
        curve: Curves.easeOutCubic,
      );
    }
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('subtitle_complete_cue'),
      tone: AppFeedbackTone.warning,
      icon: Icons.error_outline_rounded,
    );
  }

  Future<bool> _save() async {
    if (!_canSave) return false;
    setState(() {
      _saving = true;
      _saveGeneration++;
    });
    try {
      final saved = await ref
          .read(playbackSubtitleServiceProvider)
          .saveEditedSubtitle(
            widget.trackPath,
            List.of(_cues!),
            source: _sourceTrack,
          );
      if (!mounted) return false;
      setState(() {
        _sourceTrack = saved;
        _cues = saved.cues.toList();
        _dirty = false;
        _recomputeCuesValid();
      });
      showAppSnackBar(
        context,
        ref.read(appLanguageProviderInstanceProvider).tr('subtitle_saved'),
        tone: AppFeedbackTone.success,
        icon: Icons.check_circle_rounded,
      );
      return true;
    } catch (error) {
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr(
                error is SubtitleSourceChanged
                    ? 'subtitle_source_changed'
                    : 'subtitle_save_failed',
              ),
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
        builder: (dialogContext) {
          final theme = Theme.of(dialogContext);
          final cs = theme.colorScheme;
          return AppDialog(
            title: i18n.tr('subtitle_unsaved_title'),
            icon: Icons.warning_amber_rounded,
            scrollable: true,
            content: Text(
              i18n.tr('subtitle_unsaved_message'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.25,
              ),
            ),
            actions: AppDialogActions(
              children: [
                AppSecondaryButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  label: i18n.tr('cancel'),
                ),
                AppSecondaryButton(
                  isDestructive: true,
                  onPressed: () => Navigator.pop(dialogContext, false),
                  label: i18n.tr('discard_changes'),
                ),
                AppPrimaryButton(
                  onPressed: _canSave
                      ? () => Navigator.pop(dialogContext, true)
                      : null,
                  label: i18n.tr('save'),
                ),
              ],
            ),
          );
        },
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

  static int _parseFractionMillis(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    return int.parse(raw.padRight(3, '0'));
  }

  static Duration? _parseTime(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final fullMatch = _fullTimePattern.firstMatch(trimmed);
    if (fullMatch != null) {
      final hours = int.parse(fullMatch[1]!);
      final minutes = int.parse(fullMatch[2]!);
      final seconds = int.parse(fullMatch[3]!);
      if (minutes > 59 || seconds > 59) return null;
      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: _parseFractionMillis(fullMatch[4]),
      );
    }
    final shortMatch = _shortTimePattern.firstMatch(trimmed);
    if (shortMatch != null) {
      final minutes = int.parse(shortMatch[1]!);
      final seconds = int.parse(shortMatch[2]!);
      if (seconds > 59) return null;
      return Duration(
        minutes: minutes,
        seconds: seconds,
        milliseconds: _parseFractionMillis(shortMatch[3]),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final contentTopInset = AppPageHeaderMetrics.contentTopInset(context);
    final cues = _cues;
    Widget transitionChild(Widget child, {required bool interactive}) {
      return ExcludeFocus(
        key: child.key,
        excluding: !interactive,
        child: ExcludeSemantics(
          excluding: !interactive,
          child: IgnorePointer(ignoring: !interactive, child: child),
        ),
      );
    }

    final page = Scaffold(
      body: PageHeaderInset(
        topInset: contentTopInset,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                backgroundColor: cs.surface,
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : kPlaceholderContentTransitionDuration,
                  switchInCurve: kAppFadeCurve,
                  switchOutCurve: kAppFadeCurve,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.center,
                    children: [
                      for (final child in previous)
                        transitionChild(child, interactive: false),
                      if (current != null)
                        transitionChild(current, interactive: true),
                    ],
                  ),
                  child: _errorKey != null
                      ? Center(
                          key: ValueKey('error_$_errorKey'),
                          child: Text(i18n.tr(_errorKey!)),
                        )
                      : cues == null
                      ? const Center(
                          key: ValueKey('cues_loading'),
                          child: CircularProgressIndicator(),
                        )
                    : cues.isEmpty
                    ? Center(
                        key: ValueKey('cues_empty_$_dirty'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                i18n.tr(
                                  _dirty
                                      ? 'subtitle_all_removed'
                                      : 'subtitle_no_content',
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                key: const ValueKey('subtitle_empty_add_button'),
                                onPressed: _saving ? null : _appendCue,
                                icon: const Icon(Icons.add_rounded),
                                label: Text(i18n.tr('subtitle_add_cue')),
                              ),
                            ],
                          ),
                        ),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('cues_list'),
                        child: ListView.separated(
                          controller: _scrollController,
                          padding: EdgeInsets.fromLTRB(
                            16,
                            contentTopInset,
                            16,
                            16 +
                                MediaQuery.paddingOf(context).bottom +
                                MobileOverlayInset.of(context),
                          ),
                          itemCount: cues.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final cue = cues[index];
                            final needsText = cue.text.trim().isEmpty;
                            final needsTime = cue.end <= cue.start;
                            final hasSameTiming =
                                _sourceTrack?.hasSameCueTimings(cues) ?? false;
                            final hasOverlap =
                                !hasSameTiming &&
                                index > 0 &&
                                cue.start < cues[index - 1].end;
                            final isInvalid =
                                needsText ||
                                needsTime ||
                                cue.start < Duration.zero ||
                                hasOverlap;
                            final showErrorHighlight =
                                isInvalid && (_highlightInvalid || hasOverlap);
                            return SwipeRevealCard(
                              key: ObjectKey(cue),
                              enabled: !_saving,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              closedColor: cs.surfaceContainerLow,
                              onRemove: () => _deleteCue(index, cue),
                              actionLabel: i18n.tr('subtitle_delete_cue'),
                              removeTooltip: i18n.tr('subtitle_delete_cue'),
                              onLeadingAction: () => _insertAfter(index, cue),
                              leadingActionLabel: i18n.tr('subtitle_add_below'),
                              leadingActionTooltip: i18n.tr(
                                'subtitle_add_below',
                              ),
                              leadingActionIcon: Icons.add_rounded,
                              onSecondaryLeadingAction: () =>
                                  _insertBefore(index, cue),
                              secondaryLeadingActionLabel: i18n.tr(
                                'subtitle_add_above',
                              ),
                              secondaryLeadingActionTooltip: i18n.tr(
                                'subtitle_add_above',
                              ),
                              secondaryLeadingActionIcon:
                                  Icons.playlist_add_rounded,
                              child: Material(
                                color: cs.surfaceContainerLow,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: showErrorHighlight
                                      ? BorderSide(
                                          color: cs.error.withValues(
                                            alpha: 0.75,
                                          ),
                                          width: 1.5,
                                        )
                                      : BorderSide.none,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: AppEntryInkWell(
                                              key: ValueKey(
                                                'subtitle_text_$index',
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              onTap: _saving
                                                  ? null
                                                  : () => _editText(index, cue),
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  14,
                                                ),
                                                child: Text(
                                                  needsText
                                                      ? i18n.tr(
                                                          'subtitle_new_text',
                                                        )
                                                      : cue.text,
                                                  style: needsText
                                                      ? TextStyle(
                                                          color:
                                                              showErrorHighlight
                                                                  ? cs.error
                                                                  : cs.onSurfaceVariant,
                                                        )
                                                      : null,
                                                ),
                                              ),
                                            ),
                                          ),
                                          AppEntryInkWell(
                                            key: ValueKey(
                                              'subtitle_time_$index',
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            onTap: _saving
                                                ? null
                                                : () => _editTime(index, cue),
                                            child: Padding(
                                              padding: const EdgeInsets.all(12),
                                              child: needsTime
                                                  ? Text(
                                                      i18n.tr(
                                                        'subtitle_new_time',
                                                      ),
                                                      style: showErrorHighlight
                                                          ? TextStyle(
                                                              color: cs.error,
                                                            )
                                                          : null,
                                                    )
                                                  : Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .end,
                                                      children: [
                                                        Text(
                                                          _formatTime(
                                                            cue.start,
                                                          ),
                                                          style: hasOverlap
                                                              ? TextStyle(
                                                                  color:
                                                                      cs.error,
                                                                )
                                                              : null,
                                                        ),
                                                        Text(
                                                          _formatTime(cue.end),
                                                        ),
                                                      ],
                                                    ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    if (needsText || needsTime || hasOverlap)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          14,
                                          0,
                                          14,
                                          12,
                                        ),
                                        child: Text(
                                          hasOverlap
                                              ? i18n.tr('subtitle_overlap_error')
                                              : i18n.tr(
                                                  'subtitle_complete_cue',
                                                ),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: showErrorHighlight
                                                    ? cs.error
                                                    : cs.onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ).withWindowsSmoothScroll(),
                      ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                icon: Icons.edit_note_rounded,
                title: i18n.tr('subtitle_edit'),
                leading: AppHeaderBackButton(
                  enabled: !_saving,
                  onPressed: _requestExit,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HeaderFloatingButton(
                      child: IconButton(
                        key: const ValueKey('subtitle_add_button'),
                        tooltip: i18n.tr('subtitle_add_cue'),
                        onPressed: (_saving || cues == null)
                            ? null
                            : _appendCue,
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ),
                    const SizedBox(width: 8),
                    HeaderFloatingButton(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: (_dirty && !_cuesValid && !_saving)
                            ? _scrollToFirstInvalidCue
                            : null,
                        child: IconButton(
                          tooltip: i18n.tr('save'),
                          onPressed: _canSave ? _save : null,
                          icon: _saving
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_rounded),
                        ),
                      ),
                    ),
                  ],
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
