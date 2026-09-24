import '../playback_providers.dart';
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../../app/application/audio_path_coordinator.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/natural_sort.dart';
import '../../../../core/media/path_display.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/logging/app_log_service.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_time_segment_service.dart';
import '../../domain/playback_queue.dart';
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
    final trackKey = _segmentTrackKey;
    if (trackKey != null && !_segmentLabelsLoaded && !_segmentLoading) {
      unawaited(_loadSegmentLabels(trackKey));
    }
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
    widget.transitionActive?.addListener(_scheduleSegmentResult);
    _segmentNameController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSegmentTrack();
    });
    _segmentNameController.addListener(_handleSegmentNameChanged);
  }

  @override
  void didUpdateWidget(covariant SessionDetailContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionActive != widget.transitionActive) {
      oldWidget.transitionActive?.removeListener(_scheduleSegmentResult);
      widget.transitionActive?.addListener(_scheduleSegmentResult);
      _scheduleSegmentResult();
    }
    if (oldWidget.session.id != widget.session.id) _segmentTrackKey = null;
    _syncSegmentTrack();
  }

  @override
  void dispose() {
    _segmentNameDebounce?.cancel();
    _segmentLoadGeneration++;
    widget.transitionActive?.removeListener(_scheduleSegmentResult);
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
    unawaited(_loadSegmentLabels(nextKey));
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
    if (_pendingSegmentResult == null ||
        widget.transitionActive?.value == true) {
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
    try {
      await _segmentSaveCompletion?.future;
      final backupSucceeded = await _timeSegments.deleteLabel(selected);
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
      );
    } finally {
      _deletingSegment = false;
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
          replace: true,
        ),
      );
      return;
    }
    final target = track != null
        ? _paths.library.audioDetailTargetForTrack(track)
        : _paths.library.audioDetailTargetForPath(session.currentTrackPath);
    unawaited(showAudioDetailSheet(context, target, replace: true));
  }

  @override
  Widget build(BuildContext context) {
    final visibleSegmentLabels = _segmentLabels;
    final cs = Theme.of(context).colorScheme;
    final session = widget.session;
    final playback = _playback;
    final paths = _paths;

    final track = paths.trackByPath(session.currentTrackPath);
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(session.currentTrackPath);

    final hasSiblings = session.isPlaybackQueue
        ? session.playbackQueue!.entries.any((entry) => entry.tracks.isNotEmpty)
        : paths.hasOtherTracksInSameWork(session.currentTrackPath);
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
              canImportSubtitle: track?.isRemoteAsmr != true,
              onToggleGlobalSubtitle: widget.onToggleGlobalSubtitle,
            ),
          );
        },
        onShowWorkDetail: session.currentTrackPath.isNotEmpty
            ? () => _openWorkDetail(context)
            : null,
      );
    }

    final resolvedDetailPadding = widget.detailPadding.resolve(
      Directionality.of(context),
    );

    if (widget.isLandscape) {
      return Padding(
        padding: resolvedDetailPadding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 12.0;
            const progressSpacing = 5.0;
            const approxProgressBarHeight = 36.0;
            final availableHeight = constraints.maxHeight;
            final idealCoverHeight = max(
              0.0,
              availableHeight - approxProgressBarHeight - progressSpacing,
            );
            // Left side prioritizes filling vertical height: width equals idealCoverHeight
            // Ensure right side has at least enough width for transport controls if possible
            final maxLeftWidth = constraints.maxWidth > 500
                ? max(0.0, constraints.maxWidth - 386)
                : constraints.maxWidth * 0.5;
            final leftWidth = min(idealCoverHeight, maxLeftWidth);

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: leftWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: 1.0,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  widget.artworkWidget,
                                  if (_segmentPanelExpanded)
                                    Positioned.fill(
                                      child: ColoredBox(
                                        color: cs.surface,
                                        child: _buildSegmentPanel(
                                          playback: playback,
                                          session: session,
                                          labels: visibleSegmentLabels,
                                          key: const ValueKey(
                                            'segments_landscape',
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
                      const SizedBox(height: progressSpacing),
                      RepaintBoundary(child: buildProgressBar()),
                    ],
                  ),
                ),
                const SizedBox(width: spacing),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 4,
                          right: 4,
                          bottom: 8,
                        ),
                        child: MarqueeText(
                          key: ValueKey(
                            'title_marquee_${session.id}',
                          ),
                          text: displayName,
                          allowAndroidMarquee: true,
                          pauseDuration: const Duration(
                            seconds: 1,
                          ),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                color: sessionDetailForeground(
                                  cs,
                                  SessionDetailForegroundLevel.strong,
                                  darkFallback: cs.onSurface,
                                ),
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      Expanded(
                        child: RepaintBoundary(
                          child: SessionSubtitlePanel(
                            transitionActive: widget.transitionActive,
                            session: session,
                            subtitleEnabled: widget.subtitleEnabled,
                          ),
                        ),
                      ),
                      buildTransportControls(),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverHeight = _segmentPanelExpanded
            ? 42.0
            : (constraints.maxWidth * 3 / 4);

        return Padding(
          padding: EdgeInsets.only(
            top: resolvedDetailPadding.top,
            bottom: resolvedDetailPadding.bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic,
                height: coverHeight,
                width: double.infinity,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!_segmentPanelExpanded) widget.artworkWidget,
                      if (track?.isVideo != true)
                        IgnorePointer(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              height: 42,
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              alignment: Alignment.centerLeft,
                              decoration: BoxDecoration(
                                gradient: _segmentPanelExpanded
                                    ? null
                                    : LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.black.withValues(alpha: 0.0),
                                          Colors.black.withValues(alpha: 0.65),
                                        ],
                                      ),
                                color: _segmentPanelExpanded
                                    ? cs.surfaceContainerHighest.withValues(alpha: 0.95)
                                    : null,
                              ),
                              child: MarqueeText(
                                key: ValueKey('title_marquee_${session.id}'),
                                text: displayName,
                                allowAndroidMarquee: true,
                                pauseDuration: const Duration(seconds: 1),
                                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                  color: _segmentPanelExpanded
                                      ? sessionDetailForeground(
                                          cs,
                                          SessionDetailForegroundLevel.medium,
                                          darkFallback: cs.onSurface.withValues(alpha: 0.8),
                                        )
                                      : Colors.white.withValues(alpha: 0.85),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: RepaintBoundary(
                  child: SessionSubtitlePanel(
                    transitionActive: widget.transitionActive,
                    session: session,
                    subtitleEnabled: widget.subtitleEnabled,
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: resolvedDetailPadding.left,
                ),
                child: RepaintBoundary(child: buildProgressBar()),
              ),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: resolvedDetailPadding.left,
                ),
                child: buildTransportControls(),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return SizeTransition(
                    sizeFactor: animation,
                    axisAlignment: -1.0,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.0, 0.2),
                        end: Offset.zero,
                      ).animate(animation),
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                  );
                },
                child: _segmentPanelExpanded
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: max(
                              220.0,
                              constraints.maxHeight - coverHeight - 44.0 - 92.0 - 50.0,
                            ),
                          ),
                          child: _buildSegmentPanel(
                            playback: playback,
                            session: session,
                            labels: visibleSegmentLabels,
                            key: const ValueKey('segments'),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('segments_closed')),
              ),
            ],
          ),
        );
      },
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
    final tree = _buildQueueTree(
      tracks,
      session: session,
      workRoot: workRoot,
      currentPath: session.currentTrackPath,
    );
    var selectionStarted = false;
    AppBottomSheet.show<void>(
      context: context,
      builder: (ctx) {
        return SizedBox(
          width: double.infinity,
          child: ListView.builder(
            shrinkWrap: tree.length <= 8,
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 24),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: tree.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _QueueSheetHeader(count: tracks.length),
                );
              }
              final node = tree[index - 1];
              return _QueueTreeNodeTile(
                key: ValueKey<String>(node.stableKey),
                node: node,
                onTrackTap: (selectedNode) {
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
                        !listEquals(
                          current.customQueueTracks,
                          session.customQueueTracks,
                        )) {
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
                        selectedNode.track!.path,
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
          ),
        );
      },
    );
  }

  List<_QueueTreeNode> _buildQueueTree(
    List<MusicTrack> tracks, {
    required PlaybackSessionSnapshot session,
    required String? workRoot,
    required String currentPath,
  }) {
    final root = _QueueTreeNode.folder('');
    final queueTracks = session.isPlaybackQueue
        ? tracks
        : session.customQueueTracks;
    final selectedTrack = resolveSessionSwitcherSelectedTrack(
      displayedTracks: tracks,
      queueTracks: queueTracks,
      currentPath: currentPath,
      currentQueueIndex: session.currentQueueIndex,
    );
    if (session.isPlaybackQueue) {
      var queueIndex = 0;
      final resolvedTracks = <String, MusicTrack?>{};
      for (final entry in session.playbackQueue!.entries) {
        final firstTrack = entry.tracks.firstOrNull;
        final isAsmrEntry = firstTrack?.isRemoteAsmr ?? false;
        final fallbackRoot = entry.workRootPath != null || firstTrack == null
            ? null
            : _paths.workRootForTrack(firstTrack.path);
        final groupRoot = firstTrack?.groupKey.trim();
        final entryWorkRoot =
            entry.workRootPath ??
            fallbackRoot ??
            ((groupRoot == null ||
                    groupRoot.isEmpty ||
                    groupRoot == '__single_files__')
                ? null
                : PathMatcher.normalize(groupRoot));
        final showWorkRoot =
            firstTrack?.isSingle != true &&
            (entry.kind == PlaybackQueueEntryKind.work || isAsmrEntry);
        final parent = showWorkRoot
            ? _QueueTreeNode.folder(
                isAsmrEntry
                    ? (firstTrack!.groupTitle.trim().isEmpty
                          ? entry.title
                          : firstTrack.groupTitle)
                    : entryWorkRoot == null
                    ? entry.title
                    : PathDisplay.folderName(entryWorkRoot),
              )
            : root;
        if (!identical(parent, root)) {
          root.children.add(parent);
        }
        for (final track in entry.tracks) {
          final latestTrack = resolvedTracks.putIfAbsent(
            track.path,
            () => _paths.trackByPath(track.path),
          );
          final displayTrack =
              latestTrack != null && latestTrack.duration > Duration.zero
              ? latestTrack
              : track;
          var trackParent = parent;
          if (showWorkRoot) {
            for (final folder in _queueFolderSegments(
              track,
              workRoot: entryWorkRoot,
            )) {
              trackParent = trackParent.folderChild(folder);
            }
          }
          trackParent.children.add(
            _QueueTreeNode.track(
              displayTrack,
              selected: identical(track, selectedTrack),
              queueIndex: queueIndex,
            ),
          );
          queueIndex++;
        }
        if (!identical(parent, root)) {
          parent.sortChildrenNaturally();
        }
      }
      return root.children;
    }
    for (var index = 0; index < tracks.length; index++) {
      final track = tracks[index];
      var parent = root;
      for (final folder in _queueFolderSegments(track, workRoot: workRoot)) {
        parent = parent.folderChild(folder);
      }
      parent.children.add(
        _QueueTreeNode.track(
          track,
          selected: identical(track, selectedTrack),
          queueIndex: index,
        ),
      );
    }
    if (session.customQueueTracks == null ||
        tracks.every((track) => track.isRemoteAsmr)) {
      root.sortChildrenNaturally();
    }
    return root.children;
  }

  List<String> _queueFolderSegments(
    MusicTrack track, {
    required String? workRoot,
  }) {
    final remoteRelativePath = track.remoteMetadata?['trackRelativePath']
        ?.toString()
        .trim();
    final relativePath = remoteRelativePath?.isNotEmpty == true
        ? remoteRelativePath!
        : workRoot == null
        ? PathMatcher.relativeWithin(track.path, track.groupKey)
        : PathMatcher.relativeWithin(track.path, workRoot);
    if (relativePath == null || relativePath.isEmpty) {
      return const <String>[];
    }
    final displayPath = PathDisplay.displayPathFor(relativePath);
    final segments = displayPath
        .replaceAll('\\', '/')
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.length <= 1) return const <String>[];
    return segments.take(segments.length - 1).toList(growable: false);
  }
}

