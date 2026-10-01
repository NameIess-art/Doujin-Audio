import 'work_detail_breadcrumbs.dart';
import 'work_detail_actions.dart';
import 'library_download_actions.dart';
import 'work_detail_entry_tile.dart';
import 'work_detail_metadata.dart';
import 'work_detail_entries.dart';
import 'work_detail_header.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_display.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/ui/visual_settings_providers.dart';
import '../../../core/ui/undoable_removal_service.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../asmr/application/asmr_library_controller.dart';
import '../../asmr/domain/asmr_models.dart';
import '../../asmr/presentation/asmr_download_page.dart';
import '../../asmr/presentation/asmr_providers.dart';
import '../../player/presentation/playback_providers.dart';
import '../../settings/application/settings_state.dart';
import '../../settings/presentation/settings_providers.dart';
import '../application/work_text_service.dart';
import '../domain/library_node.dart';
import 'dlsite_metadata_review_page.dart';
import 'library_providers.dart';
import 'library_removal_feedback.dart';
import 'work_image_viewer_page.dart';
import 'work_text_viewer_page.dart';

const String workDetailRouteName = '/work-detail';
bool _containsAsmrSubtitle(Iterable<AsmrTrackFile> nodes) {
  for (final node in nodes) {
    if (node.isSubtitle || _containsAsmrSubtitle(node.children)) return true;
  }
  return false;
}

class WorkDetailPage extends ConsumerStatefulWidget {
  const WorkDetailPage.forLocal({super.key, required AudioDetailTarget target})
    : localTarget = target,
      asmrWork = null;

  const WorkDetailPage.forAsmr({super.key, required AsmrWork work})
    : asmrWork = work,
      localTarget = null;

  final AudioDetailTarget? localTarget;
  final AsmrWork? asmrWork;

  bool get isLocal => localTarget != null;
  bool get isAsmr => asmrWork != null;

  @override
  ConsumerState<WorkDetailPage> createState() => _WorkDetailPageState();
}

class _WorkDetailPageState extends ConsumerState<WorkDetailPage> {
  // Local state
  AudioDetailTarget? _localTarget;
  AudioDetail? _localDetail;
  FolderNode? _localFolderNode;
  List<WorkTextFile> _localTextFiles = const [];
  List<WorkImageItem> _localImageFiles = const [];
  String? _localManualCover;
  bool _loadingLocal = true;
  int _localLoadRequest = 0;
  late final String _localFilesCommitKey =
      'work_detail_files_${identityHashCode(this)}';

  // ASMR state
  List<AsmrTrackFile>? _asmrTree;
  bool _loadingAsmr = true;
  int _playRequest = 0;

  // Breadcrumb navigation state
  // Path stack: e.g. [] for root, ['EXデータ'] for subfolder
  final List<String> _currentPathSegments = [];

  @override
  void initState() {
    super.initState();
    _localTarget = widget.localTarget;
    if (widget.isLocal) {
      _loadLocalData();
    } else {
      _loadAsmrData();
    }
  }

  Future<void> _loadLocalData() async {
    final request = ++_localLoadRequest;
    UiInteractionCoordinator.instance.cancelCommit(_localFilesCommitKey);
    final target = _localTarget!;
    final folderPath = target.targetPath;
    final library = ref.read(libraryFacadeProvider);

    setState(() {
      _loadingLocal = true;
      _localFolderNode = null;
      _localTextFiles = const [];
      _localImageFiles = const [];
    });

    try {
      final detailResult = await library.loadAudioDetail(target);

      if (!mounted || request != _localLoadRequest) return;
      setState(() {
        _localDetail = detailResult.detail;
        _localManualCover =
            library.resolvedCoverPathForFolder(folderPath) ??
            detailResult.detail.cardCoverPath;
        _loadingLocal = false;
      });

      // File trees, directory scans and cover discovery wait for navigation.
      UiInteractionCoordinator.instance.scheduleCommit(
        key: _localFilesCommitKey,
        commit: () {
          if (mounted && request == _localLoadRequest) {
            unawaited(_loadLocalFiles(request, folderPath));
          }
        },
      );
    } catch (_) {
      if (!mounted || request != _localLoadRequest) return;
      setState(() {
        _loadingLocal = false;
      });
    }
  }

