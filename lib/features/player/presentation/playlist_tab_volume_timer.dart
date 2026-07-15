part of 'playlist_tab.dart';

const double _maxSessionVolume = 2.0;
const int _maxSessionVolumePercent = 200;

class _SessionVolumeButton extends StatefulWidget {
  const _SessionVolumeButton({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_SessionVolumeButton> createState() => _SessionVolumeButtonState();
}

class _SessionVolumeButtonState extends State<_SessionVolumeButton>
    with SingleTickerProviderStateMixin {
  final LayerLink _anchorLink = LayerLink();
  OverlayEntry? _overlayEntry;
  late final AnimationController _expandController;

  bool get _expanded => _overlayEntry != null;

  @override
  void initState() {
    super.initState();
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 240),
    );
  }

  Future<void> _toggleVolume() async {
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
    if (mounted) setState(() {});
  }

  IconData _getIconForVolume(double volume) {
    return volume == 0
        ? Icons.volume_off_rounded
        : volume < 0.45
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
  }

  Widget _buildOverlay(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _hideOverlay,
          ),
        ),
        CompositedTransformFollower(
          link: _anchorLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.center,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, 24),
          child: Material(
            color: Colors.transparent,
            child: AnimatedBuilder(
              animation: _expandController,
              builder: (context, _) {
                final progress = Curves.easeOutCubic
                    .transform(_expandController.value)
                    .clamp(0.0, 1.0);

                return Transform.scale(
                  alignment: Alignment.bottomCenter,
                  scale: 0.85 + (progress * 0.15),
                  child: Opacity(
                    opacity: progress,
                    child: _VerticalVolumeSlider(
                      session: widget.session,
                      provider: widget.provider,
                      onClose: _hideOverlay,
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
    final volume = widget.session.volume;
    final icon = _getIconForVolume(volume);
    final cs = Theme.of(context).colorScheme;

    return CompositedTransformTarget(
      link: _anchorLink,
      child: SizedBox(
        key: const ValueKey('session_volume_button_anchor'),
        width: 48,
        height: 48,
        child: IgnorePointer(
          ignoring: _expanded,
          child: Visibility(
            visible: !_expanded,
            maintainAnimation: true,
            maintainState: true,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: context.read<AppLanguageProvider>().tr('volume'),
              onPressed: () {
                AppInteractionFeedback.trigger(
                  AppInteractionFeedbackType.selection,
                );
                _toggleVolume();
              },
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, animation) {
                  return ScaleTransition(
                    scale: Tween<double>(begin: 0.4, end: 1.0).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutBack,
                      ),
                    ),
                    child: FadeTransition(opacity: animation, child: child),
                  );
                },
                child: Icon(
                  icon,
                  key: ValueKey(icon),
                  size: 20,
                  color: cs.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VerticalVolumeSlider extends StatefulWidget {
  const _VerticalVolumeSlider({
    required this.session,
    required this.provider,
    required this.onClose,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final VoidCallback onClose;

  @override
  State<_VerticalVolumeSlider> createState() => _VerticalVolumeSliderState();
}

class _VerticalVolumeSliderState extends State<_VerticalVolumeSlider> {
  double? _dragVolume;

  void _showVolumeInputDialog() {
    final i18n = context.read<AppLanguageProvider>();
    final controller = TextEditingController(
      text: '${((_dragVolume ?? widget.session.volume) * 100).round()}',
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(i18n.tr('volume')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: i18n.tr('volume_range_hint'),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onSubmitted: (text) {
            _applyVolumeInput(text, ctx);
          },
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(i18n.tr('cancel')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    _applyVolumeInput(controller.text, ctx);
                  },
                  child: Text(i18n.tr('confirm')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _applyVolumeInput(String text, BuildContext dialogContext) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null || parsed < 0 || parsed > _maxSessionVolumePercent) {
      return;
    }
    Navigator.of(dialogContext).pop();
    widget.onClose();
    setState(() => _dragVolume = parsed / 100);
    widget.provider.playbackFacade.setSessionVolume(
      widget.session.id,
      parsed / 100,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final volume = (_dragVolume ?? widget.session.volume).clamp(
      0.0,
      _maxSessionVolume,
    );
    final isBoosted = volume > 1.0;

    return ClipRRect(
      key: const ValueKey('session_volume_capsule'),
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: _sessionDetailCapsuleWidth,
          height: _sessionDetailCapsuleHeight,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh.withValues(alpha: 0.38),
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
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
          child: Column(
            children: [
              GestureDetector(
                onTap: _showVolumeInputDialog,
                child: Text(
                  '${(volume * 100).round()}%',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    fontSize: 10,
                    color: isBoosted ? cs.primary : null,
                    decoration: TextDecoration.underline,
                    decorationColor: (isBoosted ? cs.primary : cs.onSurface)
                        .withValues(alpha: 0.3),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return OverflowBox(
                      minHeight: constraints.maxHeight + 48,
                      maxHeight: constraints.maxHeight + 48,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 7,
                            thumbShape: const RoundSliderThumbShape(),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 18,
                            ),
                            activeTrackColor: isBoosted ? cs.primary : null,
                          ),
                          child: Slider(
                            value: volume,
                            max: _maxSessionVolume,
                            onChanged: (v) {
                              setState(() => _dragVolume = v);
                              AppInteractionFeedback.continuous(
                                (v * 100).round(),
                              );
                              UiInteractionCoordinator.instance
                                  .scheduleThrottledCommit(
                                    key: 'session_volume:${widget.session.id}',
                                    commit: () => widget.provider.playbackFacade
                                        .setSessionVolume(
                                          widget.session.id,
                                          v,
                                          persist: false,
                                        ),
                                  );
                            },
                            onChangeEnd: (v) {
                              setState(() => _dragVolume = null);
                              AppInteractionFeedback.resetContinuous();
                              UiInteractionCoordinator.instance
                                  .cancelThrottledCommit(
                                    'session_volume:${widget.session.id}',
                                  );
                              widget.provider.playbackFacade.setSessionVolume(
                                widget.session.id,
                                v,
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 2),
              IconButton(
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                padding: EdgeInsets.zero,
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  widget.onClose();
                },
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, animation) {
                    return ScaleTransition(
                      scale: Tween<double>(begin: 0.4, end: 1.0).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutBack,
                        ),
                      ),
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  child: Icon(
                    volume == 0
                        ? Icons.volume_off_rounded
                        : volume < 0.45
                        ? Icons.volume_down_rounded
                        : Icons.volume_up_rounded,
                    key: ValueKey(
                      volume == 0
                          ? Icons.volume_off_rounded
                          : volume < 0.45
                          ? Icons.volume_down_rounded
                          : Icons.volume_up_rounded,
                    ),
                    size: 20,
                    color: cs.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimerCountdownCapsule extends StatelessWidget {
  const _TimerCountdownCapsule({
    required this.remaining,
    required this.active,
    required this.autoResumeAt,
    required this.onTap,
  });

  final Duration remaining;
  final bool active;
  final DateTime? autoResumeAt;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // When auto-resume is pending, show the auto-resume countdown instead.
    final showAutoResume = autoResumeAt != null;

    return TargetCountdownBuilder(
      target: autoResumeAt,
      builder: (context, autoResumeRemaining) {
        final displayDuration = showAutoResume
            ? autoResumeRemaining
            : remaining;
        final hasRemaining = displayDuration > Duration.zero;

        return Material(
          color: cs.primaryContainer.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () {
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.selection,
              );
              onTap?.call();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    showAutoResume
                        ? Icons.alarm_rounded
                        : active
                        ? Icons.timer_rounded
                        : hasRemaining
                        ? Icons.timer_rounded
                        : Icons.alarm_off_rounded,
                    size: 14,
                    color: cs.onPrimaryContainer,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    hasRemaining
                        ? formatDurationCompact(displayDuration)
                        : '00:00',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimecodeLabel extends StatelessWidget {
  const _TimecodeLabel({required this.text, this.alignEnd = false});

  final String text;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Text(
      text,
      textAlign: alignEnd ? TextAlign.end : TextAlign.start,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: cs.onSurface.withValues(alpha: 0.8),
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        fontSize: 13,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
