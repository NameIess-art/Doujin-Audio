import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme/app_design_tokens.dart';
import '../../app/theme/app_styles.dart';
import 'app_glass_surface.dart';
import 'app_transitions.dart';
import 'windows_smooth_scroll_controller.dart';

class AppModalBackground extends StatefulWidget {
  const AppModalBackground({
    super.key,
    required this.animation,
    this.scrimKey,
    this.curve = kAppSpringCurve,
    this.reverseCurve = kAppSpringCurve,
    this.blurReverseCurve = Curves.easeInQuad,
  });

  final Animation<double> animation;
  final Key? scrimKey;
  final Curve curve;
  final Curve reverseCurve;
  final Curve blurReverseCurve;

  @override
  State<AppModalBackground> createState() => _AppModalBackgroundState();
}

class _AppModalBackgroundState extends State<AppModalBackground> {
  static const double _blurSigma = 8.0;
  static const int _blurSteps = 8;
  static final ui.ImageFilter _staticBlurFilter = ui.ImageFilter.blur(
    sigmaX: _blurSigma,
    sigmaY: _blurSigma,
    tileMode: ui.TileMode.clamp,
  );
  // Reuse a single static Gaussian kernel and fade its alpha via composed
  // ColorFilter steps so BackdropFilter stays un-isolated from the page behind
  // it while never recalculating varying blur radii.
  static final _blurFilters = List<ui.ImageFilter>.generate(_blurSteps, (
    index,
  ) {
    if (index == _blurSteps - 1) return _staticBlurFilter;
    final alpha = (index + 1) / _blurSteps;
    return ui.ImageFilter.compose(
      outer: ui.ColorFilter.matrix(<double>[
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, alpha, 0,
      ]),
      inner: _staticBlurFilter,
    );
  }, growable: false);

  CurvedAnimation? _scrimCurved;
  CurvedAnimation? _blurCurved;
  late Animation<double> _scrimAnimation;
  late Animation<double> _blurAnimation;
  bool _blurListenerAttached = false;
  final ValueNotifier<int> _blurStep = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _initAnimations();
  }

  int _computeBlurStep() =>
      (_blurSteps * _blurAnimation.value.clamp(0.0, 1.0)).round();

  void _syncBlurStep() {
    final next = _computeBlurStep();
    if (_blurStep.value != next) {
      _blurStep.value = next;
    }
  }

  void _detachBlurListener() {
    if (!_blurListenerAttached) return;
    _blurAnimation.removeListener(_syncBlurStep);
    _blurListenerAttached = false;
  }

  void _initAnimations() {
    _detachBlurListener();
    _disposeCurvedAnimations();
    _scrimCurved = widget.curve == widget.reverseCurve
        ? null
        : CurvedAnimation(
            parent: widget.animation,
            curve: widget.curve,
            reverseCurve: widget.reverseCurve,
          );
    _scrimAnimation =
        _scrimCurved ??
        widget.animation.drive(CurveTween(curve: widget.curve));

    if (widget.blurReverseCurve == widget.reverseCurve) {
      _blurCurved = null;
      _blurAnimation = _scrimAnimation;
    } else if (widget.curve == widget.blurReverseCurve) {
      _blurCurved = null;
      _blurAnimation = widget.animation.drive(CurveTween(curve: widget.curve));
    } else {
      _blurCurved = CurvedAnimation(
        parent: widget.animation,
        curve: widget.curve,
        reverseCurve: widget.blurReverseCurve,
      );
      _blurAnimation = _blurCurved!;
    }
    _blurAnimation.addListener(_syncBlurStep);
    _blurListenerAttached = true;
    _blurStep.value = _computeBlurStep();
  }

  void _disposeCurvedAnimations() {
    _scrimCurved?.dispose();
    _scrimCurved = null;
    _blurCurved?.dispose();
    _blurCurved = null;
  }

  @override
  void didUpdateWidget(covariant AppModalBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _initAnimations();
      return;
    }
    final curvesChanged =
        oldWidget.curve != widget.curve ||
        oldWidget.reverseCurve != widget.reverseCurve ||
        oldWidget.blurReverseCurve != widget.blurReverseCurve;
    if (!curvesChanged) return;

    // Retain CurvedAnimation's direction if a menu closes before fully opening.
    final canUpdateScrim =
        _scrimCurved != null && widget.curve != widget.reverseCurve;
    final canUpdateBlur =
        widget.blurReverseCurve == widget.reverseCurve
            ? canUpdateScrim
            : (_blurCurved != null && widget.curve != widget.blurReverseCurve);
    if (canUpdateScrim &&
        (widget.blurReverseCurve == widget.reverseCurve || canUpdateBlur)) {
      _scrimCurved!.curve = widget.curve;
      _scrimCurved!.reverseCurve = widget.reverseCurve;
      if (_blurCurved != null) {
        _blurCurved!.curve = widget.curve;
        _blurCurved!.reverseCurve = widget.blurReverseCurve;
      }
      _syncBlurStep();
      return;
    }
    _initAnimations();
  }

  @override
  void dispose() {
    _detachBlurListener();
    _disposeCurvedAnimations();
    _blurStep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: ValueListenableBuilder<int>(
              valueListenable: _blurStep,
              builder: (context, blurStep, _) {
                if (blurStep <= 0) return const SizedBox.shrink();
                return RepaintBoundary(
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: _blurFilters[blurStep - 1],
                      child: const SizedBox.expand(),
                    ),
                  ),
                );
              },
            ),
          ),
          FadeTransition(
            opacity: _scrimAnimation,
            child: ColoredBox(
              key: widget.scrimKey,
              color: kSecondaryOverlayConfig.scrimColor(context, 1.0),
            ),
          ),
        ],
      ),
    );
  }
}

