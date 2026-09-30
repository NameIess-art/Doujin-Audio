import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_dialog.dart';
import '../application/dlsite_metadata_batch_session.dart';
import '../domain/audio_library_category.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';

import 'dlsite_metadata_batch_review_page.dart';

class DlsiteMetadataBatchResultsPage extends StatefulWidget {
  const DlsiteMetadataBatchResultsPage({super.key, required this.session});

  final DlsiteMetadataBatchSession session;

  @override
  State<DlsiteMetadataBatchResultsPage> createState() =>
      _DlsiteMetadataBatchResultsPageState();
}

class _DlsiteMetadataBatchResultsPageState
    extends State<DlsiteMetadataBatchResultsPage> {
  bool _savingAll = false;
  final List<Timer> _pendingTimers = <Timer>[];

  @override
  void initState() {
    super.initState();
    widget.session.start();
  }

  @override
  void dispose() {
    for (final timer in _pendingTimers) {
      timer.cancel();
    }
    _pendingTimers.clear();
    widget.session.dispose();
    super.dispose();
  }

  Future<void> _handleItemTap(int index) async {
    final item = widget.session.items[index];
    if (item.isExcluded) return;
    if (item.isReviewable) {
      await Navigator.of(context).push<void>(
        buildAppPageRoute(
          context: context,
          fadeHeader: false,
          child: DlsiteMetadataBatchReviewPage(
            session: widget.session,
            initialIndex: index,
          ),
        ),
      );
      return;
    }
    if (item.status != DlsiteMetadataBatchLookupStatus.searching) {
      widget.session.retry(index);
    }
  }

  Future<void> _saveAll() async {
    if (_savingAll || widget.session.hasPendingLookups) return;
    setState(() {
      _savingAll = true;
    });
    final result = await widget.session.applyConfirmed();
    if (!mounted) return;
    setState(() {
      _savingAll = false;
    });
    await showAppDialog<void>(
      context: context,
      builder: (_) => _BatchMetadataCompletionDialog(result: result),
    );
    if (!mounted || result.failedCount > 0) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final topInset = AppPageHeaderMetrics.contentTopInset(context);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: PageHeaderInset(
        topInset: topInset,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                child: AnimatedBuilder(
                  animation: widget.session,
                  builder: (context, _) {
                    final items = widget.session.items;
                    return ListView.builder(
                      key: const ValueKey<String>(
                        'batch_metadata_results_list',
                      ),
                      padding: EdgeInsets.fromLTRB(
                        16,
                        AppPageHeaderMetrics.contentTopInset(context),
                        16,
                        78 + MediaQuery.paddingOf(context).bottom,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final entry = item.entry;
                        final title = entry.detail.workTitle.isNotEmpty
                            ? entry.detail.workTitle
                            : entry.title;
                        final isExcluded = item.isExcluded;
                        final cs = Theme.of(context).colorScheme;
                        return Dismissible(
                          key: ValueKey<String>(
                            'batch_metadata_dismissible_${AudioLibraryCategorySnapshot.targetKey(entry.target)}',
                          ),
                          direction: DismissDirection.endToStart,
                          confirmDismiss: (direction) async {
                            if (direction == DismissDirection.endToStart) {
                              late final Timer timer;
                              timer = Timer(
                                const Duration(milliseconds: 220),
                                () {
                                  _pendingTimers.remove(timer);
                                  if (mounted) {
                                    widget.session.toggleExcluded(index);
                                  }
                                },
                              );
                              _pendingTimers.add(timer);
                            }
                            return false;
                          },
                          background: const SizedBox.shrink(),
                          secondaryBackground: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            decoration: BoxDecoration(
                              color: isExcluded
                                  ? cs.surfaceContainerHighest
                                  : cs.errorContainer.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isExcluded
                                      ? Icons.undo_rounded
                                      : Icons.block_rounded,
                                  color: isExcluded
                                      ? cs.onSurface
                                      : cs.onErrorContainer,
                                  size: 20,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  isExcluded
                                      ? i18n.tr('batch_metadata_action_restore')
                                      : i18n.tr(
                                          'batch_metadata_action_exclude',
                                        ),
                                  style: TextStyle(
                                    color: isExcluded
                                        ? cs.onSurface
                                        : cs.onErrorContainer,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          child: ColorFiltered(
                            colorFilter: isExcluded
                                ? const ColorFilter.matrix(<double>[
                                    0.2126,
                                    0.7152,
                                    0.0722,
                                    0,
                                    0,
                                    0.2126,
                                    0.7152,
                                    0.0722,
                                    0,
                                    0,
                                    0.2126,
                                    0.7152,
                                    0.0722,
                                    0,
                                    0,
                                    0,
                                    0,
                                    0,
                                    1,
                                    0,
                                  ])
                                : const ColorFilter.mode(
                                    Colors.transparent,
                                    BlendMode.dst,
                                  ),
                            child: Opacity(
                              opacity: isExcluded ? 0.38 : 1.0,
                              child: ListTile(
                                key: ValueKey<String>(
                                  'batch_metadata_result_$index',
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                title: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: isExcluded
                                      ? TextStyle(
                                          color: cs.onSurface.withValues(
                                            alpha: 0.38,
                                          ),
                                        )
                                      : null,
                                ),
                                subtitle: entry.detail.rjCode.isEmpty
                                    ? null
                                    : Text(
                                        entry.detail.rjCode,
                                        style: isExcluded
                                            ? TextStyle(
                                                color: cs.onSurfaceVariant
                                                    .withValues(alpha: 0.38),
                                              )
                                            : null,
                                      ),
                                trailing: _BatchMetadataStatusIcon(
                                  key: ValueKey<String>(
                                    'batch_metadata_status_$index',
                                  ),
                                  status: item.status,
                                  isExcluded: isExcluded,
                                ),
                                onTap: isExcluded
                                    ? null
                                    : () => _handleItemTap(index),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: const ValueKey<String>('batch_metadata_results_header'),
                icon: Icons.library_add_check_rounded,
                title: i18n.tr('batch_metadata'),
                leading: const BackButton(),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              child: AppPageContentTransition(
                child: AnimatedBuilder(
                  animation: widget.session,
                  builder: (context, _) => HeaderFloatingSurface(
                    key: const ValueKey<String>('batch_metadata_results_done'),
                    height: 46,
                    radius: 23,
                    padding: EdgeInsets.zero,
                    child: Material(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(23),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(23),
                        onTap: _savingAll || widget.session.hasPendingLookups
                            ? null
                            : _saveAll,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _savingAll
                                  ? SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onPrimary,
                                      ),
                                    )
                                  : Icon(
                                      Icons.check_rounded,
                                      size: 18,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimary,
                                    ),
                              const SizedBox(width: 6),
                              Text(
                                i18n.tr('confirm'),
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BatchMetadataCompletionDialog extends StatelessWidget {
  const _BatchMetadataCompletionDialog({required this.result});

  final DlsiteMetadataBatchApplyResult result;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return AppDialog(
      key: const ValueKey<String>('batch_metadata_completion_dialog'),
      title: i18n.tr('batch_metadata_completion_title'),
      icon: Icons.task_alt_rounded,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            i18n.tr('batch_metadata_completion_saved', {
              'count': result.savedCount.toString(),
            }),
            key: const ValueKey<String>('batch_metadata_completion_saved'),
          ),
          const SizedBox(height: 8),
          Text(
            i18n.tr('batch_metadata_completion_skipped', {
              'count': result.skippedCount.toString(),
            }),
            key: const ValueKey<String>('batch_metadata_completion_skipped'),
          ),
          const SizedBox(height: 8),
          Text(
            i18n.tr('batch_metadata_completion_failed', {
              'count': result.failedCount.toString(),
            }),
            key: const ValueKey<String>('batch_metadata_completion_failed'),
          ),
        ],
      ),
      actions: AppDialogActions(
        children: [
          AppPrimaryButton(
            key: const ValueKey<String>('batch_metadata_completion_confirm'),
            onPressed: () => Navigator.of(context).pop(),
            label: i18n.tr('confirm'),
          ),
        ],
      ),
    );
  }
}

class _BatchMetadataStatusIcon extends StatelessWidget {
  const _BatchMetadataStatusIcon({
    super.key,
    required this.status,
    this.isExcluded = false,
  });

  final DlsiteMetadataBatchLookupStatus status;
  final bool isExcluded;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    if (isExcluded) {
      final label = i18n.tr('batch_metadata_status_excluded');
      return Tooltip(
        message: label,
        child: Semantics(
          label: label,
          child: Icon(Icons.block_rounded, color: cs.outline, size: 22),
        ),
      );
    }
    if (status == DlsiteMetadataBatchLookupStatus.searching) {
      final label = i18n.tr('batch_metadata_status_searching');
      return Tooltip(
        message: label,
        child: Semantics(
          label: label,
          child: _RotatingBatchMetadataStatusIcon(color: cs.primary),
        ),
      );
    }
    final (IconData icon, Color color, String label) = switch (status) {
      DlsiteMetadataBatchLookupStatus.found => (
        Icons.pending_actions_rounded,
        Colors.orange,
        i18n.tr('batch_metadata_status_found'),
      ),
      DlsiteMetadataBatchLookupStatus.confirmed => (
        Icons.check_circle_rounded,
        Colors.green,
        i18n.tr('batch_metadata_status_confirmed'),
      ),
      DlsiteMetadataBatchLookupStatus.notFound => (
        Icons.search_off_rounded,
        cs.onSurfaceVariant,
        i18n.tr('batch_metadata_status_not_found'),
      ),
      DlsiteMetadataBatchLookupStatus.failed => (
        Icons.error_outline_rounded,
        cs.error,
        i18n.tr('batch_metadata_status_failed'),
      ),
      DlsiteMetadataBatchLookupStatus.searching => throw StateError(
        'Searching status is handled above.',
      ),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }
}

class _RotatingBatchMetadataStatusIcon extends StatefulWidget {
  const _RotatingBatchMetadataStatusIcon({required this.color});

  final Color color;

  @override
  State<_RotatingBatchMetadataStatusIcon> createState() =>
      _RotatingBatchMetadataStatusIconState();
}

class _RotatingBatchMetadataStatusIconState
    extends State<_RotatingBatchMetadataStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _controller,
    child: Icon(Icons.autorenew_rounded, color: widget.color, size: 22),
  );
}
