part of 'playlist_tab.dart';

class _ExpandableLoopOptions extends StatefulWidget {
  const _ExpandableLoopOptions({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_ExpandableLoopOptions> createState() => _ExpandableLoopOptionsState();
}

class _ExpandableLoopOptionsState extends State<_ExpandableLoopOptions>
    with SingleTickerProviderStateMixin {
  final LayerLink _anchorLink = LayerLink();
  OverlayEntry? _overlayEntry;
  late final AnimationController _expandController;

  bool get _expanded => _overlayEntry != null;

  bool _isCross(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.crossSequential;
  }

  bool _isShuffle(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.folderRandom;
  }

  SessionLoopMode get _effectiveNonSingleMode {
    if (widget.session.loopMode == SessionLoopMode.single) {
      return widget.session.nonSingleLoopMode;
    }
    return widget.session.loopMode;
  }

  bool get _singleActive => widget.session.loopMode == SessionLoopMode.single;
  bool get _shuffleActive => _isShuffle(_effectiveNonSingleMode);
  bool get _crossFolderActive => _isCross(_effectiveNonSingleMode);

  bool get _shuffleButtonHighlighted => !_singleActive;
  bool get _scopeButtonHighlighted => !_singleActive;

  IconData get _orderIcon =>
      _shuffleActive ? Icons.shuffle_rounded : Icons.repeat_rounded;
  IconData get _scopeIcon =>
      _crossFolderActive ? Icons.folder_copy_rounded : Icons.folder_rounded;

  Widget _collapsedCompositeIcon(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: ValueKey<String>(
        'composite_${_orderIcon.codePoint}_${_scopeIcon.codePoint}',
      ),
      width: 20,
      height: 20,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0.28,
              child: Icon(_scopeIcon, size: 20, color: cs.onSurfaceVariant),
            ),
          ),
          Center(child: Icon(_orderIcon, size: 13, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 260),
    );
  }

  Future<void> _toggleExpanded() async {
    if (_expanded) {
      await _hideOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(builder: _buildOverlay);
    overlay.insert(_overlayEntry!);
    _expandController.forward(from: 0);
    setState(() {});
  }

  Future<void> _hideOverlay() async {
    if (_overlayEntry == null) return;
    await _expandController.reverse();
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _refreshImmediately(Future<void> future) async {
    _overlayEntry?.markNeedsBuild();
    if (mounted) {
      setState(() {});
    }
    await future;
    _overlayEntry?.markNeedsBuild();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _toggleSingleLoop() async {
    await _refreshImmediately(
      widget.provider.toggleSessionSingleLoop(widget.session.id),
    );
  }

  Future<void> _toggleShuffleLoop() async {
    final current = widget.session.loopMode == SessionLoopMode.single
        ? widget.session.nonSingleLoopMode
        : widget.session.loopMode;
    final isCrossFolder = _isCross(current);
    final isShuffle = _isShuffle(current);
    final nextMode = isShuffle
        ? (isCrossFolder
              ? SessionLoopMode.crossSequential
              : SessionLoopMode.folderSequential)
        : (isCrossFolder
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.folderRandom);
    await _refreshImmediately(
      widget.provider.setSessionLoopMode(widget.session.id, nextMode),
    );
  }

  Future<void> _toggleCrossFolderLoop() async {
    final current = widget.session.loopMode == SessionLoopMode.single
        ? widget.session.nonSingleLoopMode
        : widget.session.loopMode;
    final isCrossFolder = _isCross(current);
    final isShuffle = _isShuffle(current);
    final nextMode = isCrossFolder
        ? (isShuffle
              ? SessionLoopMode.folderRandom
              : SessionLoopMode.folderSequential)
        : (isShuffle
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.crossSequential);
    await _refreshImmediately(
      widget.provider.setSessionLoopMode(widget.session.id, nextMode),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              _hideOverlay();
            },
          ),
        ),
        CompositedTransformFollower(
          link: _anchorLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.center,
          followerAnchor: Alignment.bottomCenter,
          // The capsule bottom sits slightly below the button center so the
          // bottom action button stays locked to the collapsed position.
          offset: const Offset(0, 26),
          child: Material(
            color: Colors.transparent,
            child: AnimatedBuilder(
              animation: _expandController,
              builder: (context, _) {
                final containerProgress = Curves.easeOutCubic
                    .transform(_expandController.value)
                    .clamp(0.0, 1.0);

                Widget animatedBubble({
                  required IconData icon,
                  required bool active,
                  required VoidCallback onPressed,
                  required double start,
                  required double end,
                }) {
                  final progress = Interval(
                    start,
                    end,
                    curve: Curves.easeOutCubic,
                  ).transform(_expandController.value).clamp(0.0, 1.0);
                  return Opacity(
                    opacity: progress,
                    child: Transform.translate(
                      offset: Offset(0, (1 - progress) * 18),
                      child: Transform.scale(
                        scale: 0.82 + (progress * 0.18),
                        child: _LoopModeButton(
                          icon: icon,
                          active: active,
                          onPressed: onPressed,
                        ),
                      ),
                    ),
                  );
                }

                return Opacity(
                  opacity: 0.4 + (containerProgress * 0.6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh.withValues(
                            alpha: 0.38,
                          ),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: cs.outlineVariant.withValues(alpha: 0.92),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: cs.shadow.withValues(alpha: 0.18),
                              blurRadius: 16,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 4,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              animatedBubble(
                                icon: Icons.repeat_one_rounded,
                                active: _singleActive,
                                onPressed: _toggleSingleLoop,
                                start: 0.16,
                                end: 0.58,
                              ),
                              const SizedBox(height: 4),
                              animatedBubble(
                                icon: _orderIcon,
                                active: _shuffleButtonHighlighted,
                                onPressed: _toggleShuffleLoop,
                                start: 0.28,
                                end: 0.74,
                              ),
                              const SizedBox(height: 4),
                              animatedBubble(
                                icon: _scopeIcon,
                                active: _scopeButtonHighlighted,
                                onPressed: _toggleCrossFolderLoop,
                                start: 0.4,
                                end: 0.9,
                              ),
                              const SizedBox(height: 4),
                              _LoopModeButton(
                                iconWidget: _singleActive
                                    ? Icon(
                                        Icons.repeat_one_rounded,
                                        key: const ValueKey<String>(
                                          'single_main',
                                        ),
                                        size: 18,
                                        color: cs.primary,
                                      )
                                    : _collapsedCompositeIcon(context),
                                active: true,
                                onPressed: _toggleExpanded,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _expandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _anchorLink,
      child: SizedBox(
        width: 44,
        height: 82,
        child: IgnorePointer(
          ignoring: _expanded,
          child: Visibility(
            visible: !_expanded,
            maintainAnimation: true,
            maintainState: true,
            child: Align(
              child: _LoopModeButton(
                iconWidget: _singleActive
                    ? Icon(
                        Icons.repeat_one_rounded,
                        key: const ValueKey<String>('single_main_collapsed'),
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : _collapsedCompositeIcon(context),
                active: true,
                onPressed: _toggleExpanded,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
