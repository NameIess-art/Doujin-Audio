import '../playback_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../../app/application/audio_path_coordinator.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/logging/app_log_service.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_time_segment_service.dart';
import '../../domain/time_segment_label.dart';
import '../../../asmr/domain/asmr_models.dart';
import '../../../asmr/presentation/asmr_work_detail_sheet.dart';
import '../../../library/presentation/audio_detail_sheet.dart';
import 'playlist_progress_widgets.dart';
import 'playlist_subtitle_panel.dart';
import 'playlist_subtitle_menu_sheet.dart';
import 'playlist_shared_helpers.dart';
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
  VoidCallback? _pendingSegmentResult;
  bool _segmentLabelsLoaded = false;
  bool _syncingSegmentText = false;
  bool _savingSegment = false;
  Completer<void>? _segmentSaveCompletion;
  bool _segmentSaveQueued = false;
  bool _deletingSegment = false;
  int _segmentDraftGeneration = 0;
  final Set<(String, String)> _pendingNewSegmentNames = <(String, String)>{};

  PlaybackFacade get _playback => ref.read(playbackFacadeProvider);
  AudioPathCoordinator get _paths => ref.read(audioPathCoordinatorProvider);
  PlaybackTimeSegmentService get _timeSegments =>
      ref.read(playbackTimeSegmentServiceProvider);

  bool get isSegmentPanelExpanded => _segmentPanelExpanded;

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
    setState(() {
      _segmentPanelExpanded = false;
      _clearSegmentDraft();
    });
    widget.segmentPanelExpandedNotifier?.value = false;
  }

  @override
  void initState() {
    super.initState();
    widget.segmentPanelExpandedNotifier?.value = _segmentPanelExpanded;
    widget.transitionActive?.addListener(_scheduleSegmentResult);
    widget.transitionActive?.addListener(_scheduleSiblingQuery);
    _segmentNameController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
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
    if (oldWidget.session.id != widget.session.id) _segmentTrackKey = null;
    _syncSegmentTrack();
    _syncSiblingQuery();
  }

  @override
  void dispose() {
    _segmentNameDebounce?.cancel();
    _segmentLoadGeneration++;
    widget.transitionActive?.removeListener(_scheduleSegmentResult);
    widget.transitionActive?.removeListener(_scheduleSiblingQuery);
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
        ? session.playbackQueue!.entries.any((entry) => entry.tracks.isNotEmpty)
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
      group: 'session_detail_siblings',
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
    setState(() {
      _segmentDraftGeneration++;
      _applySelectedSegment(label);
      _segmentPanelExpanded = true;
      _segmentEditorVisible = true;
    });
  }

  void _startNewSegment() {
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

  void _toggleSelectedSegmentLoop() {
    final selected = _selectedSegment;
    if (selected == null) return;
    _timeSegments.toggleLoop(sessionId: widget.session.id, label: selected);
    setState(() {});
  }

  void _handleSegmentManualSeek(Duration position) {
    _timeSegments.handleManualSeek(widget.session.id, position);
  }

  void _setDraftStartToCurrent() {
    setState(() {
      _draftStart = _clampToDuration(_currentSessionPosition);
      _draftColorValue ??= _timeSegments.nextColor(_segmentLabels);
    });
    unawaited(_trySaveSegmentDraft());
  }

  void _setDraftEndToCurrent() {
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
    final next = await showSegmentTimeInputDialog(context, initial: current);
    if (next == null || !mounted) return;
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
    if (_deletingSegment) return;
    if (_savingSegment) {
      _segmentSaveQueued = true;
      return;
    }
    final trackKey = _segmentTrackKey;
    final name = _segmentNameController.text.trim();
    final start = _draftStart;
    final end = _draftEnd;
    final draftGeneration = _segmentDraftGeneration;
    if (trackKey == null ||
        name.isEmpty ||
        start == null ||
        end == null ||
        end <= start) {
      return;
    }
    _savingSegment = true;
    final saveCompletion = Completer<void>();
    _segmentSaveCompletion = saveCompletion;
    (String, String)? pendingReservation;
    try {
      final existing = _selectedSegmentId == null
          ? null
          : _segmentLabels
                .where((label) => label.id == _selectedSegmentId)
                .firstOrNull;
      if (existing == null) {
        pendingReservation = (trackKey, name);
        _pendingNewSegmentNames.add(pendingReservation);
      }
      final label = _timeSegments.buildLabel(
        trackKey: trackKey,
        name: name,
        start: start,
        end: end,
        colorValue:
            existing?.colorValue ??
            _draftColorValue ??
            _timeSegments.nextColor(_segmentLabels),
        existing: existing,
      );
      final backupSucceeded = await _timeSegments.saveLabel(label);
      if (!mounted || _segmentTrackKey != trackKey) return;
      setState(() {
        if (_segmentDraftGeneration == draftGeneration) {
          _selectedSegmentId ??= label.id;
        }
        _segmentLabels =
            [
              for (final current in _segmentLabels)
                if (current.id != label.id) current,
              label,
            ]..sort((a, b) {
              final startOrder = a.start.compareTo(b.start);
              return startOrder != 0
                  ? startOrder
                  : a.createdAt.compareTo(b.createdAt);
            });
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
    } finally {
      if (pendingReservation != null) {
        _pendingNewSegmentNames.remove(pendingReservation);
      }
      _savingSegment = false;
      _segmentSaveCompletion = null;
      saveCompletion.complete();
      if (_segmentSaveQueued && mounted) {
        _segmentSaveQueued = false;
        unawaited(_trySaveSegmentDraft());
      }
    }
  }

  Future<void> _deleteSelectedSegment() async {
    if (_deletingSegment) return;
    final selected = _segmentLabels
        .where((label) => label.id == _selectedSegmentId)
        .firstOrNull;
    if (selected == null) return;
    _deletingSegment = true;
    _segmentNameDebounce?.cancel();
    _segmentSaveQueued = false;
    final timeSegments = _timeSegments;
    try {
      await _segmentSaveCompletion?.future;
      final labels = await timeSegments.loadLabels(selected.trackKey);
      final removedLabel = labels
          .where((label) => label.id == selected.id)
          .firstOrNull;
      if (removedLabel == null) return;
      final backupSucceeded = await timeSegments.deleteLabel(removedLabel);
      if (!mounted || _segmentTrackKey != selected.trackKey) return;
      setState(() {
        _segmentLabels = _segmentLabels
            .where((label) => label.id != selected.id)
            .toList(growable: false);
        if (_selectedSegmentId == selected.id) _clearSegmentDraft();
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
        icon: Icons.sell_rounded,
        duration: kUndoableRemovalFeedbackDuration,
        actionLabel: i18n.tr('undo'),
        onAction: () =>
            unawaited(_restoreDeletedSegment(removedLabel, timeSegments)),
      );
    } finally {
      _deletingSegment = false;
    }
  }

  Future<void> _restoreDeletedSegment(
    TimeSegmentLabel label,
    PlaybackTimeSegmentService timeSegments,
  ) async {
    final backupSucceeded = await timeSegments.saveLabel(label);
    if (!mounted) return;
    if (_segmentTrackKey == label.trackKey) {
      await _loadSegmentLabels(label.trackKey);
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
    final track = _paths.trackByPath(session.currentTrackPath);
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

    final hasSiblings = session.isPlaybackQueue
        ? session.playbackQueue!.entries.any((entry) => entry.tracks.isNotEmpty)
        : _siblingTrackPath == session.currentTrackPath &&
              _siblingStructureRevision == paths.library.structureRevision
        ? _hasSiblings
        : paths.cachedHasOtherTracksInSameWork(session.currentTrackPath) ??
              false;
    final selectedSegmentId = _segmentPanelExpanded ? _selectedSegmentId : null;

    Widget buildProgressBar() {
      return SessionProgressBar(
        key: ValueKey('progress_${session.id}'),
        session: session,
        playback: playback,
        paths: paths,
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
        paths: paths,
        hasSiblings: hasSiblings,
        segmentPanelExpanded: _segmentPanelExpanded,
        isLandscape: widget.isLandscape,
        hasSubtitle: widget.hasSubtitle,
        subtitleEnabled: widget.subtitleEnabled,
        subtitleGlobalEnabled: widget.subtitleGlobalEnabled,
        onShowTrackSwitcher: () => _showTrackSwitcher(context),
        onToggleSegments: _segmentPanelExpanded
            ? collapseSegmentPanel
            : expandSegmentPanel,
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
      isLandscape: widget.isLandscape,
      padding: resolvedDetailPadding,
      segmentPanelExpanded: _segmentPanelExpanded,
      artwork: KeyedSubtree(key: _artworkKey, child: widget.artworkWidget),
      isVideo: track?.isVideo == true,
      title: displayName,
      sessionId: session.id,
      progress: buildProgressBar(),
      transport: buildTransportControls(),
      subtitle: SessionSubtitlePanel(
        transitionActive: widget.transitionActive,
        session: session,
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
      draftColorValue: _draftColorValue,
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
      onDelete: _deleteSelectedSegment,
      onToggleLoop: _toggleSelectedSegmentLoop,
      onClose: collapseSegmentPanel,
    );
  }

  void _showTrackSwitcher(BuildContext context) {
    final session = _playback.sessionSnapshotById(widget.session.id);
    if (session == null) return;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final tracks = orderTracksForSessionSwitcher(
      session.isPlaybackQueue
          ? session.playbackQueue!.expandedTracks
          : _paths.tracksForSessionSwitcher(session.id),
      preserveQueueOrder: session.isPlaybackQueue,
    );
    if (tracks.isEmpty) return;
    final workRoot = _paths.workRootForTrack(session.currentTrackPath);
    var selectionStarted = false;
    AppBottomSheet.show<void>(
      context: context,
      builder: (ctx) {
        return SessionTrackSwitcherSheet(
          session: session,
          tracks: tracks,
          workRoot: workRoot,
          resolveTrack: _paths.trackByPath,
          workRootForTrack: _paths.workRootForTrack,
          onSelected: (selectedNode) {
            if (selectionStarted) return;
            selectionStarted = true;
            final route = ModalRoute.of(ctx)!;
            unawaited(() async {
              unawaited(
                AppInteractionFeedback.trigger(
                  AppInteractionFeedbackType.tap,
                  context: ctx,
                ),
              );
              Navigator.of(ctx).pop();
              await route.completed;
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
  }
}
