import '../playback_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../../app/application/audio_path_coordinator.dart';
import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/logging/app_log_service.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_time_segment_service.dart';
import '../../application/session_switcher_tree.dart';
import '../../domain/time_segment_label.dart';
import '../../../asmr/domain/asmr_models.dart';
import '../../../asmr/presentation/asmr_work_detail_sheet.dart';
import '../../../library/presentation/audio_detail_sheet.dart';
import '../../../library/presentation/library_providers.dart';
import '../../../library/presentation/remote_library_work_detail.dart';
import 'playlist_progress_widgets.dart';
import 'playlist_subtitle_panel.dart';
import 'playlist_subtitle_menu_sheet.dart';
import 'playlist_time_segments.dart';
import 'playlist_transport_controls.dart';

import 'session_detail_layout.dart';
import 'session_track_switcher_sheet.dart';

class SessionDetailContent extends ConsumerStatefulWidget {
  const SessionDetailContent({
    super.key,
    required this.session,
    required this.artworkWidget,
    this.segmentPanelExpandedNotifier,
    this.transitionActive,
    this.showCoverOverlays = true,
    this.isLandscape = false,
    this.detailPadding = EdgeInsets.zero,
    this.hasSubtitle = false,
    this.subtitleEnabled = true,
    this.subtitleGlobalEnabled = false,
    this.onToggleSubtitle,
    this.onToggleGlobalSubtitle,
  });

  final PlaybackSessionSnapshot session;
  final Widget artworkWidget;
  final ValueNotifier<bool>? segmentPanelExpandedNotifier;
  final ValueListenable<bool>? transitionActive;
  final bool showCoverOverlays;
  final bool isLandscape;
  final EdgeInsetsGeometry detailPadding;
  final bool hasSubtitle;
  final bool subtitleEnabled;
  final bool subtitleGlobalEnabled;
  final VoidCallback? onToggleSubtitle;
  final VoidCallback? onToggleGlobalSubtitle;

  @override
  ConsumerState<SessionDetailContent> createState() =>
      SessionDetailContentState();
}

class SessionDetailContentState extends ConsumerState<SessionDetailContent> {
  // Reparent the artwork across orientations without losing fullscreen ownership.
  final _artworkKey = GlobalKey();
  late final TextEditingController _segmentNameController;
  bool _segmentPanelExpanded = false;
  bool _segmentEditorVisible = false;
  bool _segmentLoading = false;
  List<TimeSegmentLabel> _segmentLabels = const <TimeSegmentLabel>[];
  String? _segmentTrackKey;
  String? _selectedSegmentId;
  Duration? _draftStart;
  Duration? _draftEnd;
  int? _draftColorValue;
  Timer? _segmentNameDebounce;
  int _segmentLoadGeneration = 0;
  late final String _segmentCommitKey =
      'detail_segments_${identityHashCode(this)}';
  late final String _siblingTaskKey =
      'detail_siblings_${identityHashCode(this)}';
  String? _siblingSessionId;
  String? _siblingTrackPath;
  int _siblingStructureRevision = -1;
  int _siblingGeneration = 0;
  bool _hasSiblings = false;
  bool _openingTrackSwitcher = false;
  VoidCallback? _pendingSegmentResult;
  bool _segmentLabelsLoaded = false;
  bool _syncingSegmentText = false;
  Completer<void>? _segmentWriteCompletion;
  (int, TimeSegmentLabel)? _capturedSegmentDraft;
  String? _deletingSegmentId;
  int _segmentDraftGeneration = 0;
  final Set<(String, String)> _pendingNewSegmentNames = <(String, String)>{};

  PlaybackFacade get _playback => ref.read(playbackFacadeProvider);
  AudioPathCoordinator get _paths => ref.read(audioPathCoordinatorProvider);
  late final PlaybackTimeSegmentService _timeSegments;

  void expandSegmentPanel() {
    if (_segmentPanelExpanded) return;
    _scheduleSegmentLoad();
    setState(() {
      _segmentPanelExpanded = true;
    });
    widget.segmentPanelExpandedNotifier?.value = true;
  }

