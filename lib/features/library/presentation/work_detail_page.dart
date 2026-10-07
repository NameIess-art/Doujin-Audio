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

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/presentation/work_detail_navigation.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart'
    show CoverImageReference;
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
import '../../../core/widgets/shimmer_loading.dart';
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
import 'audio_detail_sheet.dart' show showAudioDetailEditor;
import 'library_providers.dart';
import 'library_removal_feedback.dart';
import 'page_translation_scope.dart';
import 'work_image_viewer_page.dart';
import 'work_text_viewer_page.dart';

const String workDetailRouteName = '/work-detail';

class WorkDetailPage extends ConsumerStatefulWidget {
  const WorkDetailPage.forLocal({
    super.key,
    required AudioDetailTarget target,
    this.initialDetail,
    this.initialCoverPath,
  }) : localTarget = target,
       asmrWork = null;

  const WorkDetailPage.forAsmr({super.key, required AsmrWork work})
    : asmrWork = work,
      localTarget = null,
      initialDetail = null,
      initialCoverPath = null;

  final AudioDetailTarget? localTarget;
  final AsmrWork? asmrWork;
  final AudioDetail? initialDetail;
  final String? initialCoverPath;

  bool get isLocal => localTarget != null;
  bool get isAsmr => asmrWork != null;

  @override
  ConsumerState<WorkDetailPage> createState() => _WorkDetailPageState();
}

