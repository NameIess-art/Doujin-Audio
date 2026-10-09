import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lottie/lottie.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../application/library_scanner_service.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../app/presentation/screen_view_models.dart';
import '../../../app/theme/app_styles.dart';

import '../../../core/widgets/app_buttons.dart';

class LibraryScanCountChip extends StatelessWidget {
  const LibraryScanCountChip({
    super.key,
    required this.label,
    required this.count,
    required this.color,
  });

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(AppRadius.small),
      ),
      child: Text(
        '$label: $count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class LibraryEmptyState extends StatelessWidget {
  const LibraryEmptyState({
    super.key,
    required this.onImportLibrary,
    required this.onImportFolder,
    required this.onImportFile,
    required this.isBusy,
    required this.bottomInset,
    this.topInset = AppSpacing.md,
    this.physics,
  });

  final VoidCallback onImportLibrary;
  final VoidCallback onImportFolder;
  final VoidCallback onImportFile;
  final bool isBusy;
  final double bottomInset;
  final double topInset;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight - topInset - bottomInset;
        return ListView(
          primary: false,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.xl,
            topInset,
            AppSpacing.xl,
            bottomInset,
          ),
          physics: physics ?? const ClampingScrollPhysics(),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: availableHeight > 0 ? availableHeight : 0,
              ),
              child: Center(
                child: Container(
                  key: const ValueKey('library_empty_state_card'),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: AppRadius.borderDialog,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        cs.surfaceContainerHigh.withValues(alpha: 0.6),
                        cs.surfaceContainerLow.withValues(alpha: 0.4),
                      ],
                    ),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                      vertical: 42,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Lottie.asset(
                          'assets/lottie/empty_library.json',
                          width: 140,
                          height: 140,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    cs.primaryContainer,
                                    cs.primaryContainer.withValues(alpha: 0.8),
                                  ],
                                ),
                                borderRadius: AppRadius.borderMedium,
                                boxShadow: [
                                  BoxShadow(
                                    color: cs.primary.withValues(alpha: 0.12),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.audio_file_rounded,
                                size: 36,
                                color: cs.onPrimaryContainer,
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: AppSpacing.xl),
                        Text(
                          i18n.tr('no_audio_files'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                              ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          i18n.tr('import_audio_hint'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: cs.onSurfaceVariant,
                                height: 1.4,
                              ),
                        ),
                        const SizedBox(height: 28),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 220,
                              child: AppSecondaryButton(
                                onPressed: isBusy ? null : onImportFolder,
                                isLoading: isBusy,
                                icon: Icons.create_new_folder_rounded,
                                label: i18n.tr('import_folder'),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            SizedBox(
                              width: 220,
                              child: AppSecondaryButton(
                                onPressed: isBusy ? null : onImportFile,
                                icon: Icons.upload_file_rounded,
                                label: i18n.tr('import_file'),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            SizedBox(
                              width: 220,
                              child: AppSecondaryButton(
                                onPressed: isBusy ? null : onImportLibrary,
                                icon: Icons.library_add_rounded,
                                label: i18n.tr('import_library'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class LibraryLoadingSkeleton extends ConsumerWidget {
  const LibraryLoadingSkeleton({
    super.key,
    required this.bottomInset,
    required this.topInset,
  });

  final double bottomInset;
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LibrarySkeletonListView(
      topInset: topInset,
      bottomInset: bottomInset,
    );
  }
}

class LibraryScanProgressCard extends StatelessWidget {
  const LibraryScanProgressCard({
    super.key,
    required this.i18n,
    required this.scanState,
    required this.onCancel,
  });
  final AppLanguageProvider i18n;
  final LibraryScanUiState scanState;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) {
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
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
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
                    onPressed: onCancel,
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
                  LibraryScanCountChip(
                    label: i18n.tr('scan_found'),
                    count: scanState.foundCount,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  LibraryScanCountChip(
                    label: i18n.tr('scan_duplicate'),
                    count: scanState.duplicateCount,
                    color: cs.tertiary,
                  ),
                  const SizedBox(width: 8),
                  LibraryScanCountChip(
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
