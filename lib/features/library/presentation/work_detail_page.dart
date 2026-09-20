import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_display.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/ui/undoable_removal_service.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../asmr/application/asmr_library_controller.dart';
import '../../asmr/domain/asmr_models.dart';
import '../../asmr/presentation/asmr_download_page.dart';
import '../../asmr/presentation/asmr_providers.dart';
import '../../player/presentation/playback_providers.dart';
import '../application/work_text_service.dart';
import '../domain/library_node.dart';
import 'dlsite_metadata_review_page.dart';
import 'library_providers.dart';
import 'library_removal_feedback.dart';
import 'library_tab.dart';
import 'work_image_viewer_page.dart';
import 'work_text_viewer_page.dart';

const String workDetailRouteName = '/work-detail';
const double _workMetadataCapsuleRadius = 14;
const EdgeInsets _workMetadataCapsulePadding = EdgeInsets.symmetric(
  horizontal: 10,
  vertical: 4,
);

enum _WorkEntryType { folder, audio, text, image }

enum _WorkEntryAction { open, play, add, remove, rename, setCover }

class _WorkEntryItem {
  const _WorkEntryItem({
    required this.name,
    required this.relativePath,
    required this.type,
    this.fullPathOrUrl = '',
    this.duration,
    this.track,
    this.asmrNode,
    this.textFile,
    this.imageItem,
  });

  final String name;
  final String relativePath;
  final _WorkEntryType type;
  final String fullPathOrUrl;
  final Duration? duration;
  final MusicTrack? track;
  final AsmrTrackFile? asmrNode;
  final WorkTextFile? textFile;
  final WorkImageItem? imageItem;
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

  // ASMR state
  List<AsmrTrackFile>? _asmrTree;
  bool _loadingAsmr = true;
  int _playRequest = 0;

  // Breadcrumb navigation state
  // Path stack: e.g. [] for root, ['EXデータ'] for subfolder
  final List<String> _currentPathSegments = [];
  final ScrollController _breadcrumbScrollController = ScrollController();

  @override
  void dispose() {
    _breadcrumbScrollController.dispose();
    super.dispose();
  }

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
    final target = _localTarget!;
    final folderPath = target.targetPath;
    final library = ref.read(libraryFacadeProvider);
    final textService = ref.read(workTextServiceProvider);

    setState(() {
      _loadingLocal = true;
    });