class _WorkDetailPageState extends ConsumerState<WorkDetailPage>
    with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _pageStackKey = GlobalKey();
  final GlobalKey _loadingSkeletonKey = GlobalKey();
  late final AnimationController _directoryFade;
  late final CurvedAnimation _directoryOpacity;
  bool? _directoryWasLoading;
  Rect? _departingSkeletonRect;
  final Map<AnimationController, ({Set<String> ids, Animation<double> opacity})>
  _entryLoadBatches = {};
  // Local state
  AudioDetailTarget? _localTarget;
  AudioDetail? _localDetail;
  FolderNode? _localFolderNode;
  List<WorkTextFile> _localTextFiles = const [];
  List<CoverImageReference> _localImageReferences = const [];
  String? _localManualCover;
  bool _loadingLocal = true;
  int _localLoadRequest = 0;
  late final String _filesCommitKey =
      'work_detail_files_${identityHashCode(this)}';
  late final String _dataCommitKey =
      'work_detail_data_${identityHashCode(this)}';
  final List<({int? request, VoidCallback update})> _pendingDataUpdates = [];

  // ASMR state
  List<AsmrTrackFile>? _asmrTree;
  bool _loadingAsmr = true;
  int _playRequest = 0;
  Object? _coverRequestKey;
  Future<String?>? _coverFuture;
  Object? _entriesKey;
  List<WorkEntryItem> _currentEntries = const [];
  Map<Key, int> _entryIndices = const {};
  WorkDirectorySnapshot? _directory;
  bool _preparingDirectory = false;
  int _directoryRequest = 0;
  late final String _directoryCommitKey =
      'work_detail_directory_${identityHashCode(this)}';

  // Breadcrumb navigation state
  // Path stack: e.g. [] for root, ['EXデータ'] for subfolder
  final List<String> _currentPathSegments = [];

  @override
  void initState() {
    super.initState();
    _directoryFade = AnimationController(
      vsync: this,
      duration: kPlaceholderContentTransitionDuration,
      value: 1,
    );
    _directoryOpacity = CurvedAnimation(
      parent: _directoryFade,
      curve: Curves.easeInOutCubic,
    );
    assert(
      widget.initialDetail == null ||
          (widget.initialDetail!.target.targetType ==
                  widget.localTarget!.targetType &&
              PathMatcher.equalsNormalized(
                widget.initialDetail!.target.targetPath,
                widget.localTarget!.targetPath,
              )),
    );
    _localTarget = widget.localTarget;
    if (widget.isLocal) {
      final library = ref.read(libraryFacadeProvider);
      final folderPath = _localTarget!.targetPath;
      final textService = ref.read(workTextServiceProvider);
      _localFolderNode = library.resolvedLibraryFolderTree(folderPath);
      final cachedTexts = textService.resolvedWorkTextFiles(folderPath);
      final cachedImages = textService.resolvedWorkImageFiles(folderPath);
      _localTextFiles = cachedTexts ?? const [];
      _localImageReferences = cachedImages ?? const [];
      _localDetail =
          widget.initialDetail ??
          library.resolvedAudioDetail(_localTarget!) ??
          library.categorySnapshot?.detailFor(_localTarget!);
      _localManualCover =
          widget.initialCoverPath ??
          library.resolvedCoverPathForFolder(_localTarget!.targetPath) ??
          _localDetail?.cardCoverPath;
    } else {
      _asmrTree = ref
          .read(asmrLibraryControllerProvider)
          ?.trackTreeFor(widget.asmrWork!.id);
      _loadingAsmr = _asmrTree == null;
    }
    _directory = _directoryInput.resolved;
    // Render indexed files and cached discoveries before starting fresh I/O.
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _filesCommitKey,
      commit: () {
        if (!mounted) return;
        unawaited(_prepareDirectory());
        if (widget.isLocal) {
          if (_localDetail == null) {
            unawaited(_loadLocalData());
          } else {
            unawaited(
              _loadLocalFiles(++_localLoadRequest, _localTarget!.targetPath),
            );
          }
        } else {
          unawaited(_loadAsmrData());
        }
      },
    );
  }

  Future<void> _loadLocalData() async {
    final request = ++_localLoadRequest;
    UiInteractionCoordinator.instance.cancelCommit(_filesCommitKey);
    final target = _localTarget!;
    final folderPath = target.targetPath;
    final library = ref.read(libraryFacadeProvider);

    if (!_loadingLocal) setState(() => _loadingLocal = true);

    try {
      final detailResult = await library.loadAudioDetail(target);

      if (!mounted || request != _localLoadRequest) return;
      _publishDataUpdate(() {
        _localDetail = detailResult.detail;
        _localManualCover =
            library.resolvedCoverPathForFolder(folderPath) ??
            detailResult.detail.cardCoverPath;
      }, request: request);

      // File trees, directory scans and cover discovery wait for navigation.
      UiInteractionCoordinator.instance.scheduleCommit(
        key: _filesCommitKey,
        commit: () {
          if (mounted && request == _localLoadRequest) {
            unawaited(_loadLocalFiles(request, folderPath));
          }
        },
      );
    } catch (_) {
      if (!mounted || request != _localLoadRequest) return;
      _publishDataUpdate(() {
        _loadingLocal = false;
      }, request: request);
    }
  }

  Future<void> _loadLocalFiles(int request, String folderPath) async {
    final library = ref.read(libraryFacadeProvider);
    final textService = ref.read(workTextServiceProvider);
    final previousCover = _localManualCover;
    bool isCurrent() => mounted && request == _localLoadRequest;

    if (previousCover == null || previousCover.trim().isEmpty) {
      unawaited(() async {
        try {
          final currentCover = await library.coverPathFutureForFolder(
            folderPath,
          );
          if (!isCurrent() || _localManualCover != previousCover) return;
          if (_localManualCover != currentCover) {
            _publishDataUpdate(() {
              if (_localManualCover == previousCover) {
                _localManualCover = currentCover;
              }
            }, request: request);
          }
        } catch (_) {
          // Retain the cover already provided by the library metadata.
        }
      }());
    }

    await Future.wait<void>([
      () async {
        try {
          final tree = await library.loadLibraryFolderTree(folderPath);
          if (!isCurrent()) return;
          _publishDataUpdate(() => _localFolderNode = tree, request: request);
        } catch (_) {
          // Text and image discovery can still complete independently.
        }
      }(),
      () async {
        try {
          final texts = await textService.refreshWorkTextFiles(folderPath);
          if (!isCurrent()) return;
          _publishDataUpdate(() => _localTextFiles = texts, request: request);
        } catch (_) {
          // Keep the indexed audio and other files available if discovery fails.
        }
      }(),
      () async {
        try {
          final candidateImages = await textService.refreshWorkImageFiles(
            folderPath,
          );
          if (!isCurrent()) return;
          _publishDataUpdate(
            () => _localImageReferences = candidateImages,
            request: request,
          );
        } catch (_) {
          // Text discovery can still complete independently.
        }
      }(),
    ]);
    if (isCurrent()) {
      _publishDataUpdate(() => _loadingLocal = false, request: request);
    }
  }

  void _publishDataUpdate(VoidCallback update, {int? request}) {
    if (!mounted || (request != null && request != _localLoadRequest)) return;
    _pendingDataUpdates.add((request: request, update: update));
    // Independent discoveries can finish during the next route transition.
    // Keep every field's result and publish them together after interaction.
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _dataCommitKey,
      commit: () {
        if (!mounted) return;
        final updates = _pendingDataUpdates
            .where(
              (item) =>
                  item.request == null || item.request == _localLoadRequest,
            )
            .toList(growable: false);
        _pendingDataUpdates.clear();
        if (updates.isEmpty) return;
        setState(() {
          for (final item in updates) {
            item.update();
          }
        });
        unawaited(_prepareDirectory());
      },
    );
  }

  WorkDirectoryInput get _directoryInput => widget.isLocal
      ? WorkDirectoryInput.local(
          root: _localFolderNode,
          texts: _localTextFiles,
          images: _localImageReferences,
          folderPath: _localTarget!.targetPath,
        )
      : WorkDirectoryInput.asmr(_asmrTree);

  Future<void> _prepareDirectory() async {
    final request = ++_directoryRequest;
    final input = _directoryInput;
    final cached = input.resolved;
    final loading = widget.isLocal ? _loadingLocal : _loadingAsmr;
    // Wait for a real source instead of computing an empty intermediate tree.
    if (loading &&
        input.root == null &&
        input.tree == null &&
        input.texts.isEmpty &&
        input.images.isEmpty) {
      return;
    }
    _preparingDirectory = cached != _directory || _directory == null;
    if (cached != null &&
        identical(cached, _directory) &&
        (loading ||
            cached.validDepth(_currentPathSegments) ==
                _currentPathSegments.length)) {
      UiInteractionCoordinator.instance.cancelCommit(_directoryCommitKey);
      return;
    }
    final directory = cached ?? await input.load();
    if (!mounted || request != _directoryRequest) return;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _directoryCommitKey,
      commit: () {
        if (!mounted || request != _directoryRequest) return;
        if (_directoryWasLoading == false &&
            !MediaQuery.disableAnimationsOf(context) &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          final previousIds = {
            for (final entry in _currentEntries)
              '${entry.type.name}:${entry.relativePath}',
          };
          final addedIds = {
            for (final entry in directory.entriesAt(_currentPathSegments))
              if (!previousIds.contains(
                '${entry.type.name}:${entry.relativePath}',
              ))
                '${entry.type.name}:${entry.relativePath}',
          };
          if (addedIds.isNotEmpty) {
            final controller = AnimationController(
              vsync: this,
              duration: kPlaceholderContentTransitionDuration,
            );
            _entryLoadBatches[controller] = (
              ids: addedIds,
              opacity: controller.drive(
                CurveTween(curve: Curves.easeInOutCubic),
              ),
            );
            controller.addStatusListener((status) {
              if (status == AnimationStatus.completed) {
                setState(() => _entryLoadBatches.remove(controller));
                controller.dispose();
              }
            });
            controller.forward();
          }
        }
        setState(() {
          _directory = directory;
          _preparingDirectory = false;
          if ((widget.isLocal && !_loadingLocal) ||
              (widget.isAsmr && !_loadingAsmr)) {
            final depth = directory.validDepth(_currentPathSegments);
            if (depth < _currentPathSegments.length) {
              _currentPathSegments.removeRange(
                depth,
                _currentPathSegments.length,
              );
            }
          }
        });
      },
    );
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_filesCommitKey);
    UiInteractionCoordinator.instance.cancelCommit(_dataCommitKey);
    UiInteractionCoordinator.instance.cancelCommit(_directoryCommitKey);
    _pendingDataUpdates.clear();
    _scrollController.dispose();
    _directoryOpacity.dispose();
    _directoryFade.dispose();
    for (final controller in _entryLoadBatches.keys) {
      controller.dispose();
    }
    super.dispose();
  }

  void _updateDirectoryMotion(bool isLoading) {
    if (MediaQuery.disableAnimationsOf(context) ||
        ModalRoute.isCurrentOf(context) == false) {
      _directoryFade.value = 1;
      _departingSkeletonRect = null;
      for (final controller in _entryLoadBatches.keys) {
        controller.dispose();
      }
      _entryLoadBatches.clear();
      _directoryWasLoading = isLoading;
      return;
    }
    if (_directoryWasLoading == true && !isLoading) {
      final skeleton = _loadingSkeletonKey.currentContext?.findRenderObject();
      final page = _pageStackKey.currentContext?.findRenderObject();
      // Keep the fading skeleton at its painted position without reserving
      // sliver space that would push the newly loaded entries below it.
      _departingSkeletonRect =
          skeleton is RenderBox && skeleton.hasSize && page is RenderBox
          ? skeleton.localToGlobal(Offset.zero, ancestor: page) & skeleton.size
          : null;
      _directoryFade.forward(from: 0);
    } else if (isLoading && _directoryWasLoading != true) {
      _directoryFade.value = 1;
      _departingSkeletonRect = null;
    }
    _directoryWasLoading = isLoading;
  }

  Widget _directorySkeleton() => const RepaintBoundary(
    key: ValueKey('work_detail_entries_skeleton'),
    child: WorkDetailDirectorySkeleton(),
  );

  Animation<double> _entryLoadOpacity(String id) {
    if (!MediaQuery.disableAnimationsOf(context)) {
      for (final batch in _entryLoadBatches.values) {
        if (batch.ids.contains(id)) return batch.opacity;
      }
    }
    return const AlwaysStoppedAnimation(1);
  }

  Future<void> _loadAsmrData() async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) {
      _publishDataUpdate(() => _loadingAsmr = false);
      return;
    }
    try {
      await controller.initializeForVisiblePage();
      if (!mounted || ModalRoute.of(context)?.isActive == false) return;
      // Initialization may finish during a later navigation or scroll.
      if (UiInteractionCoordinator.instance.isInteracting) {
        UiInteractionCoordinator.instance.scheduleCommit(
          key: _filesCommitKey,
          commit: () {
            if (mounted && ModalRoute.of(context)?.isActive != false) {
              unawaited(_loadAsmrData());
            }
          },
        );
        return;
      }
      final tree = await controller.ensureTrackTree(
        widget.asmrWork!,
        forceRefresh: true,
      );
      if (!mounted) return;
      _publishDataUpdate(() {
        _asmrTree = tree;
        _loadingAsmr = false;
      });
    } catch (_) {
      if (!mounted) return;
      _publishDataUpdate(() => _loadingAsmr = false);
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

  List<WorkEntryItem> _buildCurrentEntries(Object? visibilityKey) {
    final key = (_directory, visibilityKey, _currentPathSegments.join('/'));
    if (_entriesKey == key) return _currentEntries;
    _entriesKey = key;
    final entries =
        _directory?.entriesAt(_currentPathSegments) ?? const <WorkEntryItem>[];
    if (widget.isLocal) {
      final library = ref.read(libraryFacadeProvider);
      final removals = ref.read(undoableRemovalStateProvider);
      // The directory snapshot can outlive a committed library removal.
      _currentEntries = entries
          .where(
            (entry) =>
                entry.track == null ||
                (library.trackByPath(entry.track!.path) != null &&
                    !removals.isHidden(libraryRemovalKey(entry.track!.path))),
          )
          .toList(growable: false);
    } else {
      final controller = ref.read(asmrLibraryControllerProvider);
      _currentEntries = entries
          .where(
            (entry) =>
                entry.type != WorkEntryType.audio ||
                !(controller?.isTrackHidden(
                      widget.asmrWork!.id,
                      entry.asmrNode!,
                    ) ??
                    false),
          )
          .toList(growable: false);
    }
    _entryIndices = {
      for (var index = 0; index < _currentEntries.length; index++)
        ValueKey(
          'work_detail_entry_fade_${_currentEntries[index].type.name}:${_currentEntries[index].relativePath}',
        ): index,
    };
    return _currentEntries;
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
      final library = ref.read(libraryFacadeProvider);
      final removals = ref.read(undoableRemovalStateProvider);
      final tracks = (_localFolderNode?.allTracks ?? [item.track!])
          .where(
            (track) =>
                library.trackByPath(track.path) != null &&
                !removals.isHidden(libraryRemovalKey(track.path)),
          )
          .toList(growable: false);
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
        case WorkEntryAction.copy:
          _copyText(context, item.name);
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
    final sourcePath = item.type == WorkEntryType.image
        ? ref
              .read(workTextServiceProvider)
              .sourcePathForWorkImage(
                _localTarget!.targetPath,
                item.fullPathOrUrl,
              )
        : item.fullPathOrUrl;
    var name = PathDisplay.fileName(
      sourcePath,
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
      final oldPath = sourcePath;
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
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.copy,
          icon: Icons.content_copy_rounded,
          label: i18n.tr('copy_name'),
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
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.copy,
          icon: Icons.content_copy_rounded,
          label: i18n.tr('copy_name'),
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
          label: i18n.tr('exclude'),
        ),
      ],
      WorkEntryType.text => [
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.open,
          icon: Icons.open_in_new_rounded,
          label: i18n.tr('open'),
        ),
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.copy,
          icon: Icons.content_copy_rounded,
          label: i18n.tr('copy_name'),
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
        UnifiedMenuEntry<WorkEntryAction>.action(
          value: WorkEntryAction.copy,
          icon: Icons.content_copy_rounded,
          label: i18n.tr('copy_name'),
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
      buildAppPageRoute(
        context: context,
        child: WorkTextViewerPage(files: allTexts, initialIndex: initialIndex),
      ),
    );
  }

  // Open image file
  Future<void> _openImageFile(WorkEntryItem item) async {
    List<WorkImageItem> allImages = _directory?.images ?? const [];
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
      buildAppPageRoute(
        context: context,
        child: WorkImageViewerPage(
          images: allImages,
          initialIndex: initialIndex,
          onSetAsCover: widget.isLocal
              ? (img) => _setLocalImageAsCover(img.path)
              : null,
        ),
      ),
    );
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
      buildAppPageRoute(
        context: context,
        child: DlsiteMetadataReviewPage(
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
    final result = await showAudioDetailEditor(context, ref, detail.target);
    final savedDetail = result?.detail;
    if (!mounted || savedDetail == null) return;
    WorkDetailNavigationScope.maybeOf(context)?.updateIdentity(
      ('local', _localTarget),
      ('local', savedDetail.target),
    );
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
      buildAppPageRoute(
        context: context,
        child: AsmrDownloadPage(work: widget.asmrWork!),
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
  Widget build(BuildContext context) =>
      WorkPageTranslationHost(child: _buildPage(context));

  Widget _buildPage(BuildContext context) {
    final Object? visibilityKey;
    if (widget.isLocal) {
      visibilityKey = (
        ref.watch(undoableRemovalStateProvider).hiddenKeys,
        ref.watch(
          libraryStateProvider.select((state) => state.value?.contentRevision),
        ),
      );
    } else {
      // Observe user removals and undo without replacing this page's file tree.
      visibilityKey = ref.watch(
        asmrTrackTreeStateProvider(
          widget.asmrWork!.id,
        ).select((state) => state.value?.revision),
      );
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
      hasSubtitle = work.hasSubtitle || (_directory?.hasSubtitle ?? false);
      displayVoiceActors = work.voiceActors;
      displayTags = work.tags;
      coverPath = work.preferredCoverUrl;
    }

    final topSafeArea = MediaQuery.paddingOf(context).top;
    final bottomOverlayInset = MobileOverlayInset.of(context);
    const coverMaxHeight = 240.0;
    const coverMinHeight = 120.0; // Collapses by half!
    const rjBarHeight = 44.0;

    final currentEntries = _buildCurrentEntries(visibilityKey);
    final isLoading = widget.isLocal
        ? (_loadingLocal || _preparingDirectory || _directory == null) &&
              currentEntries.isEmpty
        : (_loadingAsmr || _preparingDirectory || _directory == null) &&
              currentEntries.isEmpty;
    _updateDirectoryMotion(isLoading);

    final String? trimmedCover = coverPath?.trim();
    final bool hasValidCover = trimmedCover != null && trimmedCover.isNotEmpty;
    final bool isRemoteCover =
        hasValidCover &&
        (trimmedCover.startsWith('http://') ||
            trimmedCover.startsWith('https://') ||
            widget.isAsmr);

    final coverGeneration = ref.watch(coverGenerationProvider);
    final Widget coverWidget;
    if (isRemoteCover) {
      final remoteUrl = trimmedCover;
      final library = ref.read(libraryFacadeProvider);
      final coverUi = ref.read(libraryCoverUiControllerProvider);
      final coverResolution = ref.watch(coverImageResolutionProvider);
      final cacheWidth = coverCacheWidthForResolution(coverResolution);
      final resolved = library.resolvedCoverPathForRemoteCover(remoteUrl);
      final requestKey = (remoteUrl, resolved, coverGeneration);
      if (_coverRequestKey != requestKey) {
        _coverRequestKey = requestKey;
        _coverFuture = resolved != null
            ? Future.value(resolved)
            : coverUi.deferredRemoteCover(remoteUrl, context: context);
      }
      coverWidget = AsyncRemoteCoverImage(
        deferLoadDuringInteraction: true,
        onImageError: ref
            .read(libraryFacadeProvider)
            .coverArtworkCacheService
            .reportArtworkReadFailure,
        url: remoteUrl,
        future: _coverFuture!,
        initialPath: resolved,
        retryFutureBuilder: () =>
            coverUi.deferredRemoteCover(remoteUrl, context: context),
        retryDelay: const Duration(seconds: 3),
        maxRetryAttempts: 3,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        useDefaultCacheWidth: cacheWidth != null,
        loadingBuilder: (_) => const CoverLoadingArtwork(
          placeholder: CoverFallbackArtwork(),
        ),
        fallbackBuilder: (_) => const CoverFallbackArtwork(),
      );
    } else if (widget.isLocal) {
      final library = ref.read(libraryFacadeProvider);
      final resolved =
          library.resolvedCoverPathForFolder(_localTarget!.targetPath) ??
          coverPath;
      final requestKey = (_localTarget, resolved, coverGeneration);
      if (_coverRequestKey != requestKey) {
        _coverRequestKey = requestKey;
        _coverFuture = Future.value(resolved);
      }
      Future<String?> retryCover() async {
        final request = _localLoadRequest;
        final path = await ref
            .read(libraryCoverUiControllerProvider)
            .deferredFolderCover(_localTarget!.targetPath, context: context);
        if (mounted && request == _localLoadRequest) {
          setState(() => _localManualCover = path);
        }
        return path;
      }

      coverWidget = AsyncLocalCoverImage(
        deferLoadDuringInteraction: true,
        onImageError: library.coverArtworkCacheService.reportArtworkReadFailure,
        future: _coverFuture!,
        requestKey: resolved,
        initialPath: resolved,
        retryFutureBuilder: retryCover,
        fit: BoxFit.cover,
      );
    } else {
      coverWidget = const LocalCoverImage(fit: BoxFit.cover);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        key: _pageStackKey,
        children: [
          AppPageContentTransition(
            backgroundColor: cs.surface,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: CustomScrollView(
                controller: _scrollController,
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
                                            .watch(
                                              asmrLibraryControllerProvider,
                                            )
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
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: SizedBox(
                          key: _loadingSkeletonKey,
                          child: _directorySkeleton(),
                        ),
                      ),
                    )
                  else
                    SliverFadeTransition(
                      key: const ValueKey('work_detail_entries_fade'),
                      opacity: MediaQuery.disableAnimationsOf(context)
                          ? const AlwaysStoppedAnimation(1)
                          : _directoryOpacity,
                      sliver: currentEntries.isEmpty
                          ? SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.folder_open_rounded,
                                      size: 48,
                                      color: cs.onSurfaceVariant.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      i18n.tr('empty_folder'),
                                      style: TextStyle(
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              sliver: SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final item = currentEntries[index];
                                    final id =
                                        '${item.type.name}:${item.relativePath}';
                                    return FadeTransition(
                                      key: ValueKey(
                                        'work_detail_entry_fade_$id',
                                      ),
                                      opacity: _entryLoadOpacity(id),
                                      child: WorkDetailEntryTile(
                                        key: ValueKey(id),
                                        item: item,
                                        accentColor: widget.isAsmr
                                            ? asmrBlue
                                            : cs.primary,
                                        menuEntries: _entryMenuItems(item),
                                        moreLabel: i18n.tr('more_actions'),
                                        onAction: (action) =>
                                            _handleEntryAction(item, action),
                                      ),
                                    );
                                  },
                                  childCount: currentEntries.length,
                                  findChildIndexCallback: (key) =>
                                      _entryIndices[key],
                                ),
                              ),
                            ),
                    ),
                  if (bottomOverlayInset > 0)
                    SliverToBoxAdapter(
                      child: SizedBox(
                        key: const ValueKey<String>(
                          'work_detail_playback_inset',
                        ),
                        height: bottomOverlayInset,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!isLoading &&
              _departingSkeletonRect != null &&
              !MediaQuery.disableAnimationsOf(context))
            AnimatedBuilder(
              animation: _directoryFade,
              builder: (context, _) => _directoryFade.isCompleted
                  ? const SizedBox.shrink()
                  : Positioned.fromRect(
                      rect: _departingSkeletonRect!,
                      child: AppPageContentTransition(
                        child: IgnorePointer(
                          child: ExcludeSemantics(
                            child: FadeTransition(
                              opacity: ReverseAnimation(_directoryOpacity),
                              child: _directorySkeleton(),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          // Floating Back Button (top-left)
          Positioned(
            top: topSafeArea + 6,
            left: 16,
            child: AppPageHeaderTransition(
              child: HeaderFloatingButton(
                backgroundOpacity: 0.5,
                child: IconButton(
                  key: const ValueKey<String>('work_detail_back_button'),
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                ),
              ),
            ),
          ),
          Positioned(
            top: topSafeArea + 6,
            right: 16,
            child: AppPageHeaderTransition(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasSubtitle != null) ...[
                    HeaderFloatingSurface(
                      backgroundOpacity: 0.5,
                      key: const ValueKey<String>(
                        'work_detail_subtitle_status',
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
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
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 100),
                            child: Text(
                              i18n.tr(
                                hasSubtitle
                                    ? 'asmr_has_subtitle'
                                    : 'asmr_no_subtitle',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: hasSubtitle
                                        ? asmrBlue
                                        : cs.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (widget.isLocal) ...[
                    HeaderFloatingButton(
                      backgroundOpacity: 0.5,
                      child: IconButton(
                        key: const ValueKey<String>('work_detail_edit'),
                        onPressed: _handleLocalEdit,
                        tooltip: i18n.tr('edit'),
                        icon: const Icon(Icons.edit_rounded),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  const WorkPageTranslationButton(backgroundOpacity: 0.5),
                ],
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

class WorkDetailDirectorySkeleton extends StatelessWidget {
  const WorkDetailDirectorySkeleton({super.key, this.itemCount = 6});

  final int itemCount;

  static const List<double> _titleFractions = [
    0.52,
    0.68,
    0.44,
    0.60,
    0.38,
    0.55,
  ];

  @override
  Widget build(BuildContext context) {
    return ShimmerLoader(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < itemCount; i++)
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 12),
                child: Row(
                  children: [
                    const ShimmerContainer(
                      width: 22,
                      height: 22,
                      borderRadius: 5,
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor:
                              _titleFractions[i % _titleFractions.length],
                          child: const ShimmerContainer(
                            height: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const ShimmerContainer(
                      width: 16,
                      height: 16,
                      borderRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
