import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../widgets/app_feedback.dart';

class DlsiteMetadataReviewPage extends StatefulWidget {
  const DlsiteMetadataReviewPage({
    super.key,
    required this.detail,
    this.rjCode,
    this.searchTitles = const <String>[],
  }) : assert(rjCode != null || searchTitles.length > 0);

  final AudioDetail detail;
  final String? rjCode;
  final List<String> searchTitles;

  @override
  State<DlsiteMetadataReviewPage> createState() =>
      _DlsiteMetadataReviewPageState();
}

class _DlsiteMetadataReviewPageState extends State<DlsiteMetadataReviewPage> {
  final _titleController = TextEditingController();
  final _circleController = TextEditingController();
  final _voiceActorsController = TextEditingController();
  final _tagsController = TextEditingController();

  DlsiteMetadata? _metadata;
  List<DlsiteMetadata> _candidates = const <DlsiteMetadata>[];
  int _candidateIndex = 0;
  Object? _error;
  bool _loading = true;
  bool _saving = false;
  bool _saveCover = true;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _circleController.dispose();
    _voiceActorsController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
      _metadata = null;
      _candidates = const <DlsiteMetadata>[];
      _candidateIndex = 0;
    });
    try {
      final provider = context.read<AudioProvider>();
      final rjCode = widget.rjCode;
      final candidates = rjCode != null
          ? <DlsiteMetadata>[await provider.fetchDlsiteMetadata(rjCode)]
          : await provider.searchDlsiteMetadataByTitles(widget.searchTitles);
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
    _titleController.text = metadata.workTitle;
    _circleController.text = metadata.circleName;
    _voiceActorsController.text = metadata.voiceActors.join('\uFF0C');
    _tagsController.text = metadata.tags.join('\uFF0C');
    setState(() {
      _candidateIndex = nextIndex;
      _candidates = nextCandidates;
      _metadata = metadata;
      _loading = false;
      _saveCover =
          widget.detail.target.isLibraryRootFolder && metadata.coverUrl != null;
    });
  }

  Future<void> _apply() async {
    final metadata = _metadata;
    if (metadata == null || _saving) return;
    setState(() {
      _saving = true;
    });
    final edited = metadata.copyWith(
      workTitle: _titleController.text.trim(),
      circleName: _circleController.text.trim(),
      voiceActors: AudioDetail.normalizeList(
        _voiceActorsController.text.split('\uFF0C'),
      ),
      tags: AudioDetail.normalizeList(_tagsController.text.split('\uFF0C')),
    );

    try {
      final result = await context.read<AudioProvider>().applyDlsiteMetadata(
        widget.detail,
        edited,
        saveCover: _saveCover,
      );
      if (!mounted) return;
      if (result.coverFailed) {
        showAppSnackBar(
          context,
          context.read<AppLanguageProvider>().tr('dlsite_cover_save_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
      Navigator.of(context).pop(result.detail);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
      });
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final metadata = _metadata;
    final coverUrl = widget.detail.target.isLibraryRootFolder
        ? metadata?.coverUrl
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(i18n.tr('dlsite_review_title')),
        actions: [
          if (_candidates.length > 1 && !_loading)
            IconButton(
              onPressed: _candidateIndex <= 0 || _saving
                  ? null
                  : () => _showCandidate(_candidateIndex - 1),
              tooltip: i18n.tr('previous'),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
          if (_candidates.length > 1 && !_loading)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text('${_candidateIndex + 1}/${_candidates.length}'),
              ),
            ),
          if (_candidates.length > 1 && !_loading)
            IconButton(
              onPressed: _candidateIndex >= _candidates.length - 1 || _saving
                  ? null
                  : () => _showCandidate(_candidateIndex + 1),
              tooltip: i18n.tr('next'),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _DlsiteErrorView(onRetry: _fetch)
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  if (coverUrl != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: AspectRatio(
                        aspectRatio: 4 / 3,
                        child: Image.network(
                          coverUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => ColoredBox(
                            color: cs.surfaceContainerHighest,
                            child: Icon(
                              Icons.image_not_supported_rounded,
                              color: cs.onSurfaceVariant,
                              size: 48,
                            ),
                          ),
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
                  _ReviewTextField(
                    controller: _titleController,
                    label: i18n.tr('audio_detail_work_title'),
                  ),
                  if ((metadata?.rjCode.trim().isNotEmpty ?? false)) ...[
                    _ReviewInfoLine(
                      label: i18n.tr('audio_detail_rj_code'),
                      value: metadata!.rjCode.trim(),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _ReviewTextField(
                    controller: _circleController,
                    label: i18n.tr('audio_detail_circle_name'),
                  ),
                  _ReviewTextField(
                    controller: _voiceActorsController,
                    label: i18n.tr('audio_detail_voice_actors'),
                    hint: i18n.tr('audio_detail_multi_hint'),
                  ),
                  _ReviewTextField(
                    controller: _tagsController,
                    label: i18n.tr('audio_detail_tags'),
                    hint: i18n.tr('audio_detail_multi_hint'),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _saving ? null : _apply,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(i18n.tr('confirm')),
                  ),
                ],
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
  const _DlsiteErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
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
          ],
        ),
      ),
    );
  }
}
