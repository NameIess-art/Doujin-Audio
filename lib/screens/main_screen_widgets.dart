part of 'main_screen.dart';

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground({this.tinyMode = false});

  final bool tinyMode;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (tinyMode) {
      return DecoratedBox(decoration: BoxDecoration(color: cs.surface));
    }
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(
            top: BorderSide(color: cs.primary.withValues(alpha: 0.045)),
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

class _GlobalUpdateOperationBanner extends ConsumerWidget {
  const _GlobalUpdateOperationBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operation = ref.watch(
      uiOperationForScopeProvider(UiOperationScope.settingsUpdate),
    );
    final isDownloadOperation = operation.labelKey == 'downloading_update';
    if (!isDownloadOperation || (!operation.isBusy && !operation.hasError)) {
      return const SizedBox.shrink();
    }

    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final top =
        (Platform.isWindows ? 40.0 : MediaQuery.paddingOf(context).top) + 8;
    final hasError = operation.hasError;
    final progress = operation.progress;
    final percent = progress == null ? '--' : '${(progress * 100).round()}';
    final message = hasError
        ? i18n.tr('update_download_failed_next_step')
        : i18n.tr('downloading_update', {'percent': percent});
    final detail = operation.error?.toString().trim();
    final label = hasError && detail != null && detail.isNotEmpty
        ? '$message $detail'
        : message;

    return Positioned(
      top: top,
      left: 12,
      right: 12,
      child: IgnorePointer(
        ignoring: !hasError,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Material(
              color: Colors.transparent,
              child: AppFeedbackSurface(
                tone: hasError
                    ? AppFeedbackTone.destructive
                    : AppFeedbackTone.info,
                icon: hasError
                    ? Icons.error_outline_rounded
                    : Icons.download_rounded,
                title: hasError
                    ? i18n.tr('update_download_failed')
                    : i18n.tr('download_update'),
                message: label,
                trailing: hasError && Platform.isWindows
                    ? IconButton(
                        tooltip: i18n.tr('open_update_log'),
                        color: cs.error,
                        onPressed: () =>
                            unawaited(AppUpdateService.openWindowsUpdateLog()),
                        icon: const Icon(Icons.article_outlined),
                      )
                    : SizedBox(
                        width: 72,
                        child: LinearProgressIndicator(value: progress),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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

class _FloatingGlassPanel extends ConsumerWidget {
  const _FloatingGlassPanel({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.shadowOpacity = 0.22,
    this.showTopHighlight = true,
    this.tinyMode = false,
  });

  final Widget child;
  final double radius = 100;
  final EdgeInsetsGeometry padding;
  final double shadowOpacity;
  final bool showTopHighlight;
  final bool tinyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceBright : cs.surfaceContainerHigh;
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (s) => s.valueOrNull?.uiBlurEffectEnabled ?? true,
      ),
    );

    Widget buildPanel(bool useBlur) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: bgColor.withValues(
          alpha: useBlur ? (isDark ? 0.80 : 0.86) : 1.0,
        ),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
        ),
        boxShadow: tinyMode
            ? null
            : [
                BoxShadow(
                  color: cs.shadow.withValues(alpha: shadowOpacity * 0.68),
                  blurRadius: 28,
                  spreadRadius: -6,
                  offset: const Offset(0, 14),
                ),
                BoxShadow(
                  color: cs.primary.withValues(alpha: isDark ? 0.05 : 0.035),
                  blurRadius: 14,
                  spreadRadius: -10,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: Stack(
        children: [
          if (showTopHighlight && !tinyMode)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: isDark ? 0.18 : 0.45),
                        Colors.white.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.15],
                    ),
                  ),
                ),
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );

    final useBlur = blurEnabled;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: useBlur
          ? BackdropFilter(
              key: const ValueKey('floating_glass_panel_blur'),
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: buildPanel(useBlur),
            )
          : buildPanel(useBlur),
    );
  }
}

class _ScrollToTopButton extends StatelessWidget {
  const _ScrollToTopButton({required this.visible, required this.onPressed});

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Positioned(
      right: 28,
      bottom: 28,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          key: const ValueKey('main_scroll_to_top_opacity'),
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: visible ? 1 : 0.92,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                key: const ValueKey('main_scroll_to_top_blur'),
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: SizedBox.square(
                  dimension: 56,
                  child: IconButton(
                    key: const ValueKey('main_scroll_to_top_button'),
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    color: cs.primary,
                    iconSize: 28,
                    tooltip: 'Back to top',
                    style: const ButtonStyle(
                      backgroundColor: WidgetStatePropertyAll(
                        Colors.transparent,
                      ),
                      overlayColor: WidgetStatePropertyAll(Colors.transparent),
                    ),
                    onPressed: onPressed,
                  ),
                ),
              ),
            ),
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
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).maybePop(),
                  child: const SizedBox.expand(),
                ),
              ),
              SafeArea(
                child: FadeTransition(
                  opacity: curved,
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
            ],
          );
        },
      ),
    );
  }
}

