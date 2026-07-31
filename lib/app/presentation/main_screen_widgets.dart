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

class _BottomDestinationInkResponse extends StatelessWidget {
  const _BottomDestinationInkResponse({
    required this.inkKey,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.onHorizontalSwipe,
  });

  final Key inkKey;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onHorizontalSwipe;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final inkResponse = InkResponse(
      key: inkKey,
      onTap: onTap,
      containedInkWell: true,
      radius: 32,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      child: child,
    );
    if (onLongPress == null && onHorizontalSwipe == null) return inkResponse;
    var horizontalDragDistance = 0.0;
    return RawGestureDetector(
      key: const ValueKey<String>('main_destination_library_long_press'),
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        if (onLongPress != null)
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: const Duration(seconds: 1),
                ),
                (recognizer) => recognizer.onLongPress = onLongPress,
              ),
        if (onHorizontalSwipe != null)
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(HorizontalDragGestureRecognizer.new, (recognizer) {
                recognizer.onStart = (_) {
                  horizontalDragDistance = 0;
                };
                recognizer.onUpdate = (details) {
                  horizontalDragDistance += details.primaryDelta ?? 0;
                };
                recognizer.onEnd = (_) {
                  if (horizontalDragDistance.abs() >= 24) {
                    onHorizontalSwipe?.call();
                  }
                };
              }),
      },
      child: inkResponse,
    );
  }
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

    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final top = MediaQuery.paddingOf(context).top + 8;
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
                trailing: SizedBox(
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
      settingsStateProvider.select((s) => s.value?.uiBlurEffectEnabled ?? true),
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