  void collapseSegmentPanel() {
    if (!_segmentPanelExpanded) return;
    _flushSegmentNameDraft();
    setState(() {
      _segmentPanelExpanded = false;
      _clearSegmentDraft();
    });
    widget.segmentPanelExpandedNotifier?.value = false;
  }

  void _handleSegmentPanelNotifierChanged() {
    if (widget.segmentPanelExpandedNotifier?.value == false &&
        _segmentPanelExpanded) {
      collapseSegmentPanel();
    }
  }

  @override
  void initState() {
    super.initState();
    _timeSegments = ref.read(playbackTimeSegmentServiceProvider);
    widget.transitionActive?.addListener(_scheduleSegmentResult);
    widget.transitionActive?.addListener(_scheduleSiblingQuery);
    widget.segmentPanelExpandedNotifier?.addListener(
      _handleSegmentPanelNotifierChanged,
    );
    _segmentNameController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (widget.segmentPanelExpandedNotifier?.value !=
            _segmentPanelExpanded) {
          widget.segmentPanelExpandedNotifier?.value = _segmentPanelExpanded;
        }
        _syncSegmentTrack();
        _syncSiblingQuery();
      }
    });
    _segmentNameController.addListener(_handleSegmentNameChanged);
  }

  @override
  void didUpdateWidget(covariant SessionDetailContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionActive != widget.transitionActive) {
      oldWidget.transitionActive?.removeListener(_scheduleSegmentResult);
      oldWidget.transitionActive?.removeListener(_scheduleSiblingQuery);
      widget.transitionActive?.addListener(_scheduleSegmentResult);
      widget.transitionActive?.addListener(_scheduleSiblingQuery);
      _scheduleSegmentResult();
      _scheduleSiblingQuery();
    }
    if (oldWidget.segmentPanelExpandedNotifier !=
        widget.segmentPanelExpandedNotifier) {
      oldWidget.segmentPanelExpandedNotifier?.removeListener(
        _handleSegmentPanelNotifierChanged,
      );
      widget.segmentPanelExpandedNotifier?.addListener(
        _handleSegmentPanelNotifierChanged,
      );
    }
    if (oldWidget.session.id != widget.session.id) {
      _flushSegmentNameDraft();
      _segmentTrackKey = null;
    }
    _syncSegmentTrack();
    _syncSiblingQuery();
  }

  @override
  void dispose() {
    _flushSegmentNameDraft();
    _segmentLoadGeneration++;
    widget.transitionActive?.removeListener(_scheduleSegmentResult);
    widget.transitionActive?.removeListener(_scheduleSiblingQuery);
    widget.segmentPanelExpandedNotifier?.removeListener(
      _handleSegmentPanelNotifierChanged,
    );
    UiInteractionCoordinator.instance.cancelCommit(_segmentCommitKey);
    _pendingSegmentResult = null;
    _segmentNameController.removeListener(_handleSegmentNameChanged);
    _segmentNameController.dispose();
    super.dispose();
  }

  void _syncSegmentTrack() {
    final track = _paths.trackByPath(widget.session.currentTrackPath);
    final nextKey = track == null
        ? PathMatcher.normalize(widget.session.currentTrackPath)
        : _timeSegments.trackKeyForTrack(track);
    if (nextKey == _segmentTrackKey) return;
    _flushSegmentNameDraft();
    _segmentLoadGeneration++;
    UiInteractionCoordinator.instance.cancelCommit(_segmentCommitKey);
    _pendingSegmentResult = null;
    _segmentTrackKey = nextKey;
    _segmentLabelsLoaded = false;
    _segmentLabels = const <TimeSegmentLabel>[];
    _segmentLoading = false;
    _segmentDraftGeneration++;
    _segmentEditorVisible = false;
    _selectedSegmentId = null;
    _draftStart = null;
    _draftEnd = null;
    _draftColorValue = null;
    _setSegmentNameText('');
    _scheduleSegmentLoad();
  }

  void _scheduleSegmentLoad() {
    final trackKey = _segmentTrackKey;
    if (trackKey == null ||
        _segmentLoading ||
        _segmentLabelsLoaded ||
        widget.transitionActive?.value == true) {
      return;
    }
    final generation = _segmentLoadGeneration;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _segmentCommitKey,
      commit: () {
        if (!mounted ||
            generation != _segmentLoadGeneration ||
            trackKey != _segmentTrackKey ||
            widget.transitionActive?.value == true) {
          return;
        }
        unawaited(_loadSegmentLabels(trackKey));
      },
    );
  }

  Future<void> _loadSegmentLabels(String trackKey) async {
    if (_segmentLoading) return;
    final generation = ++_segmentLoadGeneration;
    setState(() {
      _segmentLoading = true;
    });
    try {
      final labels = await _timeSegments.loadLabels(trackKey);
      if (!mounted || generation != _segmentLoadGeneration) return;
      _pendingSegmentResult = () {
        final selected = labels
            .where((label) => label.id == _selectedSegmentId)
            .firstOrNull;
        setState(() {
          _segmentLabels = labels;
          _segmentLabelsLoaded = true;
          _segmentLoading = false;
          if (selected != null) _applySelectedSegment(selected);
        });
      };
      _scheduleSegmentResult();
    } catch (error, stack) {
      if (!mounted || generation != _segmentLoadGeneration) return;
      AppLogService.warning(
        'Time segment labels failed to load',
        error: error,
        stackTrace: stack,
      );
      _pendingSegmentResult = () => setState(() => _segmentLoading = false);
      _scheduleSegmentResult();
    }
  }

  void _scheduleSegmentResult() {
    if (_pendingSegmentResult == null) {
      _scheduleSegmentLoad();
      return;
    }
    if (widget.transitionActive?.value == true) {
      return;
    }
    final generation = _segmentLoadGeneration;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _segmentCommitKey,
      commit: () {
        if (!mounted ||
            generation != _segmentLoadGeneration ||
            widget.transitionActive?.value == true) {
          return;
        }
        final apply = _pendingSegmentResult;
        _pendingSegmentResult = null;
        apply?.call();
      },
    );
  }

  void _syncSiblingQuery() {
    final session = widget.session;
    final revision = _paths.library.structureRevision;
    if (_siblingSessionId == session.id &&
        _siblingTrackPath == session.currentTrackPath &&
        _siblingStructureRevision == revision) {
      return;
    }
    _siblingGeneration++;
    _siblingSessionId = session.id;
    _siblingTrackPath = session.currentTrackPath;
    _siblingStructureRevision = revision;
    _hasSiblings = session.isPlaybackQueue
        ? session.playbackQueue!.trackCount > 0
        : _paths.cachedHasOtherTracksInSameWork(session.currentTrackPath) ??
              false;
    _scheduleSiblingQuery();
  }

  void _scheduleSiblingQuery() {
    if (widget.session.isPlaybackQueue ||
        widget.transitionActive?.value == true ||
        _paths.cachedHasOtherTracksInSameWork(
              widget.session.currentTrackPath,
            ) !=
            null) {
      return;
    }
    final coordinator = UiInteractionCoordinator.instance;
    final generation = _siblingGeneration;
    final sessionId = widget.session.id;
    final trackPath = widget.session.currentTrackPath;
    final revision = _siblingStructureRevision;
    final coordinatorGeneration = coordinator.generation;
    coordinator.scheduleAfterIdle(
      key: '${_siblingTaskKey}_$generation',
      generation: coordinatorGeneration,
      priority: 20,
      task: () async {
        await Future<void>.delayed(Duration.zero);
        if (!mounted ||
            generation != _siblingGeneration ||
            sessionId != widget.session.id ||
            trackPath != widget.session.currentTrackPath ||
            revision != _paths.library.structureRevision ||
            widget.transitionActive?.value == true) {
          return;
        }
        final hasSiblings = _paths.hasOtherTracksInSameWork(trackPath);
        if (mounted &&
            generation == _siblingGeneration &&
            sessionId == widget.session.id &&
            trackPath == widget.session.currentTrackPath &&
            revision == _paths.library.structureRevision &&
            widget.transitionActive?.value != true &&
            hasSiblings != _hasSiblings) {
          setState(() => _hasSiblings = hasSiblings);
        }
      },
    );
  }

  void _handleSegmentNameChanged() {
    if (_syncingSegmentText) return;
    _segmentNameDebounce?.cancel();
    _segmentNameDebounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_trySaveSegmentDraft()),
    );
  }

  void _flushSegmentNameDraft() {
    if (_segmentNameDebounce?.isActive != true) return;
    _segmentNameDebounce!.cancel();
    // Capture the old draft before a track, selection or page replaces it.
    unawaited(_trySaveSegmentDraft());
  }

  void _setSegmentNameText(String value) {
    _syncingSegmentText = true;
    _segmentNameController.text = value;
    _segmentNameController.selection = TextSelection.collapsed(
      offset: value.length,
    );
    _syncingSegmentText = false;
  }

  void _clearSegmentDraft() {
    _segmentDraftGeneration++;
    _segmentEditorVisible = false;
    _selectedSegmentId = null;
    _draftStart = null;
    _draftEnd = null;
    _draftColorValue = null;
    _setSegmentNameText('');
  }

  TimeSegmentLabel? get _selectedSegment {
    final selectedId = _selectedSegmentId;
    if (selectedId == null) return null;
    return _segmentLabels.where((label) => label.id == selectedId).firstOrNull;
  }

  void _applySelectedSegment(TimeSegmentLabel label) {
    _selectedSegmentId = label.id;
    _draftStart = label.start;
    _draftEnd = label.end;
    _draftColorValue = label.colorValue;
    _setSegmentNameText(label.name);
  }

  void _selectSegment(TimeSegmentLabel label) {
    if (_selectedSegmentId != label.id || !_segmentEditorVisible) {
      unawaited(
        AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
      );
    }
    _flushSegmentNameDraft();
    setState(() {
      _segmentDraftGeneration++;
      _applySelectedSegment(label);
      _segmentPanelExpanded = true;
      _segmentEditorVisible = true;
    });
  }

  void _startNewSegment() {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    _flushSegmentNameDraft();
    final defaultName = _nextSegmentDefaultName();
    setState(() {
      _segmentDraftGeneration++;
      _selectedSegmentId = null;
      _draftStart = null;
      _draftEnd = null;
      _draftColorValue = _timeSegments.nextColor(_segmentLabels);
      _setSegmentNameText(defaultName);
      _segmentPanelExpanded = true;
      _segmentEditorVisible = true;
    });
  }

  String _nextSegmentDefaultName() {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final trackKey = _segmentTrackKey;
    final pendingNames = _pendingNewSegmentNames
        .where((entry) => entry.$1 == trackKey)
        .map((entry) => entry.$2)
        .toSet();
    final usedNames = _segmentLabels
        .map((label) => label.name.trim())
        .followedBy(pendingNames)
        .toSet();
    var index = _segmentLabels.length + pendingNames.length + 1;
    while (true) {
      final name = i18n.tr('segment_default_name', {'index': index});
      if (!usedNames.contains(name)) {
        return name;
      }
      index++;
    }
  }

  void _toggleSegmentLoop(TimeSegmentLabel target) {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    _timeSegments.toggleLoop(sessionId: widget.session.id, label: target);
    setState(() {});
  }

  void _handleSegmentManualSeek(Duration position) {
    _timeSegments.handleManualSeek(widget.session.id, position);
  }

  void _setDraftStartToCurrent() {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    setState(() {
      _draftStart = _clampToDuration(_currentSessionPosition);
      _draftColorValue ??= _timeSegments.nextColor(_segmentLabels);
    });
    unawaited(_trySaveSegmentDraft());
  }

  void _setDraftEndToCurrent() {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    setState(() {
      _draftEnd = _clampToDuration(_currentSessionPosition);
      _draftColorValue ??= _timeSegments.nextColor(_segmentLabels);
    });
    unawaited(_trySaveSegmentDraft());
  }

  Duration get _currentSessionPosition =>
      _playback.sessionById(widget.session.id)?.position ??
      widget.session.position;

  Duration? get _currentSessionDuration =>
      _playback.sessionById(widget.session.id)?.duration ??
      widget.session.duration;

  Duration _clampToDuration(Duration value) {
    final duration = _currentSessionDuration;
    if (duration != null && duration > Duration.zero && value >= duration) {
      return duration;
    }
    if (value <= Duration.zero) return Duration.zero;
    return Duration(seconds: value.inSeconds);
  }

  Future<void> _editDraftTime({required bool isStart}) async {
    final current = isStart ? _draftStart : _draftEnd;
    final generation = _segmentDraftGeneration;
    final trackKey = _segmentTrackKey;
    final next = await showSegmentTimeInputDialog(context, initial: current);
    if (next == null ||
        !mounted ||
        generation != _segmentDraftGeneration ||
        trackKey != _segmentTrackKey) {
      return;
    }
    setState(() {
      if (isStart) {
        _draftStart = _clampToDuration(next);
      } else {
        _draftEnd = _clampToDuration(next);
      }
      _draftColorValue ??= _timeSegments.nextColor(_segmentLabels);
    });
    unawaited(_trySaveSegmentDraft());
  }

  Future<void> _trySaveSegmentDraft() async {
    final trackKey = _segmentTrackKey;
    final name = _segmentNameController.text.trim();
    final start = _draftStart;
    final end = _draftEnd;
    final draftGeneration = _segmentDraftGeneration;
    if (trackKey == null ||
        (_deletingSegmentId != null &&
            _deletingSegmentId == _selectedSegmentId) ||
        name.isEmpty ||
        start == null ||
        end == null ||
        end <= start) {
      return;
    }
    final timeSegments = _timeSegments;
    final previousWrite = _segmentWriteCompletion;
    final saveCompletion = Completer<void>();
    _segmentWriteCompletion = saveCompletion;
    (String, String)? pendingReservation;
    try {
      final existing = _capturedSegmentDraft?.$1 == draftGeneration
          ? _capturedSegmentDraft!.$2
          : _selectedSegment;
      if (existing == null) {
        pendingReservation = (trackKey, name);
        _pendingNewSegmentNames.add(pendingReservation);
      }
      final label = timeSegments.buildLabel(
        trackKey: trackKey,
        name: name,
        start: start,
        end: end,
        colorValue:
            existing?.colorValue ??
            _draftColorValue ??
            timeSegments.nextColor(_segmentLabels),
        existing: existing,
      );
      _capturedSegmentDraft = (draftGeneration, label);
      await previousWrite?.future;
      final backupSucceeded = await timeSegments.saveLabel(label);
      if (!mounted || _segmentTrackKey != trackKey) return;
      setState(() {
        if (_segmentDraftGeneration == draftGeneration) {
          _selectedSegmentId ??= label.id;
        }
        _upsertVisibleSegmentLabel(label);
      });
      if (!backupSucceeded) {
        final i18n = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(appLanguageProviderInstanceProvider);
        showAppSnackBar(
          context,
          i18n.tr('audio_detail_backup_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Time segment label failed to save',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('operation_failed_retry'),
          tone: AppFeedbackTone.warning,
        );
      }
    } finally {
      if (pendingReservation != null) {
        _pendingNewSegmentNames.remove(pendingReservation);
      }
      if (identical(_segmentWriteCompletion, saveCompletion)) {
        _segmentWriteCompletion = null;
      }
      saveCompletion.complete();
    }
  }

  void _upsertVisibleSegmentLabel(TimeSegmentLabel label) {
    _segmentLabels = [
      for (final current in _segmentLabels)
        if (current.id != label.id) current,
      label,
    ]..sort((a, b) {
      final startOrder = a.start.compareTo(b.start);
      return startOrder != 0 ? startOrder : a.createdAt.compareTo(b.createdAt);
    });
  }

  Future<void> _deleteSegment(TimeSegmentLabel target) async {
    if (_deletingSegmentId != null) return;
    _deletingSegmentId = target.id;
    if (_selectedSegmentId == target.id) _segmentNameDebounce?.cancel();
    final previousWrite = _segmentWriteCompletion;
    final deleteCompletion = Completer<void>();
    _segmentWriteCompletion = deleteCompletion;
    final timeSegments = _timeSegments;
    try {
      await previousWrite?.future;
      final labels = await timeSegments.loadLabels(target.trackKey);
      final removedLabel = labels
          .where((label) => label.id == target.id)
          .firstOrNull;
      if (removedLabel == null) return;
      unawaited(
        AppInteractionFeedback.trigger(AppInteractionFeedbackType.destructive),
      );
      final backupSucceeded = await timeSegments.deleteLabel(removedLabel);
      if (!mounted || _segmentTrackKey != target.trackKey) return;
      setState(() {
        _segmentLabels = _segmentLabels
            .where((label) => label.id != target.id)
            .toList(growable: false);
        if (_selectedSegmentId == target.id) _clearSegmentDraft();
      });
      final i18n = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        backupSucceeded
            ? i18n.tr('items_removed_count', {'count': 1})
            : i18n.tr('audio_detail_backup_failed'),
        tone: backupSucceeded
            ? AppFeedbackTone.destructive
            : AppFeedbackTone.warning,
        icon: backupSucceeded
            ? Icons.delete_outline_rounded
            : Icons.warning_amber_rounded,
        isUndoAction: true,
        actionLabel: i18n.tr('undo'),
        onAction: () =>
            unawaited(_restoreDeletedSegment(removedLabel, timeSegments)),
      );
    } finally {
      _deletingSegmentId = null;
      if (identical(_segmentWriteCompletion, deleteCompletion)) {
        _segmentWriteCompletion = null;
      }
      deleteCompletion.complete();
    }
  }

  Future<void> _restoreDeletedSegment(
    TimeSegmentLabel label,
    PlaybackTimeSegmentService timeSegments,
  ) async {
    final backupSucceeded = await timeSegments.saveLabel(label);
    if (!mounted) return;
    if (_segmentTrackKey == label.trackKey) {
      setState(() => _upsertVisibleSegmentLabel(label));
    }
    if (!backupSucceeded && mounted) {
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      showAppSnackBar(
        context,
        i18n.tr('audio_detail_backup_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  void _openWorkDetail(BuildContext context) {
    final session = widget.session;
    if (session.currentTrackPath.trim().isEmpty) return;
    final track =
        _paths.sessionTrackForPath(session.id, session.currentTrackPath) ??
        _paths.trackByPath(session.currentTrackPath);
    if (track?.isRemoteAsmr == true && track?.remoteMetadata != null) {
      unawaited(
        showAsmrWorkDetailSheet(
          context,
          AsmrWork.fromJson(track!.remoteMetadata!),
          returnToMain: true,
        ),
      );
      return;
    }
    if (track?.isRemoteSource == true) {
      final remoteWork = ref
          .read(remoteLibraryControllerProvider)
          .resolveWorkForTrack(track!);
      if (remoteWork != null) {
        unawaited(
          openRemoteLibraryWorkDetail(
            context,
            remoteWork,
            returnToMain: true,
          ),
        );
      }
      return;
    }
    final target = track != null
        ? _paths.library.audioDetailTargetForTrack(track)
        : _paths.library.audioDetailTargetForPath(session.currentTrackPath);
    unawaited(showAudioDetailSheet(context, target, returnToMain: true));
  }

  @override
  Widget build(BuildContext context) {
    final visibleSegmentLabels = _segmentLabels;
    final session = widget.session;
    final playback = _playback;
    final paths = _paths;

    final track = paths.trackByPath(session.currentTrackPath);
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(session.currentTrackPath);
    var circleName = '';
    var voiceActors = const <String>[];
    if (track?.isRemoteMedia == true) {
      circleName = track!.remoteCircleName;
      if (track.remoteMetadata case final metadata?
          when widget.showCoverOverlays) {
        voiceActors = AsmrWork.voiceActorsFromJson(metadata);
      }
    } else if (track != null) {
      final target = paths.library.audioDetailTargetForTrack(track);
      final canLoadCredits =
          widget.showCoverOverlays && widget.transitionActive?.value != true;
      // The prepared route can report completed while measuring offstage.
      // Its overlays are revealed after the visible entrance finishes.
      final detail =
          (canLoadCredits
              ? ref.watch(libraryDetailForTargetProvider(target)).value
              : null) ??
          paths.library.resolvedAudioDetail(target) ??
          paths.library.categorySnapshot?.detailFor(target);
      circleName = detail?.circleName ?? '';
      voiceActors = detail?.voiceActors ?? const <String>[];
    }

    final hasSiblings = session.isPlaybackQueue
        ? session.playbackQueue!.trackCount > 0
        : session.queueLoadingRequired ||
              (session.customQueueTracks?.length ?? 0) > 1 ||
              (_siblingTrackPath == session.currentTrackPath &&
                      _siblingStructureRevision ==
                          paths.library.structureRevision
                  ? _hasSiblings
                  : paths.cachedHasOtherTracksInSameWork(
                          session.currentTrackPath,
                        ) ??
                        false);
    final selectedSegmentId = _segmentPanelExpanded ? _selectedSegmentId : null;

    Widget buildProgressBar() {
      return SessionProgressBar(
        key: ValueKey('progress_${session.id}'),
        session: session,
        playback: playback,
        inlineTimecodes: widget.isLandscape,
        // This row's height also determines how much room the cover gets.
        compactSeekTarget: widget.isLandscape,
        timeSegmentLabels: visibleSegmentLabels,
        selectedSegmentId: selectedSegmentId,
        onManualSeek: _handleSegmentManualSeek,
      );
    }

    Widget buildTransportControls() {
      return TransportPlaybackControlPanel(
        key: ValueKey(widget.isLandscape ? 'controls_landscape' : 'controls'),
        session: session,
        playback: playback,
        hasSiblings: hasSiblings,
        segmentPanelExpanded: _segmentPanelExpanded,
        isLandscape: widget.isLandscape,
        showPrimaryControls: !widget.isLandscape,
        hasSubtitle: widget.hasSubtitle,
        subtitleEnabled: widget.subtitleEnabled,
        subtitleGlobalEnabled: widget.subtitleGlobalEnabled,
        onShowTrackSwitcher: () => _showTrackSwitcher(context),
        onOpenFeatures: expandSegmentPanel,
        onToggleSubtitle: widget.onToggleSubtitle,
        onToggleGlobalSubtitle: widget.onToggleGlobalSubtitle,
        onShowSubtitleMenu: () {
          unawaited(
            showSubtitleMenuBottomSheet(
              context: context,
              session: session,
              onToggleGlobalSubtitle: widget.onToggleGlobalSubtitle,
            ),
          );
        },
        onShowWorkDetail:
            session.currentTrackPath.isNotEmpty && track?.isSingle != true
            ? () => _openWorkDetail(context)
            : null,
      );
    }

    final resolvedDetailPadding = widget.detailPadding.resolve(
      Directionality.of(context),
    );

    return SessionDetailLayout(
      showCoverOverlays: widget.showCoverOverlays,
      isLandscape: widget.isLandscape,
      padding: resolvedDetailPadding,
      segmentPanelExpanded: _segmentPanelExpanded,
      artwork: KeyedSubtree(key: _artworkKey, child: widget.artworkWidget),
      isVideo: track?.isVideo == true,
      title: displayName,
      circleName: circleName,
      voiceActors: voiceActors,
      onCopyCredit: (value) {
        Clipboard.setData(ClipboardData(text: value));
        AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
        final i18n = ref.read(appLanguageProviderInstanceProvider);
        showAppSnackBar(
          context,
          i18n.tr('copied_to_clipboard', {'value': value}),
          icon: Icons.content_copy_rounded,
        );
      },
      sessionId: session.id,
      progress: buildProgressBar(),
      primaryTransport: PrimaryPlaybackControls(
        key: const ValueKey('session_detail_primary_controls'),
        session: session,
        playback: playback,
        isLandscape: widget.isLandscape,
      ),
      transport: buildTransportControls(),
      subtitle: SessionSubtitlePanel(
        transitionActive: widget.transitionActive,
        session: session,
        isLandscape: widget.isLandscape,
        subtitleEnabled: widget.subtitleEnabled,
      ),
      segmentPanelBuilder: (key) => _buildSegmentPanel(
        playback: playback,
        session: session,
        labels: visibleSegmentLabels,
        key: key,
      ),
    );
  }

  Widget _buildSegmentPanel({
    required PlaybackFacade playback,
    required PlaybackSessionSnapshot session,
    required List<TimeSegmentLabel> labels,
    required Key key,
  }) {
    return TimeSegmentPanel(
      key: key,
      session: session,
      playback: playback,
      labels: labels,
      selectedId: _selectedSegmentId,
      showEditor: _segmentEditorVisible,
      loading: _segmentLoading,
      nameController: _segmentNameController,
      draftStart: _draftStart,
      draftEnd: _draftEnd,
      loopSegmentId: _timeSegments.loopLabelIdForSession(
        session.id,
        trackKey: _segmentTrackKey,
      ),
      onSelect: _selectSegment,
      onAdd: _startNewSegment,
      onSetStart: _setDraftStartToCurrent,
      onSetEnd: _setDraftEndToCurrent,
      onEditStart: () => _editDraftTime(isStart: true),
      onEditEnd: () => _editDraftTime(isStart: false),
      onDelete: _deleteSegment,
      onToggleLoop: _toggleSegmentLoop,
      onClose: collapseSegmentPanel,
    );
  }

  Future<void> _showTrackSwitcher(BuildContext context) async {
    if (_openingTrackSwitcher) return;
    _openingTrackSwitcher = true;
    try {
      if (!await _playback.ensureSessionQueueLoaded(widget.session.id) ||
          !mounted ||
          !context.mounted) {
        return;
      }
      final session = _playback.sessionSnapshotById(widget.session.id);
      if (session == null) return;
      final i18n = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appLanguageProviderInstanceProvider);
      final tracks = session.isPlaybackQueue
          ? session.playbackQueue!.expandedTracks
          : await _paths.tracksForSessionSwitcher(session.id);
      bool canOpenSwitcher() {
        if (!mounted || !context.mounted || widget.session.id != session.id) {
          return false;
        }
        final current = _playback.sessionSnapshotById(session.id);
        return current != null &&
            current.currentTrackPath == session.currentTrackPath &&
            current.currentQueueIndex == session.currentQueueIndex &&
            current.queueVersion == session.queueVersion &&
            readAppRoute(context)?.isCurrent != false;
      }

      if (tracks.isEmpty || !canOpenSwitcher()) return;
      final tree = await prepareSessionSwitcherTree(
        tracks: tracks,
        queue: session.playbackQueue,
        customQueueTracks: session.customQueueTracks,
        currentPath: session.currentTrackPath,
        currentQueueIndex: session.currentQueueIndex,
        workRoot: session.isPlaybackQueue
            ? null
            : _paths.workRootForTrack(session.currentTrackPath),
        resolveTrack: _paths.trackByPath,
        workRootForTrack: _paths.workRootForTrack,
      );
      if (!context.mounted || !canOpenSwitcher()) return;
      var selectionStarted = false;
      await AppBottomSheet.show<void>(
        context: context,
        builder: (ctx) {
          return SessionTrackSwitcherSheet(
            session: session,
            trackCount: tracks.length,
            tree: tree,
            onSelected: (selectedNode) {
              if (selectionStarted) return;
              selectionStarted = true;
              final route = readAppRoute(ctx)!;
              unawaited(() async {
                Navigator.of(ctx).pop();
                if (!mounted) return;
                final current = _playback.sessionSnapshotById(session.id);
                if (current == null ||
                    current.playbackQueue != session.playbackQueue ||
                    (current.queueVersion != session.queueVersion &&
                        !listEquals(
                          current.customQueueTracks,
                          session.customQueueTracks,
                        ))) {
                  return;
                }
                if (session.isPlaybackQueue) {
                  await _playback.switchSessionQueueTrack(
                    session.id,
                    selectedNode.queueIndex,
                  );
                } else {
                  await _playback.switchSessionTrack(
                    session.id,
                    selectedNode.track.path,
                  );
                }
                // Prepare playback while the sheet exits; show feedback only
                // after its overlay has been removed.
                await route.completed;
                if (mounted) {
                  showAppSnackBar(
                    this.context,
                    i18n.tr('switch_audio'),
                    tone: AppFeedbackTone.success,
                    icon: Icons.queue_music_rounded,
                  );
                }
              }());
            },
          );
        },
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'session_switcher_prepare_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted && context.mounted) {
        final i18n = ref.read(appLanguageProviderInstanceProvider);
        showAppSnackBar(
          context,
          i18n.tr('operation_failed_retry'),
          tone: AppFeedbackTone.warning,
        );
      }
    } finally {
      _openingTrackSwitcher = false;
    }
  }
}