    try {
      final detailFuture = library.loadAudioDetail(target);
      final treeFuture = library.loadLibraryFolderTree(folderPath);

      final detailResult = await detailFuture;
      final tree = await treeFuture;

      if (!mounted) return;
      setState(() {
        _localDetail = detailResult.detail;
        _localFolderNode = tree;
        _loadingLocal = false;
      });

      unawaited(() async {
        try {
          final texts = await textService.findWorkTextFiles(folderPath);
          final currentCover = await library.coverPathFutureForFolder(
            folderPath,
          );
          final candidateImages = await library.discoverCoverCandidatesInFolder(
            folderPath,
            includeVideoFrames: false,
          );
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
          if (!mounted) return;
          setState(() {
            _localTextFiles = texts;
            _localImageFiles = imageItems;
            _localManualCover = currentCover;
          });
        } catch (_) {}
      }());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingLocal = false;
      });
    }
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

  String get _currentRelativePath => _currentPathSegments.join('/');

  void _enterFolder(String folderName) {
    setState(() {
      _currentPathSegments.add(folderName);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_breadcrumbScrollController.hasClients) {
        _breadcrumbScrollController.animateTo(
          _breadcrumbScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
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
  List<_WorkEntryItem> _buildCurrentEntries() {
    if (widget.isLocal) {
      return _buildLocalEntries();
    } else {
      return _buildAsmrEntries();
    }
  }

  List<_WorkEntryItem> _buildLocalEntries() {
    final currentRel = _currentRelativePath;
    final entries = <_WorkEntryItem>[];
    final visibleFolderPaths = <String>{};

    // Find current FolderNode
    FolderNode? currentFolder = _localFolderNode;
    if (currentFolder != null && _currentPathSegments.isNotEmpty) {
      for (final segment in _currentPathSegments) {
        FolderNode? next;
        for (final child in currentFolder!.children) {
          if (child is FolderNode && child.name == segment) {
            next = child;
            break;
          }
        }
        currentFolder = next;
        if (currentFolder == null) break;
      }
    }

    // 1. Folders & Tracks from currentFolder
    if (currentFolder != null) {
      for (final child in currentFolder.children) {
        if (child is FolderNode) {
          final childRel = currentRel.isEmpty
              ? child.name
              : '$currentRel/${child.name}';
          visibleFolderPaths.add(childRel);
          entries.add(
            _WorkEntryItem(
              name: child.name,
              relativePath: childRel,
              type: _WorkEntryType.folder,
              fullPathOrUrl: child.path,
            ),
          );
        } else if (child is TrackNode) {
          if (ref
              .read(undoableRemovalStateProvider)
              .isHidden(libraryRemovalKey(child.track.path))) {
            continue;
          }
          entries.add(
            _WorkEntryItem(
              name: child.track.displayName,
              relativePath: child.track.path,
              type: _WorkEntryType.audio,
              fullPathOrUrl: child.track.path,
              duration: child.track.duration,
              track: child.track,
            ),
          );
        }
      }
    }

    void addFileParentFolder(String fileRelativePath) {
      final fileSegments = fileRelativePath
          .replaceAll(r'\', '/')
          .split('/')
          .where((segment) => segment.trim().isNotEmpty)
          .toList(growable: false);
      final currentSegments = currentRel.isEmpty
          ? const <String>[]
          : currentRel.split('/');
      if (fileSegments.length <= currentSegments.length + 1) return;
      for (var index = 0; index < currentSegments.length; index++) {
        if (fileSegments[index] != currentSegments[index]) return;
      }
      final childName = fileSegments[currentSegments.length];
      final childRel = <String>[...currentSegments, childName].join('/');
      if (!visibleFolderPaths.add(childRel)) return;
      entries.add(
        _WorkEntryItem(
          name: childName,
          relativePath: childRel,
          type: _WorkEntryType.folder,
          fullPathOrUrl: childRel,
        ),
      );
    }

    for (final text in _localTextFiles) {
      addFileParentFolder(text.relativePath);
    }
    for (final image in _localImageFiles) {
      addFileParentFolder(image.relativePath);
    }

    // 2. Text files in current directory level
    for (final text in _localTextFiles) {
      final parentRel = _parentRelOf(text.relativePath);
      if (_isSameRelPath(parentRel, currentRel)) {
        entries.add(
          _WorkEntryItem(
            name: text.name,
            relativePath: text.relativePath,
            type: _WorkEntryType.text,
            fullPathOrUrl: text.path,
            textFile: text,
          ),
        );
      }
    }

    // 3. Image files in current directory level
    for (final img in _localImageFiles) {
      final parentRel = _parentRelOf(img.relativePath);
      if (_isSameRelPath(parentRel, currentRel)) {
        entries.add(
          _WorkEntryItem(
            name: img.name,
            relativePath: img.relativePath,
            type: _WorkEntryType.image,
            fullPathOrUrl: img.path,
            imageItem: img,
          ),
        );
      }
    }

    // Natural sort: folders first, then files
    entries.sort((a, b) {
      if (a.type == _WorkEntryType.folder && b.type != _WorkEntryType.folder) {
        return -1;
      }
      if (a.type != _WorkEntryType.folder && b.type == _WorkEntryType.folder) {
        return 1;
      }
      return compareNaturalTreeEntries(
        leftIsFolder: a.type == _WorkEntryType.folder,
        leftName: a.name,
        leftPath: a.relativePath,
        rightIsFolder: b.type == _WorkEntryType.folder,
        rightName: b.name,
        rightPath: b.relativePath,
      );
    });

    return entries;
  }

  List<_WorkEntryItem> _buildAsmrEntries() {
    final entries = <_WorkEntryItem>[];
    List<AsmrTrackFile> currentNodes = _asmrTree ?? const [];

    if (_currentPathSegments.isNotEmpty) {
      for (final segment in _currentPathSegments) {
        AsmrTrackFile? next;
        for (final node in currentNodes) {
          if (node.isFolder && node.title == segment) {
            next = node;
            break;
          }
        }
        if (next != null) {
          currentNodes = next.children;
        } else {
          currentNodes = const [];
          break;
        }
      }
    }

    for (final node in currentNodes) {
      if (node.isFolder) {
        entries.add(
          _WorkEntryItem(
            name: node.title,
            relativePath: node.relativePath,
            type: _WorkEntryType.folder,
            asmrNode: node,
          ),
        );
      } else if (node.isAudio) {
        if (ref
                .read(asmrLibraryControllerProvider)
                ?.isTrackHidden(widget.asmrWork!.id, node) ??
            false) {
          continue;
        }
        entries.add(
          _WorkEntryItem(
            name: node.displayTitle,
            relativePath: node.relativePath,
            type: _WorkEntryType.audio,
            fullPathOrUrl: node.streamUrl ?? '',
            duration: node.duration,
            asmrNode: node,
          ),
        );
      } else if (node.isText) {
        entries.add(
          _WorkEntryItem(
            name: node.title,
            relativePath: node.relativePath,
            type: _WorkEntryType.text,
            fullPathOrUrl: node.streamUrl ?? '',
            asmrNode: node,
            textFile: WorkTextFile(
              name: node.title,
              relativePath: node.relativePath,
              path: node.streamUrl ?? '',
            ),
          ),
        );
      } else if (node.isImage) {
        final imgUrl = node.streamUrl ?? node.downloadUrl ?? '';
        entries.add(
          _WorkEntryItem(
            name: node.title,
            relativePath: node.relativePath,
            type: _WorkEntryType.image,
            fullPathOrUrl: imgUrl,
            asmrNode: node,
            imageItem: WorkImageItem(
              name: node.title,
              path: imgUrl,
              relativePath: node.relativePath,
            ),
          ),
        );
      }
    }

    // Folders first, then natural sort
    entries.sort((a, b) {
      if (a.type == _WorkEntryType.folder && b.type != _WorkEntryType.folder) {
        return -1;
      }
      if (a.type != _WorkEntryType.folder && b.type == _WorkEntryType.folder) {
        return 1;
      }
      return compareNaturalTreeEntries(
        leftIsFolder: a.type == _WorkEntryType.folder,
        leftName: a.name,
        leftPath: a.relativePath,
        rightIsFolder: b.type == _WorkEntryType.folder,
        rightName: b.name,
        rightPath: b.relativePath,
      );
    });

    return entries;
  }

  String _parentRelOf(String relPath) {
    final normalized = relPath.replaceAll(r'\', '/').trim();
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash < 0) return '';
    return normalized.substring(0, lastSlash);
  }

  bool _isSameRelPath(String a, String b) {
    return a.replaceAll(r'\', '/').trim() == b.replaceAll(r'\', '/').trim();
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

  Future<bool> _playAudioItem(_WorkEntryItem item) async {
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
    _WorkEntryItem item,
    _WorkEntryAction action,
  ) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    try {
      switch (action) {
        case _WorkEntryAction.open:
          switch (item.type) {
            case _WorkEntryType.folder:
              _enterFolder(item.name);
            case _WorkEntryType.text:
              await _openTextFile(item);
            case _WorkEntryType.image:
              await _openImageFile(item);
            case _WorkEntryType.audio:
              await _handleEntryAction(item, _WorkEntryAction.play);
          }
        case _WorkEntryAction.play:
          final request = ++_playRequest;
          final played = await _playAudioItem(item);
          if (request == _playRequest && !played) {
            throw StateError('Playback could not start.');
          }
        case _WorkEntryAction.add:
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
        case _WorkEntryAction.remove:
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
        case _WorkEntryAction.rename:
          await _renameLocalEntry(item);
        case _WorkEntryAction.setCover:
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

  Future<void> _renameLocalEntry(_WorkEntryItem item) async {
    if (!widget.isLocal || item.fullPathOrUrl.isEmpty) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    var name = PathDisplay.fileName(
      item.fullPathOrUrl,
      withoutExtension: item.type != _WorkEntryType.folder,
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
            isMedia: item.type == _WorkEntryType.audio,
            isDirectory: item.type == _WorkEntryType.folder,
          );
      if (item.type != _WorkEntryType.folder && _localManualCover == oldPath) {
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

  List<UnifiedMenuEntry<_WorkEntryAction>> _entryMenuItems(
    _WorkEntryItem item,
  ) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return switch (item.type) {
      _WorkEntryType.folder => [
        UnifiedMenuEntry<_WorkEntryAction>.action(
          value: _WorkEntryAction.open,
          icon: Icons.folder_open_rounded,
          label: i18n.tr('open'),
        ),
        if (widget.isLocal)
          UnifiedMenuEntry<_WorkEntryAction>.action(
            value: _WorkEntryAction.rename,
            icon: Icons.drive_file_rename_outline_rounded,
            label: i18n.tr('rename'),
          ),
      ],
      _WorkEntryType.audio => [
        UnifiedMenuEntry<_WorkEntryAction>.action(
          value: _WorkEntryAction.play,
          icon: Icons.play_arrow_rounded,
          label: i18n.tr('play'),
        ),
        UnifiedMenuEntry<_WorkEntryAction>.action(
          value: _WorkEntryAction.add,
          icon: Icons.playlist_add_rounded,
          label: i18n.tr('detail_add_to_queue'),
        ),
        if (widget.isLocal)
          UnifiedMenuEntry<_WorkEntryAction>.action(
            value: _WorkEntryAction.rename,
            icon: Icons.drive_file_rename_outline_rounded,
            label: i18n.tr('rename'),
          ),
        UnifiedMenuEntry<_WorkEntryAction>.action(
          value: _WorkEntryAction.remove,
          icon: Icons.remove_circle_outline_rounded,
          label: i18n.tr('remove'),
        ),
      ],
      _WorkEntryType.text => [
        UnifiedMenuEntry<_WorkEntryAction>.action(
          value: _WorkEntryAction.open,
          icon: Icons.open_in_new_rounded,
          label: i18n.tr('open'),
        ),
        if (widget.isLocal)
          UnifiedMenuEntry<_WorkEntryAction>.action(
            value: _WorkEntryAction.rename,
            icon: Icons.drive_file_rename_outline_rounded,
            label: i18n.tr('rename'),
          ),
      ],
      _WorkEntryType.image => [
        UnifiedMenuEntry<_WorkEntryAction>.action(
          value: _WorkEntryAction.open,
          icon: Icons.open_in_new_rounded,
          label: i18n.tr('open'),
        ),
        if (widget.isLocal) ...[
          UnifiedMenuEntry<_WorkEntryAction>.action(
            value: _WorkEntryAction.rename,
            icon: Icons.drive_file_rename_outline_rounded,
            label: i18n.tr('rename'),
          ),
          UnifiedMenuEntry<_WorkEntryAction>.action(
            value: _WorkEntryAction.setCover,
            icon: Icons.photo_size_select_actual_outlined,
            label: i18n.tr('audio_detail_set_cover'),
          ),
        ],
      ],
    };
  }

  Future<void> _showEntryContextMenu(
    _WorkEntryItem item,
    Offset globalPosition,
  ) async {
    final overlayState =
        MobileOverlayInset.menuOverlayOf(context) ?? Overlay.maybeOf(context);
    final overlayBox = overlayState?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) return;

    final localPos = overlayBox.globalToLocal(globalPosition);
    final position = RelativeRect.fromRect(
      localPos & Size.zero,
      Offset.zero & overlayBox.size,
    );

    final action = await showDockAwareMenu<_WorkEntryAction>(
      context: context,
      position: position,
      entries: _entryMenuItems(item),
    );
    if (mounted && action != null) await _handleEntryAction(item, action);
  }

  Future<void> _refreshLocalTree() async {
    final tree = await ref
        .read(libraryFacadeProvider)
        .loadLibraryFolderTree(_localTarget!.targetPath);
    if (mounted) setState(() => _localFolderNode = tree);
  }

  // Open text file
  Future<void> _openTextFile(_WorkEntryItem item) async {
    List<WorkTextFile> allTexts = const [];
    if (widget.isLocal) {
      allTexts = _localTextFiles;
    } else {
      allTexts = collectAsmrWorkTextFiles(_asmrTree ?? const []);
    }
    if (allTexts.isEmpty && item.textFile != null) {
      allTexts = [item.textFile!];
    }
    int initialIndex = 0;
    if (item.textFile != null) {
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
  Future<void> _openImageFile(_WorkEntryItem item) async {
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
    List<String> displayVoiceActors = const [];
    List<String> displayTags = const [];
    String? coverPath;

    if (widget.isLocal) {
      final detail = _localDetail;
      displayTitle = PathDisplay.folderName(_localTarget!.targetPath);
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
      displayVoiceActors = work.voiceActors;
      displayTags = work.tags;
      coverPath = work.mainCoverUrl.isNotEmpty
          ? work.mainCoverUrl
          : (work.coverUrl.isNotEmpty ? work.coverUrl : work.thumbnailUrl);
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
        useDefaultCacheWidth: false,
        showIcon: true,
        icon: Icons.album_rounded,
      );
    }

    return Scaffold(
      backgroundColor: cs.surface,
      body: CustomScrollView(
        slivers: [
          // 1. Collapsible Sticky Header
          SliverPersistentHeader(
            pinned: true,
            delegate: _WorkDetailHeaderDelegate(
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
              onBackPressed: () => Navigator.of(context).maybePop(),
              onEditPressed: widget.isLocal ? _handleLocalEdit : null,
              editLabel: i18n.tr('edit'),
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
                  // Voice Actors row
                  if (displayVoiceActors.isNotEmpty) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.badge_outlined,
                          size: 17,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildVoiceActorScroller(
                            context,
                            cs,
                            displayVoiceActors,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Tags row
                  if (displayTags.isNotEmpty) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.local_offer_outlined,
                          size: 17,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildTagScroller(context, cs, displayTags),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],

                  // Action Buttons Row
                  if (widget.isLocal) ...[
                    Row(
                      children: [
                        // 补充信息
                        Expanded(
                          child: FilledButton.tonalIcon(
                            key: const ValueKey<String>(
                              'work_detail_fetch_info',
                            ),
                            onPressed: _handleLocalFetchInfo,
                            icon: const Icon(
                              Icons.cloud_download_rounded,
                              size: 18,
                            ),
                            label: Text(
                              i18n.tr('audio_detail_fetch_info'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 下载
                        Expanded(
                          child: FilledButton.tonalIcon(
                            key: const ValueKey<String>('work_detail_download'),
                            onPressed: _handleLocalDownload,
                            icon: const Icon(Icons.download_rounded, size: 18),
                            label: Text(
                              i18n.tr('download'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    Row(
                      children: [
                        // 下载
                        Expanded(
                          child: FilledButton.tonalIcon(
                            key: const ValueKey<String>(
                              'asmr_work_detail_download',
                            ),
                            onPressed: _handleAsmrDownload,
                            icon: const Icon(Icons.download_rounded, size: 18),
                            label: Text(
                              i18n.tr('download'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // 收藏 / 取消收藏
                        Consumer(
                          builder: (context, ref, _) {
                            final controller = ref.watch(
                              asmrLibraryControllerProvider,
                            );
                            final isFav =
                                controller?.isFavorite(widget.asmrWork!.id) ??
                                widget.asmrWork!.isFavorite;
                            return Expanded(
                              child: FilledButton.tonalIcon(
                                key: const ValueKey<String>(
                                  'asmr_work_detail_favorite',
                                ),
                                onPressed: _handleAsmrToggleFavorite,
                                style: FilledButton.styleFrom(
                                  backgroundColor: isFav
                                      ? asmrBlue.withValues(alpha: 0.2)
                                      : null,
                                  foregroundColor: isFav ? asmrBlue : null,
                                ),
                                icon: Icon(
                                  isFav
                                      ? Icons.favorite_rounded
                                      : Icons.favorite_border_rounded,
                                  size: 18,
                                  color: isFav ? asmrBlue : null,
                                ),
                                label: Text(
                                  i18n.tr(
                                    isFav
                                        ? 'asmr_unfavorite_action'
                                        : 'asmr_favorite_action',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 8),

                  // 3. Navigation Breadcrumb Bar
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _breadcrumbScrollController,
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _navigateToBreadcrumbIndex(-1),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.home_rounded,
                                        size: 18,
                                        color: cs.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        i18n.tr('root_directory'),
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: cs.primary,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              for (
                                var i = 0;
                                i < _currentPathSegments.length;
                                i++
                              ) ...[
                                const Text(
                                  ' > ',
                                  style: TextStyle(color: Colors.grey),
                                ),
                                InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () => _navigateToBreadcrumbIndex(i),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                    child: Text(
                                      _currentPathSegments[i],
                                      style: TextStyle(
                                        fontWeight:
                                            i == _currentPathSegments.length - 1
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color:
                                            i == _currentPathSegments.length - 1
                                            ? cs.onSurface
                                            : cs.primary,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${currentEntries.length} 项',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = currentEntries[index];
                  return _buildFileEntryTile(context, item, cs, asmrBlue);
                }, childCount: currentEntries.length),
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

  Widget _buildVoiceActorCapsule(
    BuildContext context,
    ColorScheme cs,
    String voiceActor,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: voiceActor,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('work_detail_voice_actor_$voiceActor'),
          onTap: () => _copyText(context, voiceActor),
          borderRadius: BorderRadius.circular(_workMetadataCapsuleRadius),
          child: Container(
            padding: _workMetadataCapsulePadding,
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(
                alpha: isDark ? 0.34 : 0.56,
              ),
              borderRadius: BorderRadius.circular(_workMetadataCapsuleRadius),
              border: Border.all(
                color: cs.primary.withValues(alpha: isDark ? 0.28 : 0.20),
              ),
            ),
            child: Text(
              voiceActor,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onPrimaryContainer,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagCapsule(BuildContext context, ColorScheme cs, String tag) {
    final displayLabel = tag.startsWith('#') ? tag : '#$tag';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('work_detail_tag_$displayLabel'),
        onTap: () =>
            _copyText(context, tag.startsWith('#') ? tag.substring(1) : tag),
        borderRadius: BorderRadius.circular(_workMetadataCapsuleRadius),
        child: Container(
          padding: _workMetadataCapsulePadding,
          decoration: BoxDecoration(
            color: isDark
                ? cs.surfaceContainerHighest.withValues(alpha: 0.5)
                : cs.surfaceContainerHigh.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(_workMetadataCapsuleRadius),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: isDark ? 0.3 : 0.45),
            ),
          ),
          child: Text(
            displayLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagScroller(
    BuildContext context,
    ColorScheme cs,
    List<String> tags,
  ) {
    return _buildMetadataScroller(
      context,
      cs,
      keyPrefix: 'tag',
      children: tags
          .map(
            (tag) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _buildTagCapsule(context, cs, tag),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildVoiceActorScroller(
    BuildContext context,
    ColorScheme cs,
    List<String> voiceActors,
  ) {
    return _buildMetadataScroller(
      context,
      cs,
      keyPrefix: 'voice_actor',
      children: voiceActors
          .map(
            (voiceActor) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildVoiceActorCapsule(context, cs, voiceActor),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildMetadataScroller(
    BuildContext context,
    ColorScheme cs, {
    required String keyPrefix,
    required List<Widget> children,
  }) {
    return ShaderMask(
      key: ValueKey<String>('work_detail_${keyPrefix}_edge_fade'),
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        colors: [
          Colors.transparent,
          Colors.black,
          Colors.black,
          Colors.transparent,
        ],
        stops: [0, 0.06, 0.94, 1],
      ).createShader(bounds),
      child: SingleChildScrollView(
        key: ValueKey<String>('work_detail_${keyPrefix}_scroller'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: children),
      ),
    );
  }

  Widget _buildFileEntryTile(
    BuildContext context,
    _WorkEntryItem item,
    ColorScheme cs,
    Color asmrBlue,
  ) {
    switch (item.type) {
      case _WorkEntryType.folder:
        return GestureDetector(
          onSecondaryTapDown: defaultTargetPlatform == TargetPlatform.windows
              ? (details) => _showEntryContextMenu(item, details.globalPosition)
              : null,
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            leading: const Icon(Icons.folder_rounded, color: Color(0xFFFFA000)),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            trailing: _buildEntryMoreButton(item),
            onTap: () => _enterFolder(item.name),
          ),
        );

      case _WorkEntryType.audio:
        return GestureDetector(
          onSecondaryTapDown: defaultTargetPlatform == TargetPlatform.windows
              ? (details) => _showEntryContextMenu(item, details.globalPosition)
              : null,
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            leading: Icon(
              (item.track?.isVideo ?? item.asmrNode?.isVideo ?? false)
                  ? Icons.videocam_outlined
                  : Icons.audiotrack_rounded,
              color: widget.isAsmr ? asmrBlue : cs.primary,
            ),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _buildEntryMoreButton(item),
            onTap: () => _handleEntryAction(item, _WorkEntryAction.play),
          ),
        );

      case _WorkEntryType.text:
        return GestureDetector(
          onSecondaryTapDown: defaultTargetPlatform == TargetPlatform.windows
              ? (details) => _showEntryContextMenu(item, details.globalPosition)
              : null,
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            leading: Icon(
              Icons.description_outlined,
              color: cs.onSurfaceVariant,
            ),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _buildEntryMoreButton(item),
            onTap: () => _openTextFile(item),
          ),
        );

      case _WorkEntryType.image:
        return GestureDetector(
          onSecondaryTapDown: defaultTargetPlatform == TargetPlatform.windows
              ? (details) => _showEntryContextMenu(item, details.globalPosition)
              : null,
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            leading: Icon(Icons.image_outlined, color: cs.onSurfaceVariant),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _buildEntryMoreButton(item),
            onTap: () => _openImageFile(item),
          ),
        );
    }
  }

  Widget _buildEntryMoreButton(_WorkEntryItem item) {
    return SizedBox.square(
      dimension: 44,
      child: Builder(
        builder: (buttonContext) {
          return IconButton(
            key: ValueKey<String>('work_entry_more_${item.relativePath}'),
            padding: EdgeInsets.zero,
            iconSize: 22,
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: ref
                .read(appLanguageProviderInstanceProvider)
                .tr('more_actions'),
            onPressed: () => _showEntryMenuForButton(item, buttonContext),
          );
        },
      ),
    );
  }

  Future<void> _showEntryMenuForButton(
    _WorkEntryItem item,
    BuildContext buttonContext,
  ) async {
    final buttonBox = buttonContext.findRenderObject() as RenderBox?;
    if (buttonBox == null || !buttonBox.hasSize) return;
    final overlayState =
        MobileOverlayInset.menuOverlayOf(context) ?? Overlay.maybeOf(context);
    final overlayBox = overlayState?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) return;

    final buttonOrigin = buttonBox.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final buttonRect = buttonOrigin & buttonBox.size;
    final position = RelativeRect.fromRect(
      buttonRect,
      Offset.zero & overlayBox.size,
    );

    final action = await showDockAwareMenu<_WorkEntryAction>(
      context: context,
      position: position,
      entries: _entryMenuItems(item),
    );
    if (mounted && action != null) {
      await _handleEntryAction(item, action);
    }
  }
}

class _DockMenuLayout extends SingleChildLayoutDelegate {
  _DockMenuLayout(this.position);
  final RelativeRect position;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(constraints.biggest);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Right-align to button right edge.
    double x = size.width - position.right - childSize.width;
    if (x + childSize.width > size.width - 8) {
      x = size.width - 8 - childSize.width;
    }
    if (x < 8) x = 8;

    // Top-align to button top (covering the button).
    double y = position.top;
    if (y + childSize.height > size.height - 8) {
      y = size.height - 8 - childSize.height;
    }
    if (y < 8) y = 8;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_DockMenuLayout oldDelegate) =>
      position != oldDelegate.position;
}

Future<T?> showDockAwareMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<UnifiedMenuEntry<T>> entries,
}) async {
  final overlayState =
      MobileOverlayInset.menuOverlayOf(context) ?? Overlay.maybeOf(context);
  if (overlayState == null) return null;

  final completer = Completer<T?>();
  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (_) => _DockMenuOverlay<T>(
      position: position,
      entries: entries,
      themeContext: context,
      onResult: (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
    ),
  );

  overlayState.insert(entry);
  final result = await completer.future;
  entry.remove();
  entry.dispose();
  return result;
}

class _DockMenuOverlay<T> extends StatefulWidget {
  const _DockMenuOverlay({
    required this.position,
    required this.entries,
    required this.themeContext,
    required this.onResult,
  });

  final RelativeRect position;
  final List<UnifiedMenuEntry<T>> entries;
  final BuildContext themeContext;
  final ValueChanged<T?> onResult;

  @override
  State<_DockMenuOverlay<T>> createState() => _DockMenuOverlayState<T>();
}

class _DockMenuOverlayState<T> extends State<_DockMenuOverlay<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 100),
    );
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss(T? value) async {
    if (_dismissed) return;
    _dismissed = true;
    try {
      await _controller.reverse();
    } catch (_) {}
    widget.onResult(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(widget.themeContext);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final tokens = AppDesignTokens.of(widget.themeContext);
    final background = isDark ? cs.surfaceBright : cs.surfaceContainerHighest;

    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _dismiss(null);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _dismiss(null),
            child: const SizedBox.expand(),
          ),
          CustomSingleChildLayout(
            delegate: _DockMenuLayout(widget.position),
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                alignment: Alignment.topRight,
                scale:
                    Tween<double>(begin: 0.96, end: 1).animate(curved),
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(tokens.radiusSection),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius:
                          BorderRadius.circular(tokens.radiusSection),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(
                          alpha: tokens.standardBorderAlpha,
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: cs.shadow.withValues(
                            alpha: isDark ? 0.36 : 0.18,
                          ),
                          blurRadius: 30,
                          offset: const Offset(0, 16),
                        ),
                      ],
                    ),
                    child: IntrinsicWidth(
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final e in widget.entries)
                              if (e.divider)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4,
                                  ),
                                  child: Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: cs.outlineVariant
                                        .withValues(alpha: 0.56),
                                  ),
                                )
                              else
                                Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: e.enabled && e.value != null
                                        ? () => _dismiss(e.value)
                                        : null,
                                    child: SizedBox(
                                      height: 40,
                                      child: Padding(
                                        padding:
                                            const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              e.icon,
                                              size: 18,
                                              color: cs.onSurface,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                e.label,
                                                maxLines: 1,
                                                overflow: TextOverflow
                                                    .ellipsis,
                                                style: theme
                                                    .textTheme.bodySmall
                                                    ?.copyWith(
                                                  color: cs.onSurface,
                                                  fontWeight:
                                                      FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
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
    );
  }
}

// ---------------------------------------------------------------------------
// Header Delegate: Collapses cover by half, pins RJ | CircleName row permanently
// ---------------------------------------------------------------------------

class _WorkDetailHeaderDelegate extends SliverPersistentHeaderDelegate {
  _WorkDetailHeaderDelegate({
    required this.topSafeArea,
    required this.coverMaxHeight,
    required this.coverMinHeight,
    required this.rjBarHeight,
    required this.title,
    required this.rjCode,
    required this.circleName,
    required this.coverWidget,
    required this.accentColor,
    required this.surfaceColor,
    required this.onBackPressed,
    required this.onEditPressed,
    required this.editLabel,
    required this.onCopyMetadata,
  });

  final double topSafeArea;
  final double coverMaxHeight;
  final double coverMinHeight;
  final double rjBarHeight;
  final String title;
  final String rjCode;
  final String circleName;
  final Widget coverWidget;
  final Color accentColor;
  final Color surfaceColor;
  final VoidCallback onBackPressed;
  final VoidCallback? onEditPressed;
  final String editLabel;
  final ValueChanged<String> onCopyMetadata;

  @override
  double get maxExtent => topSafeArea + coverMaxHeight + rjBarHeight;

  @override
  double get minExtent => topSafeArea + coverMinHeight + rjBarHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final scrollDelta = maxExtent - minExtent;
    final progress = scrollDelta <= 0
        ? 0.0
        : (shrinkOffset / scrollDelta).clamp(0.0, 1.0);

    final currentCoverHeight =
        coverMaxHeight -
        (shrinkOffset).clamp(0.0, coverMaxHeight - coverMinHeight);

    return Material(
      color: surfaceColor,
      elevation: progress > 0.8 ? 2.0 : 0.0,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Cover Image area with Gradient and Title
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topSafeArea + currentCoverHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                coverWidget,
                // Gradient overlay
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.35),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.85),
                      ],
                      stops: const [0.0, 0.4, 1.0],
                    ),
                  ),
                ),
                // Work title (max 3 lines) at the bottom of the cover
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 10,
                  child: Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: progress > 0.5 ? 15 : 17,
                      fontWeight: FontWeight.bold,
                      height: 1.25,
                      shadows: const [
                        Shadow(
                          color: Colors.black87,
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // RJXXXX | 社团名 Row (Pinned at the bottom of the header, never collapsed!)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: rjBarHeight,
            child: Container(
              color: surfaceColor,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  if (rjCode.isNotEmpty) ...[
                    Semantics(
                      button: true,
                      label: rjCode,
                      child: InkWell(
                        key: const ValueKey<String>('work_detail_rj_copy'),
                        onTap: () => onCopyMetadata(rjCode),
                        onSecondaryTap:
                            defaultTargetPlatform == TargetPlatform.windows
                            ? () => onCopyMetadata(rjCode)
                            : null,
                        onLongPress:
                            defaultTargetPlatform == TargetPlatform.android
                            ? () => onCopyMetadata(rjCode)
                            : () {},
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 10,
                          ),
                          child: Text(
                            rjCode,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: accentColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '|',
                      style: TextStyle(
                        color: Colors.grey.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Icon(
                    Icons.storefront_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Semantics(
                      button: circleName.isNotEmpty,
                      label: circleName.isNotEmpty ? circleName : null,
                      child: InkWell(
                        key: const ValueKey<String>('work_detail_circle_copy'),
                        onTap: circleName.isEmpty
                            ? null
                            : () => onCopyMetadata(circleName),
                        onSecondaryTap:
                            circleName.isEmpty ||
                                defaultTargetPlatform != TargetPlatform.windows
                            ? null
                            : () => onCopyMetadata(circleName),
                        onLongPress: circleName.isEmpty
                            ? null
                            : defaultTargetPlatform == TargetPlatform.android
                            ? () => onCopyMetadata(circleName)
                            : () {},
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            circleName.isNotEmpty ? circleName : '--',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Floating Back Button (top-left)
          Positioned(
            top: topSafeArea + 6,
            left: 16,
            child: HeaderFloatingButton(
              child: IconButton(
                key: const ValueKey<String>('work_detail_back_button'),
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: onBackPressed,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              ),
            ),
          ),
          if (onEditPressed != null)
            Positioned(
              top: topSafeArea + 6,
              right: 16,
              child: HeaderFloatingButton(
                child: IconButton(
                  key: const ValueKey<String>('work_detail_edit'),
                  onPressed: onEditPressed,
                  tooltip: editLabel,
                  icon: const Icon(Icons.edit_rounded),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _WorkDetailHeaderDelegate oldDelegate) {
    return oldDelegate.title != title ||
        oldDelegate.rjCode != rjCode ||
        oldDelegate.circleName != circleName ||
        oldDelegate.coverWidget != coverWidget ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.surfaceColor != surfaceColor ||
        oldDelegate.onEditPressed != onEditPressed ||
        oldDelegate.editLabel != editLabel;
  }
}