class _QueueSheetHeader extends StatelessWidget {
  const _QueueSheetHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
      child: Row(
        children: [
          Icon(Icons.queue_music_rounded, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              i18n.tr('switch_audio'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
            ),
          ),
          Text(
            count.toString(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueTreeNode {
  _QueueTreeNode.folder(this.title)
    : track = null,
      selected = false,
      queueIndex = -1;

  _QueueTreeNode.track(
    this.track, {
    required this.selected,
    required this.queueIndex,
  }) : title = track!.displayName;

  final String title;
  final MusicTrack? track;
  final bool selected;
  final int queueIndex;
  final List<_QueueTreeNode> children = <_QueueTreeNode>[];

  bool get isFolder => track == null;
  String get stableKey => isFolder ? 'folder:$title' : 'track:${track!.path}';
  bool get containsSelected =>
      selected || children.any((child) => child.containsSelected);

  _QueueTreeNode folderChild(String name) {
    for (final child in children) {
      if (child.isFolder && child.title == name) return child;
    }
    final folder = _QueueTreeNode.folder(name);
    children.add(folder);
    return folder;
  }

  void sortChildrenNaturally() {
    for (final child in children) {
      child.sortChildrenNaturally();
    }
    children.sort(
      (left, right) => compareNaturalTreeEntries(
        leftIsFolder: left.isFolder,
        leftName: left.title,
        leftPath: left.track?.path ?? left.title,
        rightIsFolder: right.isFolder,
        rightName: right.title,
        rightPath: right.track?.path ?? right.title,
      ),
    );
  }
}

class _QueueTreeNodeTile extends StatefulWidget {
  const _QueueTreeNodeTile({
    super.key,
    required this.node,
    required this.onTrackTap,
  });

  final _QueueTreeNode node;
  final ValueChanged<_QueueTreeNode> onTrackTap;

  @override
  State<_QueueTreeNodeTile> createState() => _QueueTreeNodeTileState();
}

class _QueueTreeNodeTileState extends State<_QueueTreeNodeTile> {
  final _controller = ExpansibleController();
  late bool _expanded = widget.node.containsSelected;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _QueueTreeNodeTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.stableKey != widget.node.stableKey ||
        widget.node.containsSelected) {
      _expanded = widget.node.containsSelected;
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    if (!node.isFolder) {
      return _QueueTrackLeaf(
        track: node.track!,
        selected: node.selected,
        onTap: node.selected ? null : () => widget.onTrackTap(node),
      );
    }

    final cs = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        controller: _controller,
        expansionAnimationStyle: appExpansionAnimationStyle(context),
        initiallyExpanded: _expanded,
        minTileHeight: 52,
        onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
        shape: const RoundedRectangleBorder(),
        collapsedShape: const RoundedRectangleBorder(),
        showTrailingIcon: false,
        tilePadding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 0, 0),
        title: Row(
          children: [
            Icon(
              _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
              size: 19,
              color: cs.primary.withValues(alpha: 0.78),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                node.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        trailing: AnimatedRotation(
          turns: _expanded ? 0.5 : 0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: Icon(
            Icons.expand_more_rounded,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
        ),
        children: [
          // ExpansionTile mounts this builder only while its body is visible,
          // including the reverse animation when collapsing.
          Builder(
            builder: (_) => Column(
              children: [
                for (final child in node.children)
                  _QueueTreeNodeTile(
                    key: ValueKey<String>(child.stableKey),
                    node: child,
                    onTrackTap: widget.onTrackTap,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueTrackLeaf extends StatelessWidget {
  const _QueueTrackLeaf({
    required this.track,
    required this.selected,
    required this.onTap,
  });

  final MusicTrack track;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const borderRadius = BorderRadius.all(Radius.circular(12));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Material(
        key: ValueKey<String>('queue_switcher_track_${track.path}'),
        color: selected
            ? cs.primaryContainer.withValues(alpha: 0.24)
            : Colors.transparent,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.volume_up_rounded
                        : Icons.audio_file_rounded,
                    size: 16,
                    color: selected
                        ? cs.primary
                        : cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      track.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Text(
                    track.duration <= Duration.zero
                        ? '--:--'
                        : formatDurationCompact(track.duration),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.chevron_right_rounded,
                    size: 20,
                    color: selected
                        ? cs.primary
                        : cs.onSurfaceVariant.withValues(alpha: 0.55),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