  Future<void> _loadLocalFiles(int request, String folderPath) async {
    final library = ref.read(libraryFacadeProvider);
    final textService = ref.read(workTextServiceProvider);
    final previousCover = _localManualCover;
    bool isCurrent() => mounted && request == _localLoadRequest;

    await Future.wait<void>([
      () async {
        try {
          final tree = await library.loadLibraryFolderTree(folderPath);
          if (!isCurrent()) return;
          setState(() => _localFolderNode = tree);
        } catch (_) {
          // Text and image discovery can still complete independently.
        }
      }(),
      () async {
        try {
          final texts = await textService.findWorkTextFiles(folderPath);
          if (!isCurrent()) return;
          setState(() => _localTextFiles = texts);
        } catch (_) {
          // Keep the indexed audio and other files available if discovery fails.
        }
      }(),
      () async {
        try {
          final candidateImages = await library.discoverCoverCandidatesInFolder(
            folderPath,
            includeVideoFrames: false,
            includeEmbeddedCovers: false,
          );
          if (!isCurrent()) return;
          final imageItems = <WorkImageItem>[];
          for (final imgPath in candidateImages) {
            final name = p.basename(imgPath);
            var rel = p
                .relative(imgPath, from: folderPath)
                .replaceAll(r'\', '/');
            if (rel.startsWith('..')) rel = name;
            imageItems.add(
              WorkImageItem(name: name, path: imgPath, relativePath: rel),
            );
          }
          setState(() => _localImageFiles = imageItems);
        } catch (_) {
          // Text discovery can still complete independently.
        }
      }(),
      if (previousCover == null || previousCover.trim().isEmpty)
        () async {
          try {
            final currentCover = await library.coverPathFutureForFolder(
              folderPath,
            );
            if (!isCurrent() || _localManualCover != previousCover) return;
            if (_localManualCover != currentCover) {
              setState(() => _localManualCover = currentCover);
            }
          } catch (_) {
            // Retain the cover already provided by the library metadata.
          }
        }(),
    ]);
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_localFilesCommitKey);
    super.dispose();
  }

