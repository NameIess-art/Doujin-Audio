part of 'main_screen.dart';

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.surface,
            cs.surfaceContainer.withValues(alpha: 0.94),
            cs.surfaceContainerLow,
          ],
          stops: const [0, 0.5, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: -96,
            top: -64,
            child: _GlowOrb(
              color: cs.primary.withValues(alpha: 0.08),
              size: 220,
            ),
          ),
          Positioned(
            right: -72,
            bottom: -86,
            child: _GlowOrb(
              color: cs.tertiary.withValues(alpha: 0.07),
              size: 196,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0.0)],
          ),
        ),
      ),
    );
  }
}

class _DesktopQuickAction extends StatelessWidget {
  const _DesktopQuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: cs.surfaceContainerHigh.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Feedback.forTap(context);
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: cs.onSecondaryContainer, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _MainDestination {
  const _MainDestination({
    required this.icon,
    required this.selectedIcon,
    required this.labelKey,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String labelKey;
}

class _TimerPresentation {
  const _TimerPresentation({
    required this.duration,
    required this.remaining,
    required this.active,
    required this.mode,
  });

  final Duration? duration;
  final Duration? remaining;
  final bool active;
  final TimerMode? mode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _TimerPresentation &&
        other.duration == duration &&
        other.remaining == remaining &&
        other.active == active &&
        other.mode == mode;
  }

  @override
  int get hashCode => Object.hash(duration, remaining, active, mode);
}

class _FloatingGlassPanel extends StatelessWidget {
  const _FloatingGlassPanel({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderOpacity = 0.42,
    this.shadowOpacity = 0.22,
    this.showTopHighlight = true,
    this.primaryFillOpacity = 0.22,
    this.secondaryFillOpacity = 0.10,
  });

  final Widget child;
  final double radius = 100;
  final EdgeInsetsGeometry padding;
  final double borderOpacity;
  final double shadowOpacity;
  final bool showTopHighlight;
  final double primaryFillOpacity;
  final double secondaryFillOpacity;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillAlpha = isDark ? 0.72 : 0.85;
    final bgColor = isDark ? cs.surfaceBright : cs.surfaceContainerHighest;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            color: bgColor.withValues(
              alpha: (primaryFillOpacity * fillAlpha).clamp(0.0, 0.95),
            ),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: borderOpacity),
            ),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: shadowOpacity),
                blurRadius: 34,
                spreadRadius: -6,
                offset: const Offset(0, 18),
              ),
              BoxShadow(
                color: cs.primary.withValues(alpha: isDark ? 0.08 : 0.05),
                blurRadius: 18,
                spreadRadius: -10,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Stack(
            children: [
              if (showTopHighlight)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: 0.12),
                            Colors.white.withValues(alpha: 0),
                          ],
                          stops: const [0, 0.24],
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimerOverlaySheet extends StatelessWidget {
  const _TimerOverlaySheet({
    required this.isDesktop,
    required this.animation,
    required this.openDetail,
  });

  final bool isDesktop;
  final Animation<double> animation;
  final bool openDetail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxWidth = isDesktop ? 472.0 : 404.0;
    final outerPadding = EdgeInsets.fromLTRB(
      isDesktop ? 28 : 16,
      isDesktop ? 28 : 176,
      isDesktop ? 28 : 16,
      isDesktop ? 28 : 132,
    );
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) {
          final progress = curved.value.clamp(0.0, 1.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).maybePop(),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.scrim.withValues(
                        alpha: 0.08 + (0.14 * progress),
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: FadeTransition(
                  opacity: curved,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.035),
                      end: Offset.zero,
                    ).animate(curved),
                    child: Padding(
                      padding: outerPadding,
                      child: Align(
                        alignment: isDesktop
                            ? Alignment.center
                            : Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: maxWidth),
                          child: TimerTab(
                            showHeader: false,
                            useSafeArea: false,
                            compactOnly: true,
                            initialCompactDetail: openDetail,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
