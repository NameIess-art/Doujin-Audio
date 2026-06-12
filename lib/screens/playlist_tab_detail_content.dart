part of 'playlist_tab.dart';

class _SessionDetailContent extends StatefulWidget {
  const _SessionDetailContent({
    super.key,
    required this.session,
    required this.provider,
    this.segmentPanelExpandedNotifier,
    this.isLandscape = false,
    this.artworkWidget,
    this.detailPadding = EdgeInsets.zero,
    this.hasSubtitle = false,
    this.subtitleEnabled = true,
    this.subtitleGlobalEnabled = false,
    this.onToggleSubtitle,
    this.onToggleGlobalSubtitle,
    this.onOpenTimer,
    this.onShowAudioDetail,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final ValueNotifier<bool>? segmentPanelExpandedNotifier;
  final bool isLandscape;
  final Widget? artworkWidget;
  final EdgeInsetsGeometry detailPadding;
  final bool hasSubtitle;
  final bool subtitleEnabled;
  final bool subtitleGlobalEnabled;
  final VoidCallback? onToggleSubtitle;
  final VoidCallback? onToggleGlobalSubtitle;
  final VoidCallback? onOpenTimer;
  final VoidCallback? onShowAudioDetail;

  @override
  State<_SessionDetailContent> createState() => _SessionDetailContentState();
}

class _SessionDetailContentState extends State<_SessionDetailContent> {
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
    _segmentNameController.removeListener(_handleSegmentNameChanged);
    _segmentNameController.dispose();
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
        provider.tracksInSameWork(session.currentTrackPath).length > 1;

    final contentColumn = Padding(
      padding: widget.detailPadding,
      child: Column(
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
            height: 42,
            child: MarqueeText(
              text: displayName,
              pauseDuration: const Duration(seconds: 1),
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 8),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: widget.subtitleEnabled && !_segmentPanelExpanded
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _SessionSubtitlePanel(
                      session: session,
                      provider: provider,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          _ProgressBar(
            key: ValueKey(session.id),
            session: session,
            provider: provider,
            timeSegmentLabels: _segmentLabels,
            selectedSegmentId: _segmentPanelExpanded
                ? _selectedSegmentId
                : null,
            onManualSeek: _handleSegmentManualSeek,
          ),
          _PlaybackControlPanel(
            key: ValueKey(
              widget.isLandscape ? 'controls_landscape' : 'controls',
            ),
            session: session,
            provider: provider,
            isPlaying: isPlaying,
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
            onOpenTimer: widget.onOpenTimer,
            onShowAudioDetail: widget.onShowAudioDetail,
          ),
          if (!widget.isLandscape)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _segmentPanelExpanded
                  ? _buildSegmentPanel(
                      provider: provider,
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
                if (widget.artworkWidget != null) widget.artworkWidget!,
                if (_segmentPanelExpanded)
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: _segmentPanelExpanded ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 180),
                      child: ClipRect(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Container(
                            color: cs.surface.withValues(alpha: 0.85),
                            child: SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 16,
                                ),
                                child: _TimeSegmentPanel(
                                  key: const ValueKey('segments_landscape'),
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
                                  loopSegmentId: provider
                                      .timeSegmentLoopLabelIdForSession(
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
                                  onToggleLoop: _toggleSelectedSegmentLoop,
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
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, scrollConstraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: max(0.0, scrollConstraints.maxHeight - 48),
                    ),
                    child: Center(child: contentColumn),
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
        if (widget.artworkWidget != null)
          Expanded(child: widget.artworkWidget!),
        contentColumn,
      ],
    );
  }

  Widget _buildSegmentPanel({
    required AudioProvider provider,
    required PlaybackSession session,
    required Key key,
  }) {
    return _TimeSegmentPanel(
      key: key,
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
    );
  }

  void _showTrackSwitcher(BuildContext context) {
    final i18n = context.read<AppLanguageProvider>();
    final tracks = widget.session.isPlaybackQueue
        ? widget.session.customQueueTracks ?? const <MusicTrack>[]
        : widget.provider.tracksForSessionSwitcher(widget.session.id);
    if (tracks.isEmpty) return;
    final workRoot = widget.provider.workRootForTrack(
      widget.session.currentTrackPath,
    );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final tree = _buildQueueTree(
          tracks,
          workRoot: workRoot,
          currentPath: widget.session.currentTrackPath,
        );
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.58,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 24),
            cacheExtent: 480,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              _QueueSheetHeader(count: tracks.length),
              const SizedBox(height: 6),
              for (final node in tree)
                _QueueTreeNodeTile(
                  node: node,
                  onTrackTap: (node) {
                    AppInteractionFeedback.trigger(
                      AppInteractionFeedbackType.tap,
                      context: ctx,
                    );
                    Navigator.of(ctx).pop();
                    if (widget.session.isPlaybackQueue) {
                      widget.provider.switchSessionQueueTrack(
                        widget.session.id,
                        node.queueIndex,
                      );
                    } else {
                      widget.provider.switchSessionTrack(
                        widget.session.id,
                        node.track!.path,
                      );
                    }
                    showAppSnackBar(
                      context,
                      i18n.tr('switch_audio'),
                      tone: AppFeedbackTone.success,
                      icon: Icons.queue_music_rounded,
                    );
                  },
                ),
            ],
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
    if (widget.session.isPlaybackQueue) {
      var queueIndex = 0;
      for (final entry in widget.session.playbackQueue!.entries) {
        final firstTrack = entry.tracks.firstOrNull;
        final isAsmrEntry = firstTrack?.remoteMetadataKind == 'asmr.one';
        final fallbackRoot = firstTrack == null
            ? null
            : widget.provider.workRootForTrack(firstTrack.path);
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
            entry.kind == PlaybackQueueEntryKind.work || isAsmrEntry;
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
          final latestTrack = widget.provider.trackByPath(track.path);
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
              selected: queueIndex == widget.session.currentQueueIndex,
              queueIndex: queueIndex,
            ),
          );
          queueIndex++;
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
          selected: PathMatcher.equalsNormalized(track.path, currentPath),
          queueIndex: index,
        ),
      );
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
    final i18n = context.read<AppLanguageProvider>();
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
}

class _QueueTreeNodeTile extends StatefulWidget {
  const _QueueTreeNodeTile({required this.node, required this.onTrackTap});

  final _QueueTreeNode node;
  final ValueChanged<_QueueTreeNode> onTrackTap;

  @override
  State<_QueueTreeNodeTile> createState() => _QueueTreeNodeTileState();
}

class _QueueTreeNodeTileState extends State<_QueueTreeNodeTile> {
  late bool _expanded = widget.node.containsSelected;

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
            _QueueTreeNodeTile(node: child, onTrackTap: widget.onTrackTap),
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
    return Material(
      color: selected
          ? cs.primaryContainer.withValues(alpha: 0.24)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.volume_up_rounded : Icons.audio_file_rounded,
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
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
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
    );
  }
}
