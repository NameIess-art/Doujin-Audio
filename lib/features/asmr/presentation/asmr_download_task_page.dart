import 'asmr_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../application/asmr_download_models.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/top_page_header.dart';
import 'asmr_download_details_page.dart';

import 'asmr_download_task_card.dart';

class AsmrDownloadTaskPage extends ConsumerStatefulWidget {
  const AsmrDownloadTaskPage({super.key});

  @override
  ConsumerState<AsmrDownloadTaskPage> createState() =>
      _AsmrDownloadTaskPageState();
}

class _AsmrDownloadTaskPageState extends ConsumerState<AsmrDownloadTaskPage> {
  Future<void>? _initialization;
  bool _exitScheduled = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  void _initialize() {
    _initialization = ref.read(asmrDownloadManagerProvider)?.initialize();
    // The deferred builder may subscribe after recovery fails; its FutureBuilder
    // still receives that failure and presents retry without an unhandled error.
    _initialization?.ignore();
  }

  void _exitWhenEmpty() {
    if (_exitScheduled || !Navigator.of(context).canPop()) return;
    _exitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _exitScheduled = false;
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final manager = ref.read(asmrDownloadManagerProvider);
      if (manager != null && !manager.persistedUriReferencesReady) return;
      final taskIds =
          ref.read(asmrDownloadTaskIdsProvider).value ??
          manager?.taskIds ??
          const <String>[];
      if (taskIds.isNotEmpty) return;
      unawaited(Navigator.of(context).maybePop());
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final contentTopInset = AppPageHeaderMetrics.contentTopInset(context);
    final listPadding = EdgeInsets.fromLTRB(
      16,
      contentTopInset,
      16,
      MediaQuery.paddingOf(context).bottom + 16,
    );
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: PageHeaderInset(
        topInset: contentTopInset,
        child: Stack(
          children: [
            FutureBuilder<void>(
              future: _initialization,
              builder: (context, snapshot) {
                final manager = ref.read(asmrDownloadManagerProvider);
                final recovering =
                    manager != null && !manager.persistedUriReferencesReady;
                final failed =
                    snapshot.connectionState == ConnectionState.done &&
                    snapshot.hasError;
                if (recovering && failed) {
                  return AppPageContentTransition(
                    child: Padding(
                      padding: listPadding,
                      child: OperationStatusBanner(
                        label: i18n.tr('asmr_detail_load_failed'),
                        error: snapshot.error,
                        retryTooltip: i18n.tr('retry'),
                        onRetry: () => setState(_initialize),
                      ),
                    ),
                  );
                }
                return AppPageContentTransition(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final state = ref
                          .watch(asmrDownloadTaskIdsProvider)
                          .value;
                      final taskIds =
                          state ??
                          ref.read(asmrDownloadManagerProvider)?.taskIds ??
                          const <String>[];
                      if (taskIds.isEmpty &&
                          !recovering &&
                          !failed &&
                          isCurrent) {
                        _exitWhenEmpty();
                      }
                      return taskIds.isEmpty
                          ? Center(
                              child: Text(
                                i18n.tr('asmr_download_no_tasks'),
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            )
                          : ListView.builder(
                              padding: listPadding,
                              physics: const ClampingScrollPhysics(),
                              itemCount: taskIds.length,
                              itemBuilder: (context, index) {
                                return _DownloadTaskItem(
                                  workId: taskIds[index],
                                );
                              },
                            );
                    },
                  ),
                );
              },
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                icon: Icons.download_done_rounded,
                iconColor: Theme.of(context).colorScheme.primary,
                leading: const BackButton(),
                title: i18n.tr('asmr_download_task_title'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _TaskRemovalAction { removeEntry, deleteDownloaded }

Future<_TaskRemovalAction?> _showTaskRemovalMenu(
  BuildContext context, {
  required String title,
  required String removeEntryLabel,
  required String deleteDownloadedLabel,
}) {
  return AppBottomSheet.show<_TaskRemovalAction>(
    context: context,
    isScrollControlled: false,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        top: false,
        child: Padding(
          padding: AppBottomSheet.contentPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AppBottomSheetHeader(
                  icon: Icons.delete_outline_rounded,
                  title: title,
                ),
              ),
              ListTile(
                key: const ValueKey<String>(
                  'asmr_download_remove_entry_option',
                ),
                leading: const Icon(Icons.remove_circle_outline_rounded),
                title: Text(removeEntryLabel),
                onTap: () => Navigator.of(
                  sheetContext,
                ).pop(_TaskRemovalAction.removeEntry),
              ),
              ListTile(
                key: const ValueKey<String>(
                  'asmr_download_delete_downloaded_option',
                ),
                leading: Icon(Icons.delete_forever_rounded, color: cs.error),
                title: Text(
                  deleteDownloadedLabel,
                  style: TextStyle(color: cs.error),
                ),
                onTap: () => Navigator.of(
                  sheetContext,
                ).pop(_TaskRemovalAction.deleteDownloaded),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _DownloadTaskItem extends ConsumerWidget {
  const _DownloadTaskItem({required this.workId});
  final String workId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(asmrDownloadTaskProvider(workId));
    final manager = ref.read(asmrDownloadManagerProvider);
    if (task == null || manager == null) return const SizedBox.shrink();
    final ready = ref.watch(coreRuntimeReadyProvider);
    ref.watch(appLanguageStateProvider);
    final language = ref.read(appLanguageProviderInstanceProvider);
    return AsmrDownloadTaskCard(
      task: task,
      i18n: language,
      onOpen: () => Navigator.of(context).push(
        buildAppPageRoute<void>(
          context: context,
          child: AsmrDownloadDetailsPage(workId: workId),
        ),
      ),
      onTogglePause: !ready
          ? null
          : () {
              if (task.status == AsmrDownloadTaskStatus.paused ||
                  task.status == AsmrDownloadTaskStatus.failed) {
                manager.resumeTask(workId);
              } else {
                manager.pauseTask(workId);
              }
            },
      onRemove: !ready
          ? null
          : () async {
              final action = await _showTaskRemovalMenu(
                context,
                title: language.tr('asmr_download_remove_task'),
                removeEntryLabel: language.tr('asmr_download_remove_entry'),
                deleteDownloadedLabel: language.tr(
                  'asmr_download_remove_and_delete',
                ),
              );
              if (!context.mounted || action == null) return;
              try {
                if (action == _TaskRemovalAction.removeEntry) {
                  await manager.cancelTask(workId, deleteDownloaded: false);
                } else {
                  await manager.deleteTask(workId);
                }
              } catch (_) {
                if (!context.mounted) return;
                showAppSnackBar(
                  context,
                  language.tr('removal_failed'),
                  tone: AppFeedbackTone.destructive,
                  icon: Icons.error_outline_rounded,
                );
                return;
              }
              if (!context.mounted) return;
              showAppSnackBar(
                context,
                language.tr(
                  action == _TaskRemovalAction.removeEntry
                      ? 'asmr_download_task_removed'
                      : 'asmr_download_task_removed_and_deleted',
                ),
                tone: AppFeedbackTone.destructive,
                icon: action == _TaskRemovalAction.removeEntry
                    ? Icons.remove_circle_outline_rounded
                    : Icons.delete_sweep_rounded,
              );
            },
    );
  }
}
