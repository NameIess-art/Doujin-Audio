part of 'playlist_tab.dart';

class _SessionDetailContent extends StatefulWidget {
  const _SessionDetailContent({
    super.key,
    required this.session,
    required this.provider,
    this.filenameKey,
    this.progressBarKey,
    this.subtitleFontSize = 16,
    this.segmentPanelExpandedNotifier,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final GlobalKey? filenameKey;
  final GlobalKey? progressBarKey;
  final double subtitleFontSize;
  final ValueNotifier<bool>? segmentPanelExpandedNotifier;

  @override
  State<_SessionDetailContent> createState() => _SessionDetailContentState();
}

class _SessionDetailContentState extends State<_SessionDetailContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _playPauseController;
  late final TextEditingController _segmentNameController;
  bool _wasPlaying = false;
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
  bool _syncingSegmentText = false;
  bool _savingSegment = false;
  bool _segmentSaveQueued = false;
  int _segmentDraftGeneration = 0;

  bool get isSegmentPanelExpanded => _segmentPanelExpanded;

  void expandSegmentPanel() {
    if (_segmentPanelExpanded) return;
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
    _wasPlaying = widget.session.state.playing;
    _segmentNameController = TextEditingController();
    _playPauseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: _wasPlaying ? 1.0 : 0.0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSegmentTrack();
    });
    _segmentNameController.addListener(_handleSegmentNameChanged);
  }

  @override
  void didUpdateWidget(covariant _SessionDetailContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSegmentTrack();
  }

  @override
  void dispose() {
    _segmentNameDebounce?.cancel();
    _segmentNameController.removeListener(_handleSegmentNameChanged);
    _segmentNameController.dispose();
    _playPauseController.dispose();
    super.dispose();
  }

  bool _isSingleLoop(SessionLoopMode mode) => mode == SessionLoopMode.single;

  bool _isShuffleLoop(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.folderRandom;
  }

  bool _isCrossFolderLoop(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.crossSequential;
  }

  String _loopModeSummary(BuildContext context, SessionLoopMode mode) {
    final i18n = context.read<AppLanguageProvider>();
    if (_isSingleLoop(mode)) return i18n.tr('single_loop');
    final scope = _isCrossFolderLoop(mode)
        ? i18n.tr('cross_folder')
        : i18n.tr('current_folder');
    final order = _isShuffleLoop(mode)
        ? i18n.tr('random_order')
        : i18n.tr('sequential_order');
    return '$order - $scope';
  }

  void _syncSegmentTrack() {
    final track = widget.provider.trackByPath(widget.session.currentTrackPath);
    final nextKey = track == null
        ? PathMatcher.normalize(widget.session.currentTrackPath)
        : widget.provider.timeSegmentTrackKeyForTrack(track);
    if (nextKey == _segmentTrackKey) return;
    _segmentTrackKey = nextKey;
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
    setState(() {
      _segmentLoading = true;
    });
    final labels = await widget.provider.loadTimeSegmentLabels(trackKey);
    if (!mounted || _segmentTrackKey != trackKey) return;
    final selected = labels
        .where((label) => label.id == _selectedSegmentId)
        .firstOrNull;
    setState(() {
      _segmentLabels = labels;
      _segmentLoading = false;
      if (selected != null) {
        _applySelectedSegment(selected);
      }
    });
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
    setState(() {
      _segmentDraftGeneration++;
      _selectedSegmentId = null;
      _draftStart = null;
      _draftEnd = null;
      _draftColorValue = widget.provider.nextTimeSegmentColor(_segmentLabels);
      _setSegmentNameText('');
      _segmentPanelExpanded = true;
      _segmentEditorVisible = true;
    });
  }

  void _toggleSelectedSegmentLoop() {
    final selected = _selectedSegment;
    if (selected == null) return;
    widget.provider.toggleTimeSegmentLoop(
      sessionId: widget.session.id,
      label: selected,
    );
    setState(() {});
  }

  void _handleSegmentManualSeek(Duration position) {
    widget.provider.handleTimeSegmentManualSeek(widget.session.id, position);
  }

  void _setDraftStartToCurrent() {
    setState(() {
      _draftStart = _clampToDuration(widget.session.position);
      _draftColorValue ??= widget.provider.nextTimeSegmentColor(_segmentLabels);
    });
    unawaited(_trySaveSegmentDraft());
  }

  void _setDraftEndToCurrent() {
    setState(() {
      _draftEnd = _clampToDuration(widget.session.position);
      _draftColorValue ??= widget.provider.nextTimeSegmentColor(_segmentLabels);
    });
    unawaited(_trySaveSegmentDraft());
  }

  Duration _clampToDuration(Duration value) {
    final duration = widget.session.duration;
    if (duration != null && duration > Duration.zero && value >= duration) {
      return duration;
    }
    if (value <= Duration.zero) return Duration.zero;
    return Duration(seconds: value.inSeconds);
  }

  Future<void> _editDraftTime({required bool isStart}) async {
    final current = isStart ? _draftStart : _draftEnd;
    final next = await _showSegmentTimeInputDialog(context, initial: current);
    if (next == null || !mounted) return;
    setState(() {
      if (isStart) {
        _draftStart = _clampToDuration(next);
      } else {
        _draftEnd = _clampToDuration(next);
      }
      _draftColorValue ??= widget.provider.nextTimeSegmentColor(_segmentLabels);
    });
    unawaited(_trySaveSegmentDraft());
  }

  Future<void> _trySaveSegmentDraft() async {
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
    try {
      final existing = _selectedSegmentId == null
          ? null
          : _segmentLabels
                .where((label) => label.id == _selectedSegmentId)
                .firstOrNull;
      final label = widget.provider.buildTimeSegmentLabel(
        trackKey: trackKey,
        name: name,
        start: start,
        end: end,
        colorValue:
            existing?.colorValue ??
            _draftColorValue ??
            widget.provider.nextTimeSegmentColor(_segmentLabels),
        existing: existing,
      );
      await widget.provider.saveTimeSegmentLabel(label);
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
    } finally {
      _savingSegment = false;
      if (_segmentSaveQueued && mounted) {
        _segmentSaveQueued = false;
        unawaited(_trySaveSegmentDraft());
      }
    }
  }

  Future<void> _deleteSelectedSegment() async {
    final selected = _segmentLabels
        .where((label) => label.id == _selectedSegmentId)
        .firstOrNull;
    if (selected == null) return;
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('segment_delete_title'),
      message: i18n.tr('segment_delete_confirm', {'name': selected.name}),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('remove'),
      icon: Icons.sell_rounded,
    );
    if (!confirmed || !mounted) return;
    await widget.provider.deleteTimeSegmentLabel(selected.id);
    if (!mounted) return;
    final trackKey = _segmentTrackKey;
    if (trackKey == null) return;
    setState(_clearSegmentDraft);
    await _loadSegmentLabels(trackKey);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final provider = widget.provider;
    final session = widget.session;

    final isPlaying = session.state.playing;
    if (_wasPlaying != isPlaying) {
      _wasPlaying = isPlaying;
      if (isPlaying) {
        _playPauseController.forward();
      } else {
        _playPauseController.reverse();
      }
    }

    final track = provider.trackByPath(session.currentTrackPath);
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(session.currentTrackPath);
    final i18n = context.read<AppLanguageProvider>();
    final rootFolderName = provider.getRootFolderName(session.currentTrackPath);
    final folderName = rootFolderName.isNotEmpty
        ? rootFolderName
        : (track != null && !track.isSingle && track.groupTitle.isNotEmpty)
        ? track.groupTitle
        : track?.remoteMetadataKind == 'asmr.one'
        ? i18n.tr('asmr_online_playback')
        : i18n.tr('imported_files');
    final hasSiblings =
        provider.tracksInSameGroup(session.currentTrackPath).length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: MarqueeText(
                text: folderName,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.8),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _loopModeSummary(context, session.loopMode),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          key: widget.filenameKey,
          height: 36,
          child: MarqueeText(
            text: displayName,
            pauseDuration: const Duration(seconds: 1),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 8),
        const SizedBox(height: 8),
        SizedBox(height: widget.subtitleFontSize * 3), // scales with font size
        Container(
          key: widget.progressBarKey,
          child: _ProgressBar(
            key: ValueKey(session.id),
            session: session,
            provider: provider,
            timeSegmentLabels: _segmentLabels,
            selectedSegmentId: _segmentPanelExpanded
                ? _selectedSegmentId
                : null,
            onManualSeek: _handleSegmentManualSeek,
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _segmentPanelExpanded
              ? _TimeSegmentPanel(
                  key: const ValueKey('segments'),
                  session: session,
                  provider: provider,
                  labels: _segmentLabels,
                  selectedId: _selectedSegmentId,
                  showEditor: _segmentEditorVisible,
                  loading: _segmentLoading,
                  nameController: _segmentNameController,
                  draftStart: _draftStart,
                  draftEnd: _draftEnd,
                  draftColorValue: _draftColorValue,
                  loopSegmentId: provider.timeSegmentLoopLabelIdForSession(
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
                )
              : _PlaybackControlPanel(
                  key: const ValueKey('controls'),
                  session: session,
                  provider: provider,
                  playPauseController: _playPauseController,
                  isPlaying: isPlaying,
                  hasSiblings: hasSiblings,
                  onShowTrackSwitcher: () => _showTrackSwitcher(context),
                ),
        ),
      ],
    );
  }

  void _showTrackSwitcher(BuildContext context) {
    final i18n = context.read<AppLanguageProvider>();
    final siblings = widget.provider.tracksInSameGroup(
      widget.session.currentTrackPath,
    );
    if (siblings.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.5,
        ),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          cacheExtent: 480,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: siblings.length,
          itemBuilder: (_, i) {
            final track = siblings[i];
            final isCurrent = track.path == widget.session.currentTrackPath;
            return ListTile(
              leading: Icon(
                isCurrent ? Icons.volume_up_rounded : Icons.music_note_rounded,
              ),
              title: Text(track.displayName, maxLines: 2),
              trailing: isCurrent ? const Icon(Icons.check_rounded) : null,
              onTap: () {
                Feedback.forTap(ctx);
                Navigator.of(ctx).pop();
                if (!isCurrent) {
                  widget.provider.switchSessionTrack(
                    widget.session.id,
                    track.path,
                  );
                  showAppSnackBar(
                    context,
                    i18n.tr('switch_audio'),
                    tone: AppFeedbackTone.success,
                    icon: Icons.queue_music_rounded,
                  );
                }
              },
            );
          },
        ),
      ),
    );
  }
}
