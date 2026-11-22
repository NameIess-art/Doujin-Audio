import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lottie/lottie.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../application/library_scanner_service.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../app/presentation/screen_view_models.dart';
import '../../../app/theme/app_styles.dart';

import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';

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
    this.activeImportScope,
    required this.bottomInset,
    this.topInset = AppSpacing.md,
    this.physics,
  });

  final VoidCallback onImportLibrary;
  final VoidCallback onImportFolder;
  final VoidCallback onImportFile;
  final bool isBusy;
  final UiOperationScope? activeImportScope;
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
          primary: defaultTargetPlatform == TargetPlatform.windows,
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
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
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
                              child: AppPrimaryButton(
                                onPressed: isBusy ? null : onImportFolder,
                                isLoading:
                                    isBusy &&
                                    activeImportScope ==
                                        UiOperationScope.libraryImportFolder,
                                icon: Icons.create_new_folder_rounded,
                                label: i18n.tr('import_folder'),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            SizedBox(
                              width: 220,
                              child: AppSecondaryButton(
                                onPressed: isBusy ? null : onImportFile,
                                isLoading:
                                    isBusy &&
                                    activeImportScope ==
                                        UiOperationScope.libraryImportFiles,
                                icon: Icons.upload_file_rounded,
                                label: i18n.tr('import_file'),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            SizedBox(
                              width: 220,
                              child: AppSecondaryButton(
                                onPressed: isBusy ? null : onImportLibrary,
                                isLoading:
                                    isBusy &&
                                    activeImportScope ==
                                        UiOperationScope.libraryImportLibrary,
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
            ),
          ],
        ).withWindowsSmoothScroll();
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

class LibraryScanProgressCard extends StatefulWidget {
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
  State<LibraryScanProgressCard> createState() =>
      _LibraryScanProgressCardState();
}

class _LibraryScanProgressCardState extends State<LibraryScanProgressCard> {
  bool _cancelling = false;

  @override
  void didUpdateWidget(covariant LibraryScanProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_cancelling &&
        (widget.scanState.stage == FolderScanStage.idle ||
            (oldWidget.scanState.stage == FolderScanStage.idle &&
                widget.scanState.stage != FolderScanStage.idle) ||
            widget.scanState.source != oldWidget.scanState.source)) {
      _cancelling = false;
    }
  }

  void _handleCancel() {
    if (_cancelling) return;
    setState(() => _cancelling = true);
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = widget.i18n;
    final scanState = widget.scanState;
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
        color: cs.surfaceContainerHigh,
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
                          : kAppFadeDuration,
                      switchInCurve: kAppFadeCurve,
                      switchOutCurve: kAppFadeCurve,
                      child: Text(
                        stageLabel,
                        key: ValueKey(scanState.stage),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  AppLabelledButton(
                    TextButton.icon,
                    key: const ValueKey<String>('library_scan_cancel_button'),
                    onPressed: _cancelling ? null : _handleCancel,
                    icon: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: _cancelling ? cs.onSurfaceVariant : cs.error,
                    ),
                    label: Text(
                      i18n.tr('scan_cancel'),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: _cancelling ? cs.onSurfaceVariant : cs.error,
                        fontSize: 12,
                      ),
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
                borderRadius: BorderRadius.circular(tokens.radiusCapsule),
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
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    LibraryScanCountChip(
                      label: i18n.tr('scan_found'),
                      count: scanState.foundCount,
                      color: cs.primary,
                    ),
                    LibraryScanCountChip(
                      label: i18n.tr('scan_duplicate'),
                      count: scanState.duplicateCount,
                      color: cs.tertiary,
                    ),
                    LibraryScanCountChip(
                      key: const ValueKey<String>('library_scan_failure_chip'),
                      label: i18n.tr('scan_failure'),
                      count: scanState.failureCount,
                      color: scanState.failureCount > 0
                          ? cs.error
                          : cs.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
