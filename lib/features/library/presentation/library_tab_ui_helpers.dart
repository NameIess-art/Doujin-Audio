part of 'library_tab.dart';

enum _LibraryRemovalTarget { track, folder, library }

UndoableRemovalKey _libraryRemovalKey(String targetPath) =>
    UndoableRemovalKey('library', PathMatcher.normalize(targetPath));

Future<bool> _stageLibraryRemoval(
  BuildContext context,
  WidgetRef ref, {
  required String targetPath,
  required _LibraryRemovalTarget target,
}) async {
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  final messageKey = switch (target) {
    _LibraryRemovalTarget.track => 'audio_removed',
    _LibraryRemovalTarget.folder => 'folder_removed',
    _LibraryRemovalTarget.library => 'library_removed',
  };
  final library = ref.read(libraryFacadeProvider);
  return showUndoableRemovalFeedback(
    context,
    service: ref.read(undoableRemovalServiceProvider),
    action: UndoableRemovalAction(
      key: _libraryRemovalKey(targetPath),
      commit: () async {
        final result = target == _LibraryRemovalTarget.track
            ? await library.removeTrack(targetPath)
            : await library.removeFolder(targetPath);
        if (result == null) throw StateError('Library removal failed.');
      },
      undo: () {},
    ),
    message: i18n.tr(messageKey),
    batchMessage: (count) => i18n.tr('items_removed_count', {'count': count}),
    undoLabel: i18n.tr('undo'),
    failureMessage: i18n.tr('removal_failed'),
  );
}

extension _LibraryTabUiHelpers on _LibraryTabState {
  Widget _buildScanProgressCard(
    AppLanguageProvider i18n,
    LibraryScanUiState scanState,
  ) {
    final cs = Theme.of(context).colorScheme;
    final total = scanState.total;
    final progress = total != null && total > 0
        ? (scanState.processed / total).clamp(0.0, 1.0)
        : null;
    final stageLabel = i18n.tr(switch (scanState.stage) {
      FolderScanStage.preparing => 'scan_stage_preparing',
      FolderScanStage.enumerating => 'scan_stage_enumerating',
      FolderScanStage.merging => 'scan_stage_merging',
      FolderScanStage.saving => 'scan_stage_saving',
      FolderScanStage.loadingCovers => 'scan_stage_covers',
      FolderScanStage.idle => 'scanning_title',
    });
    final tokens = AppDesignTokens.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      label: stageLabel,
      child: Card(
        key: const ValueKey('library_scan_progress_card'),
        elevation: 4,
        shadowColor: cs.shadow,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Text(
                        stageLabel,
                        key: ValueKey(scanState.stage),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _scanCoordinator.cancel(
                      ref.read(libraryFacadeProvider),
                    ),
                    icon: Icon(Icons.close_rounded, size: 16, color: cs.error),
                    label: Text(
                      i18n.tr('scan_cancel'),
                      style: TextStyle(color: cs.error, fontSize: 12),
                    ),
                  ),
                ],
              ),
              if (scanState.source.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.folder_open_rounded,
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        scanState.source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                borderRadius: BorderRadius.circular(99),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  total == null
                      ? i18n.tr('scan_processed', {
                          'processed': scanState.processed,
                        })
                      : i18n.tr('scan_processed_total', {
                          'processed': scanState.processed,
                          'total': total,
                        }),
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _ScanCountChip(
                    label: i18n.tr('scan_found'),
                    count: scanState.foundCount,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  _ScanCountChip(
                    label: i18n.tr('scan_duplicate'),
                    count: scanState.duplicateCount,
                    color: cs.tertiary,
                  ),
                  const SizedBox(width: 8),
                  _ScanCountChip(
                    label: i18n.tr('scan_failure'),
                    count: scanState.failureCount,
                    color: cs.error,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
