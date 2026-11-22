import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/widgets/app_buttons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/widgets/app_dialog.dart';
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
  bool _cancelled = false;
  Object? _lastError;

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
      _cancelled = false;
      _lastError = null;
    });
    try {
      await widget.store.ensure(widget.spec, isCancelled: () => _cancelled);
      if (mounted) Navigator.of(context).pop(true);
    } on SubtitleModelDownloadCancelled {
      if (mounted) {
        setState(() {
          _failed = false;
          _lastError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _lastError = error;
        });
      }
    } finally {
      if (mounted) setState(() => _waiting = false);
    }
  }

  void _cancelDownload() {
    _cancelled = true;
    widget.store.cancelDownload(widget.spec);
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final free = widget.status.availableBytes == null
        ? i18n.tr('subtitle_model_space_unknown')
        : '${(widget.status.availableBytes! / 1048576).ceil()} MiB';
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final progress = widget.store.snapshot(widget.spec);
        final downloading = progress.active || _waiting;
        final errorObject = progress.error ?? _lastError;
        final showError =
            !downloading &&
            (_failed ||
                (errorObject != null &&
                    errorObject is! SubtitleModelDownloadCancelled));
        final errorDetail =
            errorObject != null &&
                errorObject is! SubtitleModelDownloadCancelled
            ? errorObject.toString().trim()
            : '';
        return AppDialog(
          title: i18n.tr('subtitle_model_download_title'),
          icon: Icons.download_rounded,
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
              if (showError) ...[
                const SizedBox(height: 12),
                Text(
                  i18n.tr('subtitle_model_download_failed'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                if (errorDetail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    errorDetail,
                    key: const ValueKey('subtitle_model_download_error_detail'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
          actions: AppDialogActions(
            children: [
              if (downloading) ...[
                AppSecondaryButton(
                  key: const ValueKey('subtitle_model_cancel_download'),
                  isDestructive: true,
                  onPressed: _cancelDownload,
                  label: i18n.tr('cancel'),
                ),
                AppPrimaryButton(
                  onPressed: () => Navigator.pop(context, true),
                  label: i18n.tr('subtitle_download_in_background'),
                ),
              ] else ...[
                AppSecondaryButton(
                  onPressed: () => Navigator.pop(context, false),
                  label: i18n.tr('cancel'),
                ),
                AppPrimaryButton(
                  onPressed: _observeDownload,
                  label: i18n.tr(showError ? 'retry' : 'confirm'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
