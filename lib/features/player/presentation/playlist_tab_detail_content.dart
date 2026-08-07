part of 'playlist_tab.dart';

class _SessionDetailContent extends ConsumerStatefulWidget {
  const _SessionDetailContent({
    super.key,
    required this.session,
    this.deferSubtitleLoad = false,
    required this.artworkWidget,
    this.segmentPanelExpandedNotifier,
    this.isLandscape = false,
    this.detailPadding = EdgeInsets.zero,
    this.hasSubtitle = false,
    this.subtitleEnabled = true,
    this.subtitleGlobalEnabled = false,
    this.onToggleSubtitle,
    this.onToggleGlobalSubtitle,
    this.onShowAudioDetail,
  });

  final PlaybackSession session;
  final bool deferSubtitleLoad;
  final Widget artworkWidget;
  final ValueNotifier<bool>? segmentPanelExpandedNotifier;
  final bool isLandscape;
  final EdgeInsetsGeometry detailPadding;
  final bool hasSubtitle;
  final bool subtitleEnabled;
  final bool subtitleGlobalEnabled;
  final VoidCallback? onToggleSubtitle;
  final VoidCallback? onToggleGlobalSubtitle;
  final VoidCallback? onShowAudioDetail;

  @override
  ConsumerState<_SessionDetailContent> createState() =>
      _SessionDetailContentState();
}

class _SessionDetailContentState extends ConsumerState<_SessionDetailContent> {
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
  Timer? _segmentLoadTimer;
  bool _segmentLabelsLoaded = false;
  bool _syncingSegmentText = false;
  bool _savingSegment = false;
  bool _segmentSaveQueued = false;
  int _segmentDraftGeneration = 0;

  PlaybackFacade get _playback => ref.read(playbackFacadeProvider);
  AudioPathCoordinator get _paths => ref.read(audioPathCoordinatorProvider);
  PlaybackTimeSegmentService get _timeSegments =>
      ref.read(playbackTimeSegmentServiceProvider);

  bool get isSegmentPanelExpanded => _segmentPanelExpanded;

