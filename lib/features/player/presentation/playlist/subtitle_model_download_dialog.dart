import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../application/subtitle_model_store.dart';

class SubtitleModelDownloadDialog extends ConsumerStatefulWidget {
  const SubtitleModelDownloadDialog({
    super.key,
    required this.store,
    required this.spec,
    required this.status,
  });

  final SubtitleModelStore store;
  final SubtitleModelSpec spec;
  final SubtitleModelStatus status;

  @override
  ConsumerState<SubtitleModelDownloadDialog> createState() =>
      _SubtitleModelDownloadDialogState();
}

class _SubtitleModelDownloadDialogState
    extends ConsumerState<SubtitleModelDownloadDialog> {
  bool _waiting = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.store.snapshot(widget.spec).active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_observeDownload());
      });
    }
  }

  Future<void> _observeDownload() async {
    if (_waiting) return;
    setState(() {
      _waiting = true;
      _failed = false;
    });
    try {
      await widget.store.ensure(widget.spec);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _waiting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    final free = widget.status.availableBytes == null
        ? i18n.tr('subtitle_model_space_unknown')
        : '${(widget.status.availableBytes! / 1048576).ceil()} MiB';
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final progress = widget.store.snapshot(widget.spec);
        final downloading = progress.active || _waiting;
        return AlertDialog(
          title: Text(i18n.tr('subtitle_model_download_title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                i18n.tr('subtitle_model_download_message', {
                  'size': '${(widget.status.bytes / 1048576).ceil()} MiB',
                  'free': free,
                }),
              ),
              if (downloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress.fraction),
                const SizedBox(height: 8),
                Text(
                  i18n.tr('subtitle_model_download_progress', {
                    'received': (progress.received / 1048576).toStringAsFixed(
                      1,
                    ),
                    'total': (progress.total / 1048576).toStringAsFixed(1),
                  }),
                ),
              ],
              if (_failed || (progress.error != null && !downloading)) ...[
                const SizedBox(height: 12),
                Text(
                  i18n.tr('subtitle_model_download_failed'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, downloading),
              child: Text(
                i18n.tr(
                  downloading ? 'subtitle_download_in_background' : 'cancel',
                ),
              ),
            ),
            if (!downloading)
              FilledButton(
                onPressed: _observeDownload,
                child: Text(
                  i18n.tr(
                    _failed || progress.error != null ? 'retry' : 'confirm',
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
