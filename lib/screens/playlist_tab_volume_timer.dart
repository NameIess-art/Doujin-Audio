part of 'playlist_tab.dart';

class _SessionVolumeSlider extends StatefulWidget {
  const _SessionVolumeSlider({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_SessionVolumeSlider> createState() => _SessionVolumeSliderState();
}

class _SessionVolumeSliderState extends State<_SessionVolumeSlider> {
  double? _dragVolume;

  @override
  void didUpdateWidget(covariant _SessionVolumeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      _dragVolume = null;
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _showVolumeInputDialog() {
    final i18n = context.read<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController(
      text: '${((_dragVolume ?? widget.session.volume) * 100).round()}',
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(i18n.tr('volume')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '0-200',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onSubmitted: (text) {
            _applyVolumeInput(text, ctx, i18n, cs);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(i18n.tr('cancel')),
          ),
          FilledButton(
            onPressed: () {
              _applyVolumeInput(controller.text, ctx, i18n, cs);
            },
            child: Text(i18n.tr('confirm')),
          ),
        ],
      ),
    );
  }

  void _applyVolumeInput(
    String text,
    BuildContext dialogContext,
    AppLanguageProvider i18n,
    ColorScheme cs,
  ) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null || parsed < 0 || parsed > 200) {
      return;
    }
    if (parsed > 120) {
      Navigator.of(dialogContext).pop();
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: cs.error, size: 32),
          title: Text(i18n.tr('volume_warning_title')),
          content: Text(i18n.tr('volume_warning_message')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(i18n.tr('cancel')),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                setState(() => _dragVolume = parsed / 100);
                widget.provider.setSessionVolume(
                  widget.session.id,
                  parsed / 100,
                );
              },
              child: Text(i18n.tr('confirm')),
            ),
          ],
        ),
      );
      return;
    }
    Navigator.of(dialogContext).pop();
    setState(() => _dragVolume = parsed / 100);
    widget.provider.setSessionVolume(widget.session.id, parsed / 100);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final volume = (_dragVolume ?? widget.session.volume).clamp(0.0, 2.0);
    final volumePercent = (volume * 100).round();
    final isBoosted = volume > 1.0;

    return Row(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: Icon(
            volume == 0
                ? Icons.volume_off_rounded
                : volume < 0.45
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
            key: ValueKey<int>((volume * 10).round()),
            size: 20,
            color: isBoosted ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SliderTheme(
            data: Theme.of(context).sliderTheme.copyWith(
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 10,
                elevation: 3,
                pressedElevation: 6,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
              activeTrackColor: isBoosted ? cs.primary : null,
            ),
            child: Slider(
              value: volume,
              min: 0.0,
              max: 2.0,
              onChangeStart: (value) {
                HapticFeedback.selectionClick();
                setState(() {
                  _dragVolume = value;
                });
              },
              onChanged: (value) {
                setState(() {
                  _dragVolume = value;
                });
                widget.provider.setSessionVolume(
                  widget.session.id,
                  value,
                  persist: false,
                );
              },
              onChangeEnd: (value) {
                HapticFeedback.selectionClick();
                setState(() {
                  _dragVolume = null;
                });
                widget.provider.setSessionVolume(widget.session.id, value);
              },
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 140),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.18),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: GestureDetector(
              onTap: _showVolumeInputDialog,
              child: Text(
                '$volumePercent%',
                key: ValueKey<int>(volumePercent),
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: isBoosted ? cs.primary : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                  decorationColor: (isBoosted ? cs.primary : cs.onSurfaceVariant)
                      .withValues(alpha: 0.3),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionVolumeButton extends StatefulWidget {
  const _SessionVolumeButton({
    required this.session,
    required this.provider,
    this.compact = false,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final bool compact;

  @override
  State<_SessionVolumeButton> createState() => _SessionVolumeButtonState();
}

class _SessionVolumeButtonState extends State<_SessionVolumeButton> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  void _toggleVolume() {
    if (_overlay != null) {
      _overlay?.remove();
      _overlay = null;
    } else {
      final overlay = Overlay.of(context);
      _overlay = OverlayEntry(
        builder: (context) => _VerticalVolumeSlider(
          link: _link,
          session: widget.session,
          provider: widget.provider,
          onClose: () {
            _overlay?.remove();
            _overlay = null;
            if (mounted) setState(() {});
          },
        ),
      );
      overlay.insert(_overlay!);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _overlay?.remove();
    _overlay = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final volume = widget.session.volume;
    final icon = volume == 0
        ? Icons.volume_off_rounded
        : volume < 0.45
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;

    final cs = Theme.of(context).colorScheme;
    return CompositedTransformTarget(
      link: _link,
      child: IconButton(
        constraints: BoxConstraints.tightFor(
          width: widget.compact ? 40 : 48,
          height: widget.compact ? 40 : 48,
        ),
        padding: EdgeInsets.zero,
        onPressed: _toggleVolume,
        icon: Icon(icon, size: widget.compact ? 19 : 20, color: cs.onSurface),
      ),
    );
  }
}

class _VerticalVolumeSlider extends StatefulWidget {
  const _VerticalVolumeSlider({
    required this.link,
    required this.session,
    required this.provider,
    required this.onClose,
  });

  final LayerLink link;
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
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController(
      text: '${((_dragVolume ?? widget.session.volume) * 100).round()}',
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(i18n.tr('volume')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '0-200',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onSubmitted: (text) {
            _applyVolumeInput(text, ctx, i18n, cs);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(i18n.tr('cancel')),
          ),
          FilledButton(
            onPressed: () {
              _applyVolumeInput(controller.text, ctx, i18n, cs);
            },
            child: Text(i18n.tr('confirm')),
          ),
        ],
      ),
    );
  }

  void _applyVolumeInput(
    String text,
    BuildContext dialogContext,
    AppLanguageProvider i18n,
    ColorScheme cs,
  ) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null || parsed < 0 || parsed > 200) {
      return;
    }
    if (parsed > 120) {
      Navigator.of(dialogContext).pop();
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: cs.error, size: 32),
          title: Text(i18n.tr('volume_warning_title')),
          content: Text(i18n.tr('volume_warning_message')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(i18n.tr('cancel')),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                widget.onClose();
                setState(() => _dragVolume = parsed / 100);
                widget.provider.setSessionVolume(
                  widget.session.id,
                  parsed / 100,
                );
              },
              child: Text(i18n.tr('confirm')),
            ),
          ],
        ),
      );
      return;
    }
    Navigator.of(dialogContext).pop();
    widget.onClose();
    setState(() => _dragVolume = parsed / 100);
    widget.provider.setSessionVolume(widget.session.id, parsed / 100);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final volume = (_dragVolume ?? widget.session.volume).clamp(0.0, 2.0);
    final isBoosted = volume > 1.0;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          followerAnchor: Alignment.bottomCenter,
          targetAnchor: Alignment.topCenter,
          offset: const Offset(0, -8),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 44,
              height: 220,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.8),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
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
                  const SizedBox(height: 8),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 7,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 10,
                            elevation: 4,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 18,
                          ),
                          activeTrackColor: isBoosted ? cs.primary : null,
                        ),
                        child: Slider(
                          value: volume,
                          min: 0.0,
                          max: 2.0,
                          onChanged: (v) {
                            setState(() => _dragVolume = v);
                            widget.provider.setSessionVolume(
                              widget.session.id,
                              v,
                              persist: false,
                            );
                          },
                          onChangeEnd: (v) {
                            setState(() => _dragVolume = null);
                            widget.provider.setSessionVolume(
                              widget.session.id,
                              v,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TimerCountdownCapsule extends StatelessWidget {
  const _TimerCountdownCapsule({
    required this.remaining,
    required this.active,
    required this.onTap,
  });

  final Duration remaining;
  final bool active;
  final VoidCallback? onTap;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '${h.toString().padLeft(2, '0')}:$m:$s';
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasRemaining = remaining > Duration.zero;

    return Material(
      color: cs.primaryContainer.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          Feedback.forTap(context);
          HapticFeedback.selectionClick();
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
                active
                    ? Icons.timer_rounded
                    : hasRemaining
                    ? Icons.timer_rounded
                    : Icons.alarm_off_rounded,
                size: 14,
                color: cs.onPrimaryContainer,
              ),
              const SizedBox(width: 5),
              Text(
                hasRemaining ? _fmt(remaining) : '00:00',
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
        color: cs.onSurface.withValues(alpha: 0.7),
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