class _BootstrapOverlay extends StatefulWidget {
  const _BootstrapOverlay({
    required this.visible,
    required this.onAnimationEnd,
  });

  final bool visible;
  final VoidCallback onAnimationEnd;

  @override
  State<_BootstrapOverlay> createState() => _BootstrapOverlayState();
}

class _BootstrapOverlayState extends State<_BootstrapOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _textOpacity;
  late final Animation<Offset> _textSlide;
  late final Animation<double> _opacity;
  late final Animation<double> _blur;
  bool _disableAnimations = false;
  bool _completionScheduled = false;

  @override
  void initState() {
    super.initState();
    // Total duration 1600ms: 0.8s entrance (0.0->0.5) + 0.8s exit (0.5->1.0)
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    _logoScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.4,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 35, // 0.0 - 0.35
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 15,
      ), // 0.35 - 0.50
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.85,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 50, // 0.50 - 1.0
      ),
    ]).animate(_controller);

    _logoOpacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 25, // 0.0 - 0.25
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 25,
      ), // 0.25 - 0.50
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 50, // 0.50 - 1.0
      ),
    ]).animate(_controller);

    _textOpacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: ConstantTween<double>(0.0),
        weight: 15,
      ), // Wait 0.0 - 0.15
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 25, // 0.15 - 0.40
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 10,
      ), // 0.40 - 0.50
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 50, // 0.50 - 1.0
      ),
    ]).animate(_controller);

    _textSlide = TweenSequence<Offset>([
      TweenSequenceItem(
        tween: ConstantTween<Offset>(const Offset(0, 0.4)),
        weight: 15,
      ),
      TweenSequenceItem(
        tween: Tween<Offset>(
          begin: const Offset(0, 0.4),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 25,
      ),
      TweenSequenceItem(tween: ConstantTween<Offset>(Offset.zero), weight: 60),
    ]).animate(_controller);

    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 50),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 50, // Fade during shrink
      ),
    ]).animate(_controller);

    _blur = TweenSequence<double>([
      TweenSequenceItem(
        tween: ConstantTween<double>(0.0),
        weight: 50,
      ), // No blur during grow
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.0,
          end: 25.0,
        ).chain(CurveTween(curve: Curves.easeInQuint)),
        weight: 50, // Blur during shrink
      ),
    ]).animate(_controller);

    _controller.animateTo(0.5).then((_) {
      if (mounted && !widget.visible) {
        _controller.animateTo(1.0).then((_) {
          if (mounted) widget.onAnimationEnd();
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_disableAnimations == disableAnimations) return;
    _disableAnimations = disableAnimations;
    if (_disableAnimations) {
      _controller
        ..stop()
        ..value = widget.visible ? 0.5 : 1.0;
      _scheduleReducedMotionCompletion();
    }
  }

  @override
  void didUpdateWidget(covariant _BootstrapOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_disableAnimations) {
      if (widget.visible) {
        _completionScheduled = false;
        _controller.value = 0.5;
      } else {
        _controller.value = 1.0;
        _scheduleReducedMotionCompletion();
      }
      return;
    }
    if (oldWidget.visible && !widget.visible) {
      if (_controller.value >= 0.5 && !_controller.isAnimating) {
        _controller.animateTo(1.0).then((_) {
          if (mounted) widget.onAnimationEnd();
        });
      }
    }
  }

  void _scheduleReducedMotionCompletion() {
    if (widget.visible || _completionScheduled) return;
    _completionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.visible) widget.onAnimationEnd();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        if (progress >= 1.0) return const SizedBox.shrink();

        return Stack(
          children: [
            // Background - Solid layer first to prevent flicker
            Positioned.fill(
              child: Opacity(
                opacity: _opacity.value.clamp(0.0, 1.0),
                child: Container(
                  color: cs.surface,
                  child: Stack(
                    children: [
                      const Positioned.fill(child: _AmbientBackground()),
                      // Blur applies to the ambient background
                      Positioned.fill(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(
                            sigmaX: _blur.value,
                            sigmaY: _blur.value,
                          ),
                          child: const SizedBox.shrink(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Logo
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: _logoOpacity.value.clamp(0.0, 1.0),
                    child: ScaleTransition(
                      scale: _logoScale,
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: cs.primary.withValues(alpha: 0.3),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              cs.primary,
                              cs.primary.withValues(alpha: 0.8),
                            ],
                          ),
                        ),
                        child: const Icon(
                          Icons.graphic_eq_rounded,
                          color: Colors.white,
                          size: 52,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SlideTransition(
                    position: _textSlide,
                    child: Opacity(
                      opacity: _textOpacity.value.clamp(0.0, 1.0),
                      child: Text(
                        'Nameless Audio',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                              color: cs.onSurface,
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
