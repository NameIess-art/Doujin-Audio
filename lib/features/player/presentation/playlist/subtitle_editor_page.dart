import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/subtitle_parser.dart';
import '../../../../core/widgets/page_header_inset.dart';
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
    final controller = TextEditingController(text: cue.text);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final nextText = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.tr('subtitle_edit_text')),
        content: TextField(
          controller: controller,
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
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(i18n.tr('save')),
          ),
        ],
      ),
    );
    controller.dispose();
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
    final startController = TextEditingController(text: _formatTime(cue.start));
    final endController = TextEditingController(text: _formatTime(cue.end));
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
              TextField(
                controller: startController,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                  labelText: i18n.tr('subtitle_start_time'),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: endController,
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
                final start = _parseTime(startController.text);
                final end = _parseTime(endController.text);
                final previousEnd = index == 0
                    ? Duration.zero
                    : _cues![index - 1].end;
                final nextStart = index + 1 == _cues!.length
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
    startController.dispose();
    endController.dispose();
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

  Future<void> _save() async {
    if (!_dirty || _saving || _cues == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(playbackSubtitleServiceProvider)
          .saveEditedSubtitle(widget.trackPath, _cues!);
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ref.read(appLanguageProviderInstanceProvider).tr('subtitle_saved'),
          ),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _errorKey = 'subtitle_save_failed');
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
                  ? Center(child: Text(i18n.tr('subtitle_no_content')))
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(16, contentTopInset, 16, 16),
                      itemCount: _cues!.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final cue = _cues![index];
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  key: ValueKey('subtitle_text_$index'),
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () => _editText(index),
                                  child: Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Text(cue.text),
                                  ),
                                ),
                              ),
                              InkWell(
                                key: ValueKey('subtitle_time_$index'),
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _editTime(index),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(_formatTime(cue.start)),
                                      Text(_formatTime(cue.end)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
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
                  onPressed: _dirty && !_saving ? _save : null,
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
