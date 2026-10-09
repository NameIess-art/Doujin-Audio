import 'asmr_providers.dart';
import 'asmr_theme.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../application/asmr_download_models.dart';
import '../../../core/ui/undoable_removal_service.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/top_page_header.dart';
import 'asmr_download_details_page.dart';

import 'asmr_download_task_card.dart';

class AsmrDownloadTaskPage extends ConsumerWidget {
  const AsmrDownloadTaskPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final headerHeight = MediaQuery.paddingOf(context).top + 56;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: PageHeaderInset(
        topInset: headerHeight + 16,
        child: Stack(
          children: [
            AppPageContentTransition.deferred(
              placeholder: OperationSkeletonList(
                showHeader: false,
                padding: EdgeInsets.fromLTRB(
                  16,
                  headerHeight + 16,
                  16,
                  MediaQuery.paddingOf(context).bottom + 16,
                ),
              ),
              builder: (context) => Consumer(
                builder: (context, ref, _) {
                  final state = ref.watch(asmrDownloadTaskIdsProvider).value;
                  final removalState = ref.watch(undoableRemovalStateProvider);
                  final taskIds =
                      (state ??
                              ref.read(asmrDownloadManagerProvider)?.taskIds ??
                              const <int>[])
                          .where(
                            (workId) => !removalState.isHidden(
                              _asmrDownloadTaskRemovalKey(workId),
                            ),
                          )
                          .toList(growable: false);
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
                          padding: EdgeInsets.fromLTRB(
                            16,
                            headerHeight + 16,
                            16,
                            MediaQuery.paddingOf(context).bottom + 16,
                          ),
                          physics: const ClampingScrollPhysics(),
                          itemCount: taskIds.length,
                          itemBuilder: (context, index) {
                            return _DownloadTaskItem(workId: taskIds[index]);
                          },
                        );
                },
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Theme(
                data: asmrThemeData(context),
                child: TopPageHeader(
                  icon: Icons.download_done_rounded,
                  iconColor: AppDesignTokens.of(context).asmrAccent,
                  leading: const BackButton(),
                  title: i18n.tr('asmr_download_task_title'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _TaskRemovalAction { removeEntry, deleteDownloaded }

UndoableRemovalKey _asmrDownloadTaskRemovalKey(int workId) =>
    UndoableRemovalKey('asmr-download-task', '$workId');

Future<void> _stageAsmrDownloadTaskRemoval(
  BuildContext context,
  WidgetRef ref, {
  required AsmrDownloadTaskSnapshot task,
  required _TaskRemovalAction removalAction,
}) async {
  final manager = ref.read(asmrDownloadManagerProvider);
  if (manager == null) return;
  final service = ref.read(undoableRemovalServiceProvider);
  final wasRunning =
      task.status == AsmrDownloadTaskStatus.idle || task.isActive;
  await showUndoableRemovalFeedback(
    context,
    service: service,
    action: UndoableRemovalAction(
      key: _asmrDownloadTaskRemovalKey(task.work.id),
      prepare: () async {
        if (wasRunning) await manager.pauseTask(task.work.id);
        return manager.getTask(task.work.id) != null;
      },
      undo: () async {
        if (wasRunning && manager.getTask(task.work.id) != null) {
          await manager.resumeTask(task.work.id);
        }
      },
      commit: () => removalAction == _TaskRemovalAction.removeEntry
          ? manager.cancelTask(task.work.id, deleteDownloaded: false)
          : manager.deleteTask(task.work.id),
    ),
    message: ref
        .read(appLanguageProviderInstanceProvider)
        .tr(
          removalAction == _TaskRemovalAction.removeEntry
              ? 'asmr_download_task_removed'
              : 'asmr_download_task_removed_and_deleted',
        ),
    batchMessage: (count) => ref.read(appLanguageProviderInstanceProvider).tr(
      'items_removed_count',
      {'count': count},
    ),
    undoLabel: ref.read(appLanguageProviderInstanceProvider).tr('undo'),
    failureMessage: ref
        .read(appLanguageProviderInstanceProvider)
        .tr('removal_failed'),
    icon: removalAction == _TaskRemovalAction.removeEntry
        ? Icons.remove_circle_outline_rounded
        : Icons.delete_sweep_rounded,
  );
}

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
  final int workId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(asmrDownloadTaskProvider(workId));
    final manager = ref.read(asmrDownloadManagerProvider);
    if (task == null || manager == null) return const SizedBox.shrink();
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
      onTogglePause: () {
        if (task.status == AsmrDownloadTaskStatus.paused) {
          manager.resumeTask(workId);
        } else {
          manager.pauseTask(workId);
        }
      },
      onRemove: () async {
        final action = await _showTaskRemovalMenu(
          context,
          title: language.tr('asmr_download_remove_task'),
          removeEntryLabel: language.tr('asmr_download_remove_entry'),
          deleteDownloadedLabel: language.tr('asmr_download_remove_and_delete'),
        );
        if (!context.mounted || action == null) return;
        await _stageAsmrDownloadTaskRemoval(
          context,
          ref,
          task: task,
          removalAction: action,
        );
      },
    );
  }
}