  void expandSegmentPanel() {
    if (_segmentPanelExpanded) return;
    final trackKey = _segmentTrackKey;
    if (trackKey != null && !_segmentLabelsLoaded && !_segmentLoading) {
      _segmentLoadTimer?.cancel();
      _segmentLoadTimer = null;
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
    _segmentNameController = TextEditingController();
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
    _segmentLoadTimer?.cancel();
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
    _segmentLoadTimer?.cancel();
    _segmentLoadTimer = Timer(const Duration(milliseconds: 220), () {
      _segmentLoadTimer = null;
      if (!mounted || _segmentTrackKey != nextKey) return;
      unawaited(_loadSegmentLabels(nextKey));
    });
  }

  Future<void> _loadSegmentLabels(String trackKey) async {
    setState(() {
      _segmentLoading = true;
    });
    final labels = await _timeSegments.loadLabels(trackKey);
    if (!mounted || _segmentTrackKey != trackKey) return;
    final selected = labels
        .where((label) => label.id == _selectedSegmentId)
        .firstOrNull;
    setState(() {
      _segmentLabels = labels;
      _segmentLabelsLoaded = true;
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
      _draftColorValue = _timeSegments.nextColor(_segmentLabels);
      _setSegmentNameText('');
      _segmentPanelExpanded = true;
      _segmentEditorVisible = true;
    });
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
      _draftStart = _clampToDuration(widget.session.position);
      _draftColorValue ??= _timeSegments.nextColor(_segmentLabels);
    });
    unawaited(_trySaveSegmentDraft());
  }

  void _setDraftEndToCurrent() {
    setState(() {
      _draftEnd = _clampToDuration(widget.session.position);
      _draftColorValue ??= _timeSegments.nextColor(_segmentLabels);
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
      _draftColorValue ??= _timeSegments.nextColor(_segmentLabels);
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
      await _timeSegments.saveLabel(label);
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
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('segment_delete_title'),
      message: i18n.tr('segment_delete_confirm', {'name': selected.name}),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('segment_delete_title'),
      icon: Icons.sell_rounded,
    );
    if (!confirmed || !mounted) return;
    await _timeSegments.deleteLabel(selected.id);
    if (!mounted) return;
    final trackKey = _segmentTrackKey;
    if (trackKey == null) return;
    setState(_clearSegmentDraft);
    await _loadSegmentLabels(trackKey);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = widget.session;
    final playback = _playback;
    final paths = _paths;
    final timeSegments = _timeSegments;

    final isPlaying = session.effectivePlaying;
    if (_wasPlaying != isPlaying) {
      _wasPlaying = isPlaying;
    }

    final track = paths.trackByPath(session.currentTrackPath);
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(session.currentTrackPath);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final rootFolderName = paths.rootFolderName(session.currentTrackPath);
    final folderName = rootFolderName.isNotEmpty
        ? rootFolderName
        : (track != null && !track.isSingle && track.groupTitle.isNotEmpty)
        ? track.groupTitle
        : track?.remoteMetadataKind == 'asmr.one'
        ? i18n.tr('asmr_online_playback')
        : i18n.tr('imported_files');
    final hasSiblings = session.isPlaybackQueue
        ? session.playbackQueue!.expandedTracks.isNotEmpty
        : paths.tracksInSameWork(session.currentTrackPath).length > 1;
    final selectedSegmentId = _segmentPanelExpanded ? _selectedSegmentId : null;

    Widget buildProgressBar() {
      return _ProgressBar(
        key: ValueKey('progress_${session.id}'),
        session: session,
        playback: playback,
        paths: paths,
        timeSegmentLabels: _segmentLabels,
        selectedSegmentId: selectedSegmentId,
        onManualSeek: _handleSegmentManualSeek,
      );
    }

    Widget buildTransportControls() {
      return _TransportPlaybackControlPanel(
        key: ValueKey(widget.isLandscape ? 'controls_landscape' : 'controls'),
        session: session,
        playback: playback,
        paths: paths,
        hasSiblings: hasSiblings,
        segmentPanelExpanded: _segmentPanelExpanded,
        hasSubtitle: widget.hasSubtitle,
        subtitleEnabled: widget.subtitleEnabled,
        subtitleGlobalEnabled: widget.subtitleGlobalEnabled,
        onShowTrackSwitcher: () => _showTrackSwitcher(context),
        onToggleSegments: _segmentPanelExpanded
            ? collapseSegmentPanel
            : expandSegmentPanel,
        onToggleSubtitle: widget.onToggleSubtitle,
        onToggleGlobalSubtitle: widget.onToggleGlobalSubtitle,
        onShowAudioDetail: widget.onShowAudioDetail,
      );
    }

    final contentColumn = Padding(
      padding: widget.detailPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarqueeText(
            text: folderName,
            allowAndroidMarquee: true,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: _sessionDetailForeground(
                cs,
                _SessionDetailForegroundLevel.medium,
                darkFallback: cs.onSurface.withValues(alpha: 0.8),
              ),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: MarqueeText(
              text: displayName,
              pauseDuration: const Duration(seconds: 1),
              allowAndroidMarquee: true,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: _sessionDetailForeground(
                  cs,
                  _SessionDetailForegroundLevel.strong,
                ),
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (widget.subtitleEnabled && !_segmentPanelExpanded)
            RepaintBoundary(
              child: _SessionSubtitlePanel(
                session: session,
                deferLoad: widget.deferSubtitleLoad,
              ),
            ),
          RepaintBoundary(child: buildProgressBar()),
          buildTransportControls(),
          if (!widget.isLandscape)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.0, 0.2),
                    end: Offset.zero,
                  ).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: _segmentPanelExpanded
                  ? _buildSegmentPanel(
                      playback: playback,
                      session: session,
                      key: const ValueKey('segments'),
                    )
                  : const SizedBox.shrink(key: ValueKey('segments_closed')),
            ),
        ],
      ),
    );

    if (widget.isLandscape) {
      return Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                widget.artworkWidget,
                Positioned.fill(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      return SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.0, 0.2),
                          end: Offset.zero,
                        ).animate(animation),
                        child: FadeTransition(opacity: animation, child: child),
                      );
                    },
                    child: _segmentPanelExpanded
                        ? SizedBox.expand(
                            key: const ValueKey('segments_landscape_container'),
                            child: ClipRRect(
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(16),
                                topRight: Radius.circular(16),
                                bottomRight: Radius.circular(16),
                              ),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 16,
                                  sigmaY: 16,
                                ),
                                child: Container(
                                  color: cs.surface.withValues(alpha: 0.85),
                                  child: SafeArea(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 16,
                                      ),
                                      child: _TimeSegmentPanel(
                                        key: const ValueKey(
                                          'segments_landscape',
                                        ),
                                        session: session,
                                        playback: playback,
                                        labels: _segmentLabels,
                                        selectedId: _selectedSegmentId,
                                        showEditor: _segmentEditorVisible,
                                        loading: _segmentLoading,
                                        nameController: _segmentNameController,
                                        draftStart: _draftStart,
                                        draftEnd: _draftEnd,
                                        draftColorValue: _draftColorValue,
                                        loopSegmentId: timeSegments
                                            .loopLabelIdForSession(
                                              session.id,
                                              trackKey: _segmentTrackKey,
                                            ),
                                        onSelect: _selectSegment,
                                        onAdd: _startNewSegment,
                                        onSetStart: _setDraftStartToCurrent,
                                        onSetEnd: _setDraftEndToCurrent,
                                        onEditStart: () =>
                                            _editDraftTime(isStart: true),
                                        onEditEnd: () =>
                                            _editDraftTime(isStart: false),
                                        onDelete: _deleteSelectedSegment,
                                        onToggleLoop:
                                            _toggleSelectedSegmentLoop,
                                        onClose: collapseSegmentPanel,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('segments_landscape_closed'),
                          ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, scrollConstraints) {
                return ScrollActivityGate(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: max(0.0, scrollConstraints.maxHeight - 48),
                      ),
                      child: Center(child: contentColumn),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Expanded(child: widget.artworkWidget),
        contentColumn,
      ],
    );
  }

  Widget _buildSegmentPanel({
    required PlaybackFacade playback,
    required PlaybackSession session,
    required Key key,
  }) {
    return _TimeSegmentPanel(
      key: key,
      session: session,
      playback: playback,
      labels: _segmentLabels,
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
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final tracks = orderTracksForSessionSwitcher(
      widget.session.isPlaybackQueue
          ? widget.session.playbackQueue!.expandedTracks
          : _paths.tracksForSessionSwitcher(widget.session.id),
      preserveQueueOrder: widget.session.isPlaybackQueue,
    );
    if (tracks.isEmpty) return;
    final workRoot = _paths.workRootForTrack(widget.session.currentTrackPath);
    final tree = _buildQueueTree(
      tracks,
      workRoot: workRoot,
      currentPath: widget.session.currentTrackPath,
    );
    AppBottomSheet.show<void>(
      context: context,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 320),
        reverseDuration: Duration(milliseconds: 250),
        curve: Curves.fastOutSlowIn,
        reverseCurve: Curves.fastOutSlowIn,
      ),
      builder: (ctx) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.58,
          ),
          child: ListView.builder(
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
                  unawaited(() async {
                    unawaited(
                      AppInteractionFeedback.trigger(
                        AppInteractionFeedbackType.tap,
                        context: ctx,
                      ),
                    );
                    Navigator.of(ctx).pop();
                    await Future<void>.delayed(
                      const Duration(milliseconds: 200),
                    );
                    if (!context.mounted) return;
                    if (widget.session.isPlaybackQueue) {
                      await _playback.switchSessionQueueTrack(
                        widget.session.id,
                        selectedNode.queueIndex,
                      );
                    } else {
                      await _playback.switchSessionTrack(
                        widget.session.id,
                        selectedNode.track!.path,
                      );
                    }
                    if (context.mounted) {
                      showAppSnackBar(
                        context,
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
    required String? workRoot,
    required String currentPath,
  }) {
    final root = _QueueTreeNode.folder('');
    final queueTracks = widget.session.isPlaybackQueue
        ? widget.session.playbackQueue!.expandedTracks
        : widget.session.customQueueTracks;
    final selectedTrack = resolveSessionSwitcherSelectedTrack(
      displayedTracks: tracks,
      queueTracks: queueTracks,
      currentPath: currentPath,
      currentQueueIndex: widget.session.currentQueueIndex,
    );
    if (widget.session.isPlaybackQueue) {
      var queueIndex = 0;
      for (final entry in widget.session.playbackQueue!.entries) {
        final firstTrack = entry.tracks.firstOrNull;
        final isAsmrEntry = firstTrack?.remoteMetadataKind == 'asmr.one';
        final fallbackRoot = firstTrack == null
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
          final latestTrack = _paths.trackByPath(track.path);
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
    if (widget.session.customQueueTracks == null ||
        tracks.every((track) => track.remoteMetadataKind == 'asmr.one')) {
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
          for (final child in node.children)
            _QueueTreeNodeTile(
              key: ValueKey<String>(child.stableKey),
              node: child,
              onTrackTap: widget.onTrackTap,
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
                        : _formatSegmentTime(track.duration),
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
