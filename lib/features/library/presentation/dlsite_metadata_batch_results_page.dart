import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../application/dlsite_metadata_batch_session.dart';
import '../domain/audio_library_category.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';

import 'dlsite_metadata_batch_review_page.dart';

class DlsiteMetadataBatchResultsPage extends ConsumerStatefulWidget {
  const DlsiteMetadataBatchResultsPage({super.key, required this.session});

  final DlsiteMetadataBatchSession session;

  @override
  ConsumerState<DlsiteMetadataBatchResultsPage> createState() =>
      _DlsiteMetadataBatchResultsPageState();
}

class _DlsiteMetadataBatchResultsPageState
    extends ConsumerState<DlsiteMetadataBatchResultsPage> {
  bool _savingAll = false;
  late Map<String, int> _itemIndexByKey;

  @override
  void initState() {
    super.initState();
    _rebuildItemIndexMap();
    widget.session.start();
  }

  @override
  void didUpdateWidget(covariant DlsiteMetadataBatchResultsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _rebuildItemIndexMap();
    }
  }

  void _rebuildItemIndexMap() {
    final items = widget.session.items;
    _itemIndexByKey = <String, int>{
      for (var i = 0; i < items.length; i++) ...{
        'batch_metadata_swipe_${AudioLibraryCategorySnapshot.targetKey(items[i].entry.target)}':
            i,
        'batch_metadata_context_${AudioLibraryCategorySnapshot.targetKey(items[i].entry.target)}':
            i,
      },
    };
  }

  @override
  void dispose() {
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
    ref.watch(appLanguageStateProvider);
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
                    final maxWidth = AppDesignTokens.of(
                      context,
                    ).readableContentMaxWidth;
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final horizontalPadding = math.max(
                          16.0,
                          (constraints.maxWidth - maxWidth) / 2,
                        );
                        return ListView.builder(
                          key: const ValueKey<String>(
                            'batch_metadata_results_list',
                          ),
                          padding: EdgeInsets.fromLTRB(
                            horizontalPadding,
                            AppPageHeaderMetrics.contentTopInset(context),
                            horizontalPadding,
                            78 +
                                MediaQuery.paddingOf(context).bottom +
                                MobileOverlayInset.of(context),
                          ),
                          itemCount: items.length,
                          findChildIndexCallback: (key) =>
                              key is ValueKey<String>
                              ? _itemIndexByKey[key.value]
                              : null,
                          itemBuilder: (context, index) {
                        final item = items[index];
                        final entry = item.entry;
                        final targetKey =
                            AudioLibraryCategorySnapshot.targetKey(
                              entry.target,
                            );
                        final title = entry.detail.workTitle.isNotEmpty
                            ? entry.detail.workTitle
                            : entry.title;
                        final isExcluded = item.isExcluded;
                        final cs = Theme.of(context).colorScheme;
                        final isWindows =
                            defaultTargetPlatform == TargetPlatform.windows;
                        void toggleExcluded() {
                          if (!_savingAll) widget.session.toggleExcluded(index);
                        }

                        Widget row = Opacity(
                          opacity: isExcluded ? 0.38 : 1.0,
                          child: FileTreeRow(
                            key: ValueKey<String>(
                              'batch_metadata_result_$index',
                            ),
                            minHeight: 48,
                            verticalPadding: 2,
                            reserveSubtitleSpace: true,
                            title: title,
                            subtitle: entry.detail.rjCode.isEmpty
                                ? null
                                : entry.detail.rjCode,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _BatchMetadataStatusIcon(
                                  key: ValueKey<String>(
                                    'batch_metadata_status_$index',
                                  ),
                                  status: item.status,
                                  isExcluded: isExcluded,
                                ),
                                if (isWindows)
                                  IconButton(
                                    key: ValueKey<String>(
                                      'batch_metadata_exclude_$index',
                                    ),
                                    tooltip: i18n.tr(
                                      isExcluded
                                          ? 'batch_metadata_action_restore'
                                          : 'batch_metadata_action_exclude',
                                    ),
                                    onPressed: _savingAll
                                        ? null
                                        : toggleExcluded,
                                    icon: Icon(
                                      isExcluded
                                          ? Icons.undo_rounded
                                          : Icons.block_rounded,
                                    ),
                                  ),
                              ],
                            ),
                            onTap: isExcluded
                                ? null
                                : () => _handleItemTap(index),
                          ),
                        );
                        if (isWindows) {
                          return UnifiedContextMenuRegion(
                            key: ValueKey<String>(
                              'batch_metadata_context_$targetKey',
                            ),
                            enabled: !_savingAll,
                            shape: const RoundedRectangleBorder(
                              borderRadius: FileTreeRow.borderRadius,
                            ),
                            buildEntries: () => [
                              if (!isExcluded &&
                                  item.status !=
                                      DlsiteMetadataBatchLookupStatus.searching)
                                UnifiedMenuEntry.action(
                                  value: () =>
                                      unawaited(_handleItemTap(index)),
                                  icon: item.isReviewable
                                      ? Icons.rate_review_rounded
                                      : Icons.refresh_rounded,
                                  label: i18n.tr(
                                    item.isReviewable
                                        ? 'dlsite_review_title'
                                        : 'retry',
                                  ),
                                ),
                              UnifiedMenuEntry.action(
                                value: toggleExcluded,
                                icon: isExcluded
                                    ? Icons.undo_rounded
                                    : Icons.block_rounded,
                                label: i18n.tr(
                                  isExcluded
                                      ? 'batch_metadata_action_restore'
                                      : 'batch_metadata_action_exclude',
                                ),
                              ),
                            ],
                            child: row,
                          );
                        }
                        final actionLabel = i18n.tr(
                          isExcluded
                              ? 'batch_metadata_action_restore'
                              : 'batch_metadata_action_exclude',
                        );
                        return SwipeRevealCard(
                          key: ValueKey<String>(
                            'batch_metadata_swipe_$targetKey',
                          ),
                          enabled: !_savingAll,
                          shape: const RoundedRectangleBorder(
                            borderRadius: FileTreeRow.borderRadius,
                          ),
                          closedColor: cs.surface,
                          destructive: !isExcluded,
                          primaryActionIcon: isExcluded
                              ? Icons.undo_rounded
                              : Icons.block_rounded,
                          actionLabel: actionLabel,
                          removeTooltip: actionLabel,
                          onRemove: toggleExcluded,
                          child: row,
                        );
                      },
                    ).withWindowsSmoothScroll();
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
                icon: Icons.cloud_download_rounded,
                title: i18n.tr('batch_metadata'),
                leading: const AppHeaderBackButton(),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16 +
                  MediaQuery.paddingOf(context).bottom +
                  MobileOverlayInset.of(context),
              child: AppPageContentTransition(
                child: AnimatedBuilder(
                  animation: widget.session,
                  builder: (context, _) => HeaderFloatingActionPill(
                    pillKey: const ValueKey<String>(
                      'batch_metadata_results_done',
                    ),
                    icon: Icons.check_rounded,
                    label: i18n.tr('confirm'),
                    loading: _savingAll,
                    horizontalPadding: 20,
                    onTap: _savingAll || widget.session.hasPendingLookups
                        ? null
                        : _saveAll,
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

class _BatchMetadataCompletionDialog extends ConsumerWidget {
  const _BatchMetadataCompletionDialog({required this.result});

  final DlsiteMetadataBatchApplyResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
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
    final tokens = AppDesignTokens.of(context);
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
        Icons.pending_rounded,
        tokens.warning,
        i18n.tr('batch_metadata_status_found'),
      ),
      DlsiteMetadataBatchLookupStatus.confirmed => (
        Icons.check_circle_rounded,
        tokens.success,
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
  Widget build(BuildContext context) => RepaintBoundary(
    child: RotationTransition(
      turns: _controller,
      child: Icon(Icons.autorenew_rounded, color: widget.color, size: 22),
    ),
  );
}