  Future<void> _loadAsmrData() async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) {
      setState(() => _loadingAsmr = false);
      return;
    }
    setState(() => _loadingAsmr = true);
    try {
      await controller.initializeForVisiblePage();
      final tree = await controller.ensureTrackTree(widget.asmrWork!);
      if (!mounted) return;
      setState(() {
        _asmrTree = tree;
        _loadingAsmr = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingAsmr = false);
    }
  }

  void _enterFolder(String folderName) {
    setState(() {
      _currentPathSegments.add(folderName);
    });
  }

  // Navigate back to specific level in breadcrumbs
  void _navigateToBreadcrumbIndex(int index) {
    setState(() {
      if (index < 0) {
        _currentPathSegments.clear();
      } else if (index < _currentPathSegments.length) {
        _currentPathSegments.removeRange(
          index + 1,
          _currentPathSegments.length,
        );
      }
    });
  }

  // Current entries in directory
  List<WorkEntryItem> _buildCurrentEntries() {
    if (widget.isLocal) {
      final removalState = ref.read(undoableRemovalStateProvider);
      return buildLocalWorkEntries(
        root: _localFolderNode,
        pathSegments: _currentPathSegments,
        textFiles: _localTextFiles,
        imageFiles: _localImageFiles,
        isHidden: (track) =>
            removalState.isHidden(libraryRemovalKey(track.path)),
      );
    } else {
      final controller = ref.read(asmrLibraryControllerProvider);
      return buildAsmrWorkEntries(
        tree: _asmrTree,
        pathSegments: _currentPathSegments,
        isHidden: (node) =>
            controller?.isTrackHidden(widget.asmrWork!.id, node) ?? false,
      );
    }
  }

  // Set local image as cover
  Future<void> _setLocalImageAsCover(String imagePath) async {
    final folderPath = _localTarget!.targetPath;
    final library = ref.read(libraryFacadeProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    try {
      await library.setFolderManualCover(folderPath, imagePath);
      if (!mounted) return;
      setState(() {
        _localManualCover = imagePath;
      });
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_cover_saved'),
        tone: AppFeedbackTone.success,
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_save_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  Future<bool> _playAudioItem(WorkEntryItem item) async {
    if (widget.isLocal && item.track != null) {
      final playback = ref.read(playbackFacadeProvider);
      final tracks = _localFolderNode?.allTracks ?? [item.track!];
      final index = tracks.indexWhere(
        (track) => track.path == item.track!.path,
      );
      if (index < 0) throw StateError('The selected media is unavailable.');
      return playback.playDirect(tracks, startIndex: index);
    } else if (widget.isAsmr && item.asmrNode != null) {
      final playback = ref.read(asmrPlaybackCoordinatorProvider);
      if (playback != null) {
        return playback.playDirectTrack(widget.asmrWork!, item.asmrNode!);
      }
    }
    throw StateError('Playback is unavailable.');
  }

  Future<void> _handleEntryAction(
    WorkEntryItem item,
    WorkEntryAction action,
  ) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    try {
      switch (action) {
        case WorkEntryAction.open:
          switch (item.type) {
            case WorkEntryType.folder:
              _enterFolder(item.name);
            case WorkEntryType.text:
              await _openTextFile(item);
            case WorkEntryType.image:
              await _openImageFile(item);
            case WorkEntryType.audio:
              await _handleEntryAction(item, WorkEntryAction.play);
          }
        case WorkEntryAction.play:
          final request = ++_playRequest;
          final played = await _playAudioItem(item);
          if (request == _playRequest && !played) {
            throw StateError('Playback could not start.');
          }
        case WorkEntryAction.add:
          final added = widget.isLocal && item.track != null
              ? await ref
                    .read(playbackFacadeProvider)
                    .addTrackToPlaylist(item.track!)
              : await ref
                        .read(asmrPlaybackCoordinatorProvider)
                        ?.addTrackToPlaylist(
                          widget.asmrWork!,
                          item.asmrNode!,
                        ) ??
                    (throw StateError('Playback is unavailable.'));
          if (mounted) {
            showAppSnackBar(
              context,
              i18n.tr(
                added ? 'track_added_to_playlist' : 'track_already_in_playlist',
              ),
            );
          }
        case WorkEntryAction.remove:
          if (widget.isLocal && item.track != null) {
            await stageLibraryRemoval(
              context,
              ref,
              targetPath: item.track!.path,
              target: LibraryRemovalTarget.track,
            );
          } else {
            final controller = ref.read(asmrLibraryControllerProvider);
            if (controller == null || item.asmrNode == null) return;
            final workId = widget.asmrWork!.id;
            final node = item.asmrNode!;
            await showUndoableRemovalFeedback(
              context,
              service: ref.read(undoableRemovalServiceProvider),
              action: UndoableRemovalAction(
                key: UndoableRemovalKey(
                  'asmr-track',
                  '$workId:${node.stableKey}',
                ),
                prepare: () async {
                  await controller.setTrackHidden(workId, node, true);
                  return true;
                },
                commit: () {},
                undo: () => controller.setTrackHidden(workId, node, false),
              ),
              message: i18n.tr('audio_removed'),
              batchMessage: (count) =>
                  i18n.tr('items_removed_count', {'count': count}),
              undoLabel: i18n.tr('undo'),
              failureMessage: i18n.tr('removal_failed'),
            );
          }
        case WorkEntryAction.rename:
          await _renameLocalEntry(item);
        case WorkEntryAction.setCover:
          await _setLocalImageAsCover(item.fullPathOrUrl);
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          i18n.tr('operation_failed_retry'),
          tone: AppFeedbackTone.destructive,
        );
      }
    }
  }

  Future<void> _renameLocalEntry(WorkEntryItem item) async {
    if (!widget.isLocal || item.fullPathOrUrl.isEmpty) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    var name = PathDisplay.fileName(
      item.fullPathOrUrl,
      withoutExtension: item.type != WorkEntryType.folder,
    );
    final targetName = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: i18n.tr('rename'),
        icon: Icons.drive_file_rename_outline_rounded,
        content: TextFormField(
          initialValue: name,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onChanged: (value) => name = value,
          onFieldSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: AppDialogActions(
          children: [
            AppSecondaryButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: i18n.tr('cancel'),
            ),
            AppPrimaryButton(
              onPressed: () => Navigator.of(dialogContext).pop(name),
              label: i18n.tr('save'),
            ),
          ],
        ),
      ),
    );
    if (targetName == null || !mounted) return;
    try {
      final oldPath = item.fullPathOrUrl;
      final renamedPath = await ref
          .read(libraryFacadeProvider)
          .renameWorkEntryToName(
            libraryRootPath: _localTarget!.targetPath,
            entryPath: oldPath,
            targetName: targetName,
            isMedia: item.type == WorkEntryType.audio,
            isDirectory: item.type == WorkEntryType.folder,
          );
      if (item.type != WorkEntryType.folder && _localManualCover == oldPath) {
        await ref
            .read(libraryFacadeProvider)
            .setFolderManualCover(_localTarget!.targetPath, renamedPath);
      }
      if (!mounted) return;
      await _loadLocalData();
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_rename_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  List<UnifiedMenuEntry<WorkEntryAction>> _entryMenuItems(WorkEntryItem item) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return switch (item.type) {
      WorkEntryType.folder => [
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.open,
          icon: Icons.folder_open_rounded,
          label: i18n.tr('open'),
        ),
        if (widget.isLocal)
          UnifiedMenuEntry<WorkEntryAction>.action(
            value: WorkEntryAction.rename,
            icon: Icons.drive_file_rename_outline_rounded,
            label: i18n.tr('rename'),
          ),
      ],
      WorkEntryType.audio => [
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.play,
          icon: Icons.play_arrow_rounded,
          label: i18n.tr('play'),
        ),
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.add,
          icon: Icons.playlist_add_rounded,
          label: i18n.tr('detail_add_to_queue'),
        ),
        if (widget.isLocal)
          UnifiedMenuEntry<WorkEntryAction>.action(
            value: WorkEntryAction.rename,
            icon: Icons.drive_file_rename_outline_rounded,
            label: i18n.tr('rename'),
          ),
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.remove,
          icon: Icons.remove_circle_outline_rounded,
          label: i18n.tr('remove'),
        ),
      ],
      WorkEntryType.text => [
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.open,
          icon: Icons.open_in_new_rounded,
          label: i18n.tr('open'),
        ),
        if (widget.isLocal)
          UnifiedMenuEntry<WorkEntryAction>.action(
            value: WorkEntryAction.rename,
            icon: Icons.drive_file_rename_outline_rounded,
            label: i18n.tr('rename'),
          ),
      ],
      WorkEntryType.image => [
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.open,
          icon: Icons.open_in_new_rounded,
          label: i18n.tr('open'),
        ),
        if (widget.isLocal) ...[
          UnifiedMenuEntry<WorkEntryAction>.action(
            value: WorkEntryAction.rename,
            icon: Icons.drive_file_rename_outline_rounded,
            label: i18n.tr('rename'),
          ),
          UnifiedMenuEntry<WorkEntryAction>.action(
            value: WorkEntryAction.setCover,
            icon: Icons.photo_size_select_actual_outlined,
            label: i18n.tr('audio_detail_set_cover'),
          ),
        ],
      ],
    };
  }

  Future<void> _refreshLocalTree() async {
    if (_localFolderNode == null) return;
    final request = _localLoadRequest;
    final tree = await ref
        .read(libraryFacadeProvider)
        .loadLibraryFolderTree(_localTarget!.targetPath);
    if (mounted && request == _localLoadRequest) {
      setState(() => _localFolderNode = tree);
    }
  }

  // Open text file
  Future<void> _openTextFile(WorkEntryItem item) async {
    List<WorkTextFile> allTexts = const [];
    if (widget.isLocal) {
      allTexts = _localTextFiles;
    } else {
      allTexts = collectAsmrWorkTextFiles(_asmrTree ?? const []);
      if (allTexts.isEmpty && item.asmrNode != null) {
        allTexts = collectAsmrWorkTextFiles([item.asmrNode!]);
      }
    }
    if (allTexts.isEmpty && item.textFile != null) {
      allTexts = [item.textFile!];
    }
    int initialIndex = 0;
    if (item.asmrNode != null) {
      final idx = allTexts.indexWhere(
        (f) => f.relativePath == item.asmrNode!.relativePath,
      );
      if (idx >= 0) initialIndex = idx;
    } else if (item.textFile != null) {
      final idx = allTexts.indexWhere(
        (f) =>
            f.path == item.textFile!.path ||
            f.relativePath == item.textFile!.relativePath ||
            f.name == item.textFile!.name,
      );
      if (idx >= 0) initialIndex = idx;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            WorkTextViewerPage(files: allTexts, initialIndex: initialIndex),
      ),
    );
  }

  // Open image file
  Future<void> _openImageFile(WorkEntryItem item) async {
    List<WorkImageItem> allImages = const [];
    if (widget.isLocal) {
      allImages = _localImageFiles;
    } else {
      allImages = _collectAsmrImageFiles(_asmrTree ?? const []);
    }
    if (allImages.isEmpty && item.imageItem != null) {
      allImages = [item.imageItem!];
    }
    int initialIndex = 0;
    if (item.imageItem != null) {
      final idx = allImages.indexWhere(
        (img) =>
            img.path == item.imageItem!.path ||
            img.relativePath == item.imageItem!.relativePath,
      );
      if (idx >= 0) initialIndex = idx;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => WorkImageViewerPage(
          images: allImages,
          initialIndex: initialIndex,
          onSetAsCover: widget.isLocal
              ? (img) => _setLocalImageAsCover(img.path)
              : null,
        ),
      ),
    );
  }

  List<WorkImageItem> _collectAsmrImageFiles(List<AsmrTrackFile> nodes) {
    final result = <WorkImageItem>[];
    void visit(AsmrTrackFile node) {
      if (node.isImage) {
        final url = node.streamUrl ?? node.downloadUrl ?? '';
        result.add(
          WorkImageItem(
            name: node.title,
            path: url,
            relativePath: node.relativePath,
          ),
        );
      }
      for (final child in node.children) {
        visit(child);
      }
    }

    for (final node in nodes) {
      visit(node);
    }
    return result;
  }

  // Local actions: Fetch info, Download, Pin
  Future<void> _handleLocalFetchInfo() async {
    final detail = _localDetail;
    if (detail == null) return;
    final query = ref
        .read(libraryFacadeProvider)
        .buildDlsiteMetadataQuery(detail);
    if (!query.hasQuery) {
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_fetch_missing_query'),
        tone: AppFeedbackTone.warning,
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DlsiteMetadataReviewPage(
          detail: detail,
          rjCode: query.rjCode,
          searchTitles: query.searchTitles,
        ),
      ),
    );
    if (mounted) {
      unawaited(_loadLocalData());
    }
  }

  Future<void> _handleLocalEdit() async {
    final detail = _localDetail;
    if (detail == null) return;
    final result = await Navigator.of(context).push<DlsiteMetadataReviewResult>(
      MaterialPageRoute(
        builder: (_) => DlsiteMetadataReviewPage.edit(detail: detail),
      ),
    );
    final savedDetail = result?.detail;
    if (!mounted || savedDetail == null) return;
    setState(() {
      _localTarget = savedDetail.target;
      _localDetail = savedDetail;
      _currentPathSegments.clear();
    });
    await _loadLocalData();
  }

  Future<void> _handleLocalDownload() async {
    await downloadAudioTargetFromAsmr(
      context: context,
      ref: ref,
      target: _localTarget!,
    );
  }

  // ASMR actions: Download, Toggle favorite
  Future<void> _handleAsmrDownload() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AsmrDownloadPage(work: widget.asmrWork!),
      ),
    );
  }

  Future<void> _handleAsmrToggleFavorite() async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final work = widget.asmrWork!;
    final isFav = controller.isFavorite(work.id);
    final shouldFavorite = !isFav;
    final scope = UiOperationScope.asmrWork(
      AsmrOperationKind.favorite,
      work.id,
    );
    final operations = ref.read(uiOperationServiceProvider);
    if (operations.isBusy(scope)) return;
    try {
      await operations.run<void>(
        scope: scope,
        labelKey: 'loading_dot',
        task: (_) => controller.toggleFavorite(work),
        cancelPrevious: false,
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('operation_failed_retry'),
        tone: AppFeedbackTone.warning,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    if (!mounted) return;
    if (!shouldFavorite) {
      showAppSnackBar(
        context,
        i18n.tr('asmr_favorite_removed'),
        actionLabel: i18n.tr('undo'),
        onAction: () => unawaited(controller.toggleFavorite(work)),
        duration: const Duration(seconds: 5),
        showCountdown: true,
        showActionCountdown: true,
        tone: AppFeedbackTone.warning,
        icon: Icons.favorite_border_rounded,
        iconColor: asmrBlue,
      );
    } else {
      showAppSnackBar(
        context,
        i18n.tr('asmr_favorite_added'),
        tone: AppFeedbackTone.success,
        icon: Icons.favorite_rounded,
        iconColor: asmrBlue,
      );
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLocal) {
      ref.watch(undoableRemovalStateProvider);
      ref.listen(
        libraryStateProvider.select((state) => state.value?.structureRevision),
        (previous, next) {
          if (previous != null && next != previous) {
            unawaited(_refreshLocalTree());
          }
        },
      );
    } else {
      ref.watch(asmrTrackTreeStateProvider(widget.asmrWork!.id));
    }
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;

    // Resolve unified display fields
    String displayTitle = '';
    String displayRj = '';
    String displayCircle = '';
    bool? hasSubtitle;
    List<String> displayVoiceActors = const [];
    List<String> displayTags = const [];
    String? coverPath;

    if (widget.isLocal) {
      final detail = _localDetail;
      final folderName = PathDisplay.folderName(_localTarget!.targetPath);
      final workTitle = detail?.workTitle.trim() ?? '';
      final displayMode = ref.watch(
        settingsStateProvider.select(
          (state) => state.value?.workNameDisplay ?? WorkNameDisplay.workTitle,
        ),
      );
      displayTitle =
          displayMode == WorkNameDisplay.workTitle && workTitle.isNotEmpty
          ? workTitle
          : folderName;
      displayRj = detail?.rjCode ?? '';
      displayCircle = detail?.circleName ?? '';
      displayVoiceActors = detail?.voiceActors ?? const [];
      displayTags = detail?.tags ?? const [];
      coverPath =
          _localManualCover ??
          detail?.cardCoverPath ??
          ref
              .watch(libraryFacadeProvider)
              .resolvedCoverPathForFolder(_localTarget!.targetPath);
    } else {
      final work = widget.asmrWork!;
      displayTitle = work.title;
      displayRj = work.rjCode;
      displayCircle = work.circleName;
      hasSubtitle =
          work.hasSubtitle ||
          (_asmrTree != null && _containsAsmrSubtitle(_asmrTree!));
      displayVoiceActors = work.voiceActors;
      displayTags = work.tags;
      coverPath = work.preferredCoverUrl;
    }

    final topSafeArea = MediaQuery.paddingOf(context).top;
    final bottomOverlayInset = MobileOverlayInset.of(context);
    const coverMaxHeight = 240.0;
    const coverMinHeight = 120.0; // Collapses by half!
    const rjBarHeight = 44.0;

    final currentEntries = _buildCurrentEntries();
    final isLoading = widget.isLocal ? _loadingLocal : _loadingAsmr;

    final String? trimmedCover = coverPath?.trim();
    final bool hasValidCover = trimmedCover != null && trimmedCover.isNotEmpty;
    final bool isRemoteCover =
        hasValidCover &&
        (trimmedCover.startsWith('http://') ||
            trimmedCover.startsWith('https://') ||
            widget.isAsmr);

    final Widget coverWidget;
    if (isRemoteCover) {
      final remoteUrl = trimmedCover;
      final library = ref.read(libraryFacadeProvider);
      final coverUi = ref.read(libraryCoverUiControllerProvider);
      final coverResolution = ref.watch(coverImageResolutionProvider);
      final cacheWidth = coverCacheWidthForResolution(coverResolution);
      coverWidget = AsyncRemoteCoverImage(
        url: remoteUrl,
        future: coverUi.deferredRemoteCover(remoteUrl),
        initialPath: library.resolvedCoverPathForRemoteCover(remoteUrl),
        retryFutureBuilder: () => coverUi.deferredRemoteCover(remoteUrl),
        retryDelay: const Duration(seconds: 3),
        maxRetryAttempts: 3,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        useDefaultCacheWidth: cacheWidth != null,
        loadingBuilder: (_) => CoverLoadingArtwork(
          placeholder: CoverFallbackArtwork(seed: displayTitle),
        ),
        fallbackBuilder: (_) => CoverFallbackArtwork(seed: displayTitle),
      );
    } else {
      coverWidget = LocalCoverImage(
        path: coverPath,
        seed: coverPath ?? displayTitle,
        fit: BoxFit.cover,
        showIcon: true,
        icon: Icons.album_rounded,
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          AppPageContentTransition(
            backgroundColor: cs.surface,
            child: CustomScrollView(
              slivers: [
                // 1. Collapsible Sticky Header
                SliverPersistentHeader(
                  pinned: true,
                  delegate: WorkDetailHeaderDelegate(
                    topSafeArea: topSafeArea,
                    coverMaxHeight: coverMaxHeight,
                    coverMinHeight: coverMinHeight,
                    rjBarHeight: rjBarHeight,
                    title: displayTitle,
                    rjCode: displayRj,
                    circleName: displayCircle,
                    coverWidget: coverWidget,
                    accentColor: widget.isAsmr ? asmrBlue : cs.primary,
                    surfaceColor: cs.surface,
                    onCopyMetadata: (value) => _copyText(context, value),
                  ),
                ),

                // 2. Collapsible Details: Voice Actors, Tags, Action Buttons
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        WorkDetailMetadata(
                          voiceActors: displayVoiceActors,
                          tags: displayTags,
                          onCopy: (value) => _copyText(context, value),
                        ),

                        Consumer(
                          builder: (context, ref, _) {
                            final isFavorite = widget.isAsmr
                                ? ref
                                          .watch(asmrLibraryControllerProvider)
                                          ?.isFavorite(widget.asmrWork!.id) ??
                                      widget.asmrWork!.isFavorite
                                : false;
                            return WorkDetailActions(
                              i18n: i18n,
                              isLocal: widget.isLocal,
                              isFavorite: isFavorite,
                              accentColor: asmrBlue,
                              onFetchInfo: _handleLocalFetchInfo,
                              onDownload: widget.isLocal
                                  ? _handleLocalDownload
                                  : _handleAsmrDownload,
                              onToggleFavorite: _handleAsmrToggleFavorite,
                            );
                          },
                        ),

                        const SizedBox(height: 12),
                        const Divider(height: 1),
                        const SizedBox(height: 8),

                        WorkDetailBreadcrumbs(
                          segments: List.of(_currentPathSegments),
                          entryCount: currentEntries.length,
                          i18n: i18n,
                          onNavigate: _navigateToBreadcrumbIndex,
                        ),
                      ],
                    ),
                  ),
                ),

                // 4. Directory File Tree List
                if (isLoading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (currentEntries.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.folder_open_rounded,
                            size: 48,
                            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            i18n.tr('empty_folder'),
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final item = currentEntries[index];
                          final tile = WorkDetailEntryTile(
                            item: item,
                            accentColor: widget.isAsmr ? asmrBlue : cs.primary,
                            menuEntries: _entryMenuItems(item),
                            moreLabel: i18n.tr('more_actions'),
                            onAction: (action) =>
                                _handleEntryAction(item, action),
                          );
                          if (!widget.isLocal) return tile;
                          return TweenAnimationBuilder<double>(
                            key: ValueKey(
                              '${item.type.name}:${item.relativePath}',
                            ),
                            tween: Tween(begin: 0, end: 1),
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 300),
                            curve: Curves.easeOutCubic,
                            child: tile,
                            builder: (context, opacity, child) =>
                                Opacity(opacity: opacity, child: child),
                          );
                        },
                        childCount: currentEntries.length,
                        findChildIndexCallback: widget.isLocal
                            ? (key) {
                                final index = currentEntries.indexWhere(
                                  (item) =>
                                      key ==
                                      ValueKey(
                                        '${item.type.name}:${item.relativePath}',
                                      ),
                                );
                                return index < 0 ? null : index;
                              }
                            : null,
                      ),
                    ),
                  ),
                if (bottomOverlayInset > 0)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      key: const ValueKey<String>('work_detail_playback_inset'),
                      height: bottomOverlayInset,
                    ),
                  ),
              ],
            ),
          ),
          // Floating Back Button (top-left)
          Positioned(
            top: topSafeArea + 6,
            left: 16,
            child: AppPageHeaderTransition(
              child: HeaderFloatingButton(
                child: IconButton(
                  key: const ValueKey<String>('work_detail_back_button'),
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                ),
              ),
            ),
          ),
          if (hasSubtitle != null)
            Positioned(
              top: topSafeArea + 6,
              right: 16,
              child: AppPageHeaderTransition(
                child: HeaderFloatingSurface(
                  key: const ValueKey<String>('work_detail_subtitle_status'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        hasSubtitle
                            ? Icons.subtitles_rounded
                            : Icons.subtitles_off_rounded,
                        size: 16,
                        color: hasSubtitle ? asmrBlue : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        i18n.tr(
                          hasSubtitle
                              ? 'asmr_has_subtitle'
                              : 'asmr_no_subtitle',
                        ),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: hasSubtitle
                                  ? asmrBlue
                                  : cs.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (widget.isLocal)
            Positioned(
              top: topSafeArea + 6,
              right: 16,
              child: AppPageHeaderTransition(
                child: HeaderFloatingButton(
                  child: IconButton(
                    key: const ValueKey<String>('work_detail_edit'),
                    onPressed: _handleLocalEdit,
                    tooltip: i18n.tr('edit'),
                    icon: const Icon(Icons.edit_rounded),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _copyText(BuildContext context, String rawValue) {
    final value = rawValue.trim();
    if (value.isEmpty) return;
    Clipboard.setData(ClipboardData(text: value));
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('copied_to_clipboard', {'value': value}),
      icon: Icons.content_copy_rounded,
    );
  }
}
