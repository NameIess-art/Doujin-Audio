import 'asmr_providers.dart';
import 'asmr_theme.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../domain/asmr_models.dart';
import '../application/asmr_download_models.dart';
import '../application/asmr_download_selection.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';
import 'asmr_download_summary_card.dart';
import 'asmr_download_selection_tree.dart';
export 'asmr_download_task_page.dart';

class AsmrDownloadPage extends ConsumerStatefulWidget {
  const AsmrDownloadPage({
    super.key,
    this.work,
    this.initialRjCode,
    this.batchIndex,
    this.batchTotal,
    this.customDestinationRoot,
    this.customWorkFolderName,
  }) : assert(
         work != null || initialRjCode != null,
         'Either work or initialRjCode must be provided',
       );

  final AsmrWork? work;
  final String? initialRjCode;
  final int? batchIndex;
  final int? batchTotal;
  final String? customDestinationRoot;
  final String? customWorkFolderName;

  @override
  ConsumerState<AsmrDownloadPage> createState() => _AsmrDownloadPageState();
}

class _AsmrDownloadPageState extends ConsumerState<AsmrDownloadPage> {
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 0;
  AsmrDownloadSelectionModel? _selection;
  String? _destinationRoot;
  AsmrWork? _work;
  bool _loading = true;
  bool _starting = false;
  Object? _bootstrapError;
  VoidCallback? _pendingBootstrapCommit;
  late final String _bootstrapCommitKey =
      'asmr_download_bootstrap_${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    _work = widget.work;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrap());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleBootstrapCommit();
  }

  void _scheduleBootstrapCommit() {
    if (_pendingBootstrapCommit == null ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.isCurrentOf(context) == false) {
      return;
    }
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _bootstrapCommitKey,
      allowDuringScroll: true,
      commit: () {
        if (!mounted ||
            !TickerMode.valuesOf(context).enabled ||
            ModalRoute.isCurrentOf(context) == false) {
          return;
        }
        final commit = _pendingBootstrapCommit;
        _pendingBootstrapCommit = null;
        commit?.call();
      },
    );
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_bootstrapCommitKey);
    _pendingBootstrapCommit = null;
    super.dispose();
  }

  Future<void> _bootstrap() async {
    var destinationMissing = false;
    try {
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      final findWork = _work == null ? ref.read(asmrWorkFinderProvider) : null;
      final libraryController = ref.read(asmrLibraryControllerProvider);
      final downloadManager = ref.read(asmrDownloadManagerProvider);
      final settings = ref.read(settingsRepositoryProvider);
      final result = await ref
          .read(uiOperationServiceProvider)
          .run<
            ({List<AsmrTrackFile> tree, String? destinationRoot, AsmrWork work})
          >(
            scope: UiOperationScope.asmrDownloadInit,
            labelKey: 'asmr_download_title',
            task: (_) async {
              var work = _work;
              if (work == null) {
                final rjCode = widget.initialRjCode?.trim();
                if (rjCode == null || rjCode.isEmpty) {
                  throw StateError('No RJ code provided');
                }
                work = await findWork!(rjCode, language: i18n.language);
                if (work == null) {
                  throw StateError(
                    i18n.tr('audio_detail_asmr_work_not_found', {'rj': rjCode}),
                  );
                }
                if (mounted) {
                  setState(() => _work = work);
                }
              }

              if (libraryController == null || downloadManager == null) {
                throw StateError('ASMR services are not configured.');
              }

              final tree = await libraryController.ensureTrackTree(work);
              await downloadManager.initialize();
              final customRoot = widget.customDestinationRoot?.trim();
              final customFolder = widget.customWorkFolderName?.trim();
              final isCustom =
                  customRoot != null &&
                  customRoot.isNotEmpty &&
                  customFolder != null &&
                  customFolder.isNotEmpty;

              final String? targetRoot;
              if (isCustom) {
                targetRoot = customRoot;
              } else {
                targetRoot = settings.asmrDownloadDestinationRoot;
              }

              destinationMissing =
                  !isCustom &&
                  targetRoot != null &&
                  targetRoot.trim().isNotEmpty &&
                  !await downloadManager.destinationExists(targetRoot);
              return (
                tree: tree,
                destinationRoot: destinationMissing ? null : targetRoot,
                work: work,
              );
            },
          );
      if (!mounted) return;
      _pendingBootstrapCommit = () {
        final currentWork = result.work;
        _work = currentWork;
        final workTitle = currentWork.title.trim().isNotEmpty
            ? currentWork.title.trim()
            : (currentWork.sourceId.trim().isNotEmpty
                  ? currentWork.sourceId.trim()
                  : currentWork.id.toString());
        final workRootFolder = AsmrTrackFile(
          hash: 'work_root_${currentWork.id}',
          title: workTitle,
          type: 'folder',
          streamUrl: null,
          downloadUrl: null,
          lowQualityUrl: null,
          duration: Duration.zero,
          size: 0,
          children: result.tree,
          workId: currentWork.id,
          workTitle: currentWork.title,
          sourceId: currentWork.sourceId,
          relativePath: '__work_root_${currentWork.id}__',
        );
        setState(() {
          _selection = AsmrDownloadSelectionModel([workRootFolder]);
          _destinationRoot = result.destinationRoot;
          _loading = false;
          _bootstrapError = null;
        });
        if (destinationMissing) {
          final i18n = ref.read(appLanguageProviderInstanceProvider);
          showAppSnackBar(
            context,
            i18n.tr('asmr_download_path_missing'),
            tone: AppFeedbackTone.warning,
            icon: Icons.folder_off_rounded,
            iconColor: AppDesignTokens.of(context).asmrAccent,
          );
        }
      };
      _scheduleBootstrapCommit();
    } catch (error) {
      if (!mounted) return;
      _pendingBootstrapCommit = () {
        setState(() {
          _bootstrapError = error;
          _loading = false;
        });
      };
      _scheduleBootstrapCommit();
    }
  }

  Future<void> _chooseDestination() async {
    final route = ModalRoute.of(context);
    final downloadManager = ref.read(asmrDownloadManagerProvider);
    if (downloadManager == null) return;
    final settings = ref.read(settingsRepositoryProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final folder = await downloadManager.pickDestinationFolder(
      dialogTitle: i18n.tr('asmr_download_choose_path'),
    );
    if (!mounted ||
        route?.isCurrent != true ||
        folder == null ||
        folder.trim().isEmpty) {
      return;
    }
    await settings.setAsmrDownloadDestinationRoot(folder);
    if (!mounted || route?.isCurrent != true) return;
    setState(() {
      _destinationRoot = folder.trim();
    });
  }

  void _refreshSelection() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _startDownload() async {
    final work = _work;
    final selection = _selection;
    if (work == null || selection == null) return;
    if (_starting) return;
    final route = ModalRoute.of(context);

    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final downloadManager = ref.read(asmrDownloadManagerProvider);
    if (downloadManager == null) return;
    final settings = ref.read(settingsRepositoryProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final task = downloadManager.getTask(work.id);
    if (task != null &&
        task.status != AsmrDownloadTaskStatus.completed &&
        task.status != AsmrDownloadTaskStatus.failed) {
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_task_running'),
        icon: Icons.downloading_rounded,
        iconColor: asmrBlue,
      );
      return;
    }

    final selectedRoots = selection.selectedDownloadRoots();
    if (selectedRoots.isEmpty) {
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_select_required'),
        tone: AppFeedbackTone.warning,
        icon: Icons.check_box_outline_blank_rounded,
        iconColor: asmrBlue,
      );
      return;
    }

    var destination = _destinationRoot?.trim();
    if (destination == null || destination.isEmpty) {
      await _chooseDestination();
      destination = _destinationRoot?.trim();
      if (!mounted ||
          route?.isCurrent != true ||
          destination == null ||
          destination.isEmpty) {
        return;
      }
    }
    final destinationExists = await downloadManager.destinationExists(
      destination,
    );
    if (!mounted || route?.isCurrent != true) return;
    if (!destinationExists) {
      setState(() {
        _destinationRoot = null;
      });
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_path_missing'),
        tone: AppFeedbackTone.warning,
        icon: Icons.folder_off_rounded,
        iconColor: asmrBlue,
      );
      await _chooseDestination();
      destination = _destinationRoot?.trim();
      if (!mounted ||
          route?.isCurrent != true ||
          destination == null ||
          destination.isEmpty) {
        return;
      }
    }

    setState(() {
      _starting = true;
    });
    try {
      await ref
          .read(uiOperationServiceProvider)
          .run<void>(
            scope: UiOperationScope.asmrDownloadStart,
            labelKey: 'asmr_download_starting',
            task: (_) => downloadManager.startDownload(
              work: work,
              selectedRoots: selectedRoots,
              destinationRoot: destination!,
              conflictPolicy: settings.asmrDownloadConflictPolicy,
              saveMetadata: settings.asmrDownloadSaveMetadata,
              saveCover: settings.asmrDownloadSaveCover,
              automaticFileRetryCount: settings.asmrDownloadRetryCount,
              folderNameFields: settings.asmrDownloadFolderNameFields,
              customWorkFolderName: widget.customWorkFolderName,
            ),
          );
      if (!mounted || route?.isCurrent != true) return;
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_added_to_list'),
        tone: AppFeedbackTone.success,
        icon: Icons.checklist_rounded,
        iconColor: asmrBlue,
      );
      unawaited(Navigator.of(context).maybePop());
    } catch (_) {
      if (!mounted || route?.isCurrent != true) return;
      showAppSnackBar(
        context,
        i18n.tr('asmr_download_failed_next_step'),
        tone: AppFeedbackTone.destructive,
        title: i18n.tr('asmr_download_failed_title'),
        icon: Icons.error_outline_rounded,
        iconColor: asmrBlue,
        actionLabel: i18n.tr('retry'),
        onAction: () => unawaited(_startDownload()),
        duration: const Duration(seconds: 6),
      );
    } finally {
      if (mounted) {
        setState(() {
          _starting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selection = _selection;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final selectedLeafCount = selection?.selectedLeafCount() ?? 0;
    final selectedTotalSizeBytes = selection?.selectedTotalSizeBytes() ?? 0;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    final onAsmrBlue = tokens.onAsmrAccent;
    final hasDestination = (_destinationRoot?.trim().isNotEmpty ?? false);
    final compactHeader = MediaQuery.sizeOf(context).width < 400;
    final destinationLabel = i18n.tr(
      hasDestination
          ? 'asmr_download_change_path'
          : 'asmr_download_choose_path',
    );
    final destinationIcon = hasDestination
        ? Icons.folder_rounded
        : Icons.folder_open_rounded;
    final chooseDestination = (_starting || _loading)
        ? null
        : _chooseDestination;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    final listBottomPadding = 76 + bottomInset;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final h = box.size.height;
        if (h > 0 && (_headerHeight == 0 || (h - _headerHeight).abs() > 0.5)) {
          setState(() => _headerHeight = h);
        }
      }
    });

    final defaultHeaderHeight = MediaQuery.paddingOf(context).top + 140.0;
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : defaultHeaderHeight;
    final listTopPadding = effectiveHeaderHeight + 8;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: PageHeaderInset(
        topInset: listTopPadding,
        child: Stack(
          children: [
            AppPageContentTransition.deferred(
              placeholder: OperationSkeletonList(
                showHeader: false,
                padding: EdgeInsets.fromLTRB(
                  16,
                  listTopPadding,
                  16,
                  listBottomPadding,
                ),
              ),
              builder: (context) => Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: PlaceholderContentTransition(
                      showPlaceholder: _loading,
                      placeholder: OperationSkeletonList(
                        showHeader: false,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          listTopPadding,
                          16,
                          listBottomPadding,
                        ),
                      ),
                      content: _bootstrapError != null || selection == null
                          ? Padding(
                              padding: EdgeInsets.fromLTRB(
                                16,
                                listTopPadding,
                                16,
                                listBottomPadding,
                              ),
                              child: OperationStatusBanner(
                                label: i18n.tr('asmr_detail_load_failed'),
                                error: _bootstrapError,
                                onRetry: () {
                                  setState(() {
                                    _loading = true;
                                    _bootstrapError = null;
                                  });
                                  unawaited(_bootstrap());
                                },
                              ),
                            )
                          : AsmrDownloadSelectionList(
                              key: const ValueKey<String>(
                                'asmr_download_file_list',
                              ),
                              padding: EdgeInsets.fromLTRB(
                                16,
                                listTopPadding,
                                16,
                                listBottomPadding,
                              ),
                              selection: selection,
                              onSelectionChanged: _refreshSelection,
                            ),
                    ),
                  ),
                  if (!_loading && _selection != null && _work != null)
                    Positioned(
                      bottom: 16 + bottomInset,
                      right: 16,
                      child: HeaderFloatingSurface(
                        key: const ValueKey<String>(
                          'asmr_download_start_button',
                        ),
                        height: 46,
                        radius: 23,
                        padding: EdgeInsets.zero,
                        child: Material(
                          color: asmrBlue,
                          borderRadius: BorderRadius.circular(23),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(23),
                            onTap: _starting ? null : _startDownload,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_starting)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                onAsmrBlue,
                                              ),
                                        ),
                                      ),
                                    )
                                  else
                                    Icon(
                                      Icons.download_rounded,
                                      size: 18,
                                      color: onAsmrBlue,
                                    ),
                                  const SizedBox(width: 8),
                                  Text(
                                    i18n.tr('asmr_download_action'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          color: onAsmrBlue,
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
                ],
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Theme(
                data: asmrThemeData(context),
                child: TopPageHeader(
                  key: _headerKey,
                  icon: Icons.download_rounded,
                  iconColor: AppDesignTokens.of(context).asmrAccent,
                  leading: const BackButton(),
                  title: i18n.tr('asmr_download_title'),
                  titleSuffix:
                      (widget.batchIndex != null &&
                          widget.batchTotal != null &&
                          widget.batchTotal! > 1)
                      ? Text(
                          '${widget.batchIndex}/${widget.batchTotal}',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant
                                    .withValues(alpha: 0.75),
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                        )
                      : null,
                  trailing: widget.customWorkFolderName != null
                      ? null
                      : compactHeader
                      ? HeaderFloatingButton(
                          child: IconButton(
                            tooltip: destinationLabel,
                            onPressed: chooseDestination,
                            icon: Icon(
                              destinationIcon,
                              size: 18,
                              color: asmrBlue,
                            ),
                          ),
                        )
                      : HeaderFloatingSurface(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(19),
                            onTap: chooseDestination,
                            child: Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    destinationIcon,
                                    size: 18,
                                    color: asmrBlue,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    destinationLabel,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: asmrBlue,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                  additionalChild: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                    child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : kPlaceholderContentTransitionDuration,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: AsmrDownloadSummaryCard(
                        key: ValueKey(_work == null),
                        work: _work,
                        initialRjCode: widget.initialRjCode,
                        selectedLeafCount: selectedLeafCount,
                        selectedTotalSizeBytes: selectedTotalSizeBytes,

                        customWorkFolderName: widget.customWorkFolderName,
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