Future<T?> showAppOverlayPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? barrierLabel,
  bool barrierDismissible = true,
  double mobileMaxWidth = 404,
  double desktopMaxWidth = 472,
  double? maxHeight,
  Alignment mobileAlignment = Alignment.topCenter,
  EdgeInsets? mobileOuterPadding,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierLabel:
        barrierLabel ??
        MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.transparent,
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kAppOverlayDuration,
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final mediaSize = MediaQuery.sizeOf(dialogContext);
      final isDesktop =
          mediaSize.width >= 760 ||
          MediaQuery.orientationOf(dialogContext) == Orientation.landscape;
      final outerPadding = isDesktop
          ? const EdgeInsets.all(28)
          : mobileOuterPadding ?? const EdgeInsets.fromLTRB(16, 176, 16, 132);
      return _AppOverlayPanelShell(
        animation: animation,
        outerPadding: outerPadding,
        maxWidth: isDesktop ? desktopMaxWidth : mobileMaxWidth,
        maxHeight: maxHeight,
        isDesktop: isDesktop,
        mobileAlignment: mobileAlignment,
        barrierDismissible: barrierDismissible,
        child: Builder(builder: builder),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}

class _AppOverlayPanelShell extends StatelessWidget {
  const _AppOverlayPanelShell({
    required this.animation,
    required this.outerPadding,
    required this.maxWidth,
    required this.maxHeight,
    required this.isDesktop,
    required this.mobileAlignment,
    required this.barrierDismissible,
    required this.child,
  });

  final Animation<double> animation;
  final EdgeInsets outerPadding;
  final double maxWidth;
  final double? maxHeight;
  final bool isDesktop;
  final Alignment mobileAlignment;
  final bool barrierDismissible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final constraints = maxHeight == null
        ? BoxConstraints(maxWidth: maxWidth)
        : BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight!);
    return Material(
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: barrierDismissible
                  ? () => Navigator.of(context).maybePop()
                  : null,
              child: AppModalBackground(
                animation: animation,
                scrimKey: const ValueKey('app_overlay_panel_scrim'),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: outerPadding,
              child: Align(
                alignment: isDesktop ? Alignment.center : mobileAlignment,
                child: ConstrainedBox(
                  constraints: constraints,
                  child: buildAppScaleFadeTransition(
                    context: context,
                    animation: animation,
                    beginScale: 0.88,
                    curve: kSecondaryOverlayConfig.curve,
                    reverseCurve: kSecondaryOverlayConfig.reverseCurve,
                    // Ink must paint inside the transition so tile backgrounds
                    // and splashes fade and scale with the panel content.
                    child: AppGlassBackdropScope(
                      backdropBlurred: true,
                      child: Material(
                        type: MaterialType.transparency,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  double maxWidth = 420,
  EdgeInsets outerPadding = const EdgeInsets.all(AppSpacing.xl),
  bool captureLocalThemes = true,
}) {
  final navigatorContext = Navigator.of(context, rootNavigator: true).context;
  final capturedThemes = InheritedTheme.capture(
    from: captureLocalThemes ? context : navigatorContext,
    to: navigatorContext,
  );
  return showGeneralDialog<T>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.transparent,
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kSecondaryOverlayConfig.transitionDuration,
    pageBuilder: (_, animation, secondaryAnimation) {
      return capturedThemes.wrap(
        Builder(
          builder: (dialogContext) => Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: barrierDismissible
                      ? () => Navigator.of(dialogContext).maybePop()
                      : null,
                  child: AppModalBackground(
                    animation: animation,
                    scrimKey: const ValueKey('app_dialog_scrim'),
                  ),
                ),
              ),
              AnimatedPadding(
                padding: MediaQuery.viewInsetsOf(dialogContext),
                duration: MediaQuery.disableAnimationsOf(dialogContext)
                    ? Duration.zero
                    : const Duration(milliseconds: 140),
                curve: Curves.decelerate,
                // The host consumes IME insets once, including for Material
                // dialogs that would otherwise apply the same insets again.
                child: MediaQuery.removeViewInsets(
                  context: dialogContext,
                  removeLeft: true,
                  removeTop: true,
                  removeRight: true,
                  removeBottom: true,
                  child: SafeArea(
                    child: Center(
                      child: Padding(
                        padding: outerPadding,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: maxWidth),
                          child: buildAppScaleFadeTransition(
                            context: dialogContext,
                            animation: animation,
                            beginScale: 0.88,
                            curve: kSecondaryOverlayConfig.curve,
                            reverseCurve: kSecondaryOverlayConfig.reverseCurve,
                            child: AppGlassBackdropScope(
                              backdropBlurred: true,
                              child: Material(
                                color: Colors.transparent,
                                child: Builder(builder: builder),
                              ),
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
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}

class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    this.icon,
    this.accentColor,
    this.actions,
    this.scrollable = false,
  });

  final String title;
  final Widget content;
  final IconData? icon;
  final Color? accentColor;
  final Widget? actions;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final resolvedAccentColor = accentColor ?? cs.primary;

    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: title,
      child: Container(
        key: const ValueKey('app_dialog_surface'),
        decoration: BoxDecoration(
          borderRadius: AppRadius.borderDialog,
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.24),
              blurRadius: 38,
              offset: const Offset(0, 22),
            ),
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.08),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: AppGlassSurface(
          enabled: AppDesignTokens.of(context).barGlassEnabled,
          backgroundColor: cs.surfaceContainerHigh,
          borderRadius: AppRadius.borderDialog,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              borderRadius: AppRadius.borderDialog,
              border: Border.all(
                color: theme.brightness == Brightness.dark
                    ? Color.alphaBlend(
                        Colors.white.withValues(alpha: 0.08),
                        cs.outlineVariant,
                      ).withValues(alpha: 0.40)
                    : cs.outlineVariant.withValues(alpha: 0.36),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: resolvedAccentColor.withValues(alpha: 0.12),
                          borderRadius: AppRadius.borderMedium,
                        ),
                        child: Icon(
                          icon,
                          size: AppDesignTokens.opticalIconSize(icon, 24),
                          color: resolvedAccentColor,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                    ],
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(top: icon == null ? 0 : 8),
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Flexible(
                  child: scrollable
                      ? SingleChildScrollView(
                          child: content,
                        ).withWindowsSmoothScroll()
                      : content,
                ),
                if (actions != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  actions!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps Material alert layout while limiting blur to its actual surface.
class AppAlertDialog extends AlertDialog {
  const AppAlertDialog({
    super.key,
    super.title,
    super.content,
    super.actions,
    super.scrollable,
    super.contentPadding,
    super.titlePadding,
    super.actionsPadding,
  });

  @override
  Widget build(BuildContext context) {
    // AlertDialog builds a Dialog with its complete, accessible content layout.
    // Keep its outer inset and Material shadow outside the clipped glass.
    final dialog = super.build(context) as Dialog;
    return _glassMaterialDialog(context, dialog);
  }
}

Widget _glassMaterialDialog(BuildContext context, Dialog dialog) {
  final theme = Theme.of(context);
  final dialogTheme = DialogTheme.of(context);
  final resolvedShape =
      (dialog.shape ??
              dialogTheme.shape ??
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  theme.useMaterial3 ? AppRadius.dialog : 4,
                ),
              ))
          as RoundedRectangleBorder;
  final surfaceColor =
      dialog.backgroundColor ??
      dialogTheme.backgroundColor ??
      (theme.useMaterial3
          ? theme.colorScheme.surfaceContainerHigh
          : theme.brightness == Brightness.dark
          ? Colors.grey[800]!
          : Colors.white);
  return Dialog(
    backgroundColor: Colors.transparent,
    elevation: dialog.elevation,
    shadowColor: dialog.shadowColor,
    surfaceTintColor: Colors.transparent,
    insetAnimationDuration: dialog.insetAnimationDuration,
    insetAnimationCurve: dialog.insetAnimationCurve,
    insetPadding: dialog.insetPadding,
    clipBehavior: dialog.clipBehavior,
    shape: resolvedShape,
    alignment: dialog.alignment,
    constraints: dialog.constraints,
    semanticsRole: dialog.semanticsRole,
    child: AppGlassSurface(
      enabled: AppDesignTokens.of(context).barGlassEnabled,
      backgroundColor: surfaceColor,
      borderRadius: resolvedShape.borderRadius.resolve(
        Directionality.of(context),
      ),
      child: dialog.child!,
    ),
  );
}

class AppDialogActions extends StatelessWidget {
  const AppDialogActions({
    super.key,
    required this.children,
    this.forceVertical = false,
  });

  final List<Widget> children;
  final bool forceVertical;

  @override
  Widget build(BuildContext context) {
    assert(children.isNotEmpty);

    return LayoutBuilder(
      builder: (context, constraints) {
        final stackVertically =
            forceVertical || children.length > 2 || constraints.maxWidth < 260;

        if (stackVertically) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                SizedBox(width: double.infinity, child: children[index]),
                if (index != children.length - 1)
                  const SizedBox(height: AppSpacing.sm),
              ],
            ],
          );
        }

        return Row(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              Expanded(child: children[index]),
              if (index != children.length - 1)
                const SizedBox(width: AppSpacing.md),
            ],
          ],
        );
      },
    );
  }
}
