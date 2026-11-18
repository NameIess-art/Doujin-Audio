import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../ui/ui_interaction_coordinator.dart';
import '../../app/theme/app_design_tokens.dart';
import 'app_entry_ink_well.dart';
import 'app_feedback.dart';
import 'app_glass_surface.dart';
import 'app_transitions.dart';
import 'mobile_overlay_inset.dart';
import 'windows_smooth_scroll_controller.dart';

const _menuEnterDuration = Duration(milliseconds: 200);
const _menuExitDuration = Duration(milliseconds: 160);
const _compactMenuEdgeExtension = 6.0;

class _AnchoredMenuScale extends SingleChildRenderObjectWidget {
  const _AnchoredMenuScale({
    required this.scale,
    required this.anchorInMenu,
    required super.child,
  });

  final Animation<double> scale;
  final Offset Function(Size) anchorInMenu;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAnchoredMenuScale(scale, anchorInMenu);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAnchoredMenuScale renderObject,
  ) {
    renderObject.update(scale, anchorInMenu);
  }
}

class _RenderAnchoredMenuScale extends RenderTransform {
  _RenderAnchoredMenuScale(this._scale, this._anchorInMenu)
    : super(transform: Matrix4.identity());

  Animation<double> _scale;
  Offset Function(Size) _anchorInMenu;

  void update(Animation<double> scale, Offset Function(Size) anchorInMenu) {
    if (scale != _scale) {
      if (attached) _scale.removeListener(_updateTransform);
      _scale = scale;
      if (attached) _scale.addListener(_updateTransform);
    }
    _anchorInMenu = anchorInMenu;
    if (hasSize) _updateTransform();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scale.addListener(_updateTransform);
  }

  @override
  void detach() {
    _scale.removeListener(_updateTransform);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    _updateTransform();
  }

  void _updateTransform() {
    if (!hasSize) return;
    final anchor = _anchorInMenu(size);
    origin = Offset(
      anchor.dx.clamp(0, size.width),
      anchor.dy.clamp(0, size.height),
    );
    final value = _scale.value;
    transform = Matrix4.diagonal3Values(value, value, 1);
  }
}

TextAlign _menuTextAlign(
  BuildContext context,
  RenderBox overlay,
  Offset anchor,
) {
  final page = readAppRoute(context)?.subtreeContext?.findRenderObject();
  final pageCenter = page is RenderBox && page.hasSize
      ? page.localToGlobal(Offset(page.size.width / 2, 0)).dx
      : overlay.localToGlobal(Offset(overlay.size.width / 2, 0)).dx;
  return overlay.localToGlobal(anchor).dx > pageCenter
      ? TextAlign.right
      : TextAlign.left;
}

class UnifiedMenuEntry<T> {
  const UnifiedMenuEntry.action({
    required this.value,
    this.icon,
    this.iconWidget,
    required this.label,
    this.trailing,
    this.trailingValue,
    this.destructive = false,
    this.enabled = true,
  }) : divider = false;

  const UnifiedMenuEntry.divider()
    : value = null,
      icon = null,
      iconWidget = null,
      label = '',
      trailing = null,
      trailingValue = null,
      destructive = false,
      enabled = false,
      divider = true;

  final T? value;
  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final Widget? trailing;
  final T? trailingValue;
  final bool destructive;
  final bool enabled;
  final bool divider;
}

class UnifiedPopupMenuButton<T> extends StatefulWidget {
  const UnifiedPopupMenuButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.entries,
    required this.onSelected,
    this.onTrailingSelected,
    this.iconSize = 28,
    this.menuWidth = 236,
    this.enabled = true,
    this.selectAfterDismiss = true,
    this.padding,
    this.constraints,
  });

  final IconData icon;
  final String tooltip;
  final List<UnifiedMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final ValueChanged<T>? onTrailingSelected;
  final double iconSize;
  final double menuWidth;
  final bool enabled;
  final bool selectAfterDismiss;
  final EdgeInsetsGeometry? padding;
  final BoxConstraints? constraints;

  @override
  State<UnifiedPopupMenuButton<T>> createState() =>
      _UnifiedPopupMenuButtonState<T>();
}

class _UnifiedPopupMenuButtonState<T> extends State<UnifiedPopupMenuButton<T>>
    with SingleTickerProviderStateMixin {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;
  Future<void>? _closing;
  late final AnimationController _controller;
  final Object _interactionSource = Object();
  ValueNotifier<VoidCallback?>? _menuDismiss;
  VoidCallback? _dismissCallback;
  VoidCallback? _stopTrackingHover;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _menuEnterDuration,
      reverseDuration: _menuExitDuration,
    )..addStatusListener(_handleAnimationStatus);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    final interaction = UiInteractionCoordinator.instance;
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      interaction.beginInteraction(_interactionSource);
    } else {
      interaction.endInteraction(_interactionSource);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entry == null) return;
    if (!TickerMode.valuesOf(context).enabled) {
      unawaited(_removeOverlay(immediate: true));
    } else if (MediaQuery.disableAnimationsOf(context)) {
      if (_closing != null) {
        unawaited(_removeOverlay(immediate: true));
      } else {
        UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
        // Its transitions live in a separate overlay subtree, which cannot
        // rebuild while the launching button updates dependencies.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _entry != null && _closing == null) {
            _controller.value = 1;
          }
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant UnifiedPopupMenuButton<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) unawaited(_removeOverlay(immediate: true));
  }

  @override
  void dispose() {
    _removeOverlay(immediate: true);
    UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!widget.enabled || !TickerMode.valuesOf(context).enabled) return;
    if (_entry != null) {
      await _removeOverlay();
      return;
    }
    _showOverlay();
  }

  void _showOverlay() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        MobileOverlayInset.menuOverlayOf(context) ??
        Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;

    final anchorOffset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final anchorRect = anchorOffset & box.size;
    final textAlign = _menuTextAlign(context, overlayBox, anchorRect.center);
    final screenWidth = overlayBox.size.width;
    final availableWidth = (screenWidth - 20).clamp(0.0, double.infinity);
    final menuWidth = widget.menuWidth.clamp(0.0, availableWidth).toDouble();
    if (menuWidth == 0) return;
    final left = (anchorRect.right - menuWidth)
        .clamp(10.0, screenWidth - menuWidth - 10.0)
        .toDouble();
    final top = anchorRect.top
        .clamp(8.0, math.max(8.0, overlayBox.size.height - 8.0))
        .toDouble();

    var hoverEnabled = false;
    final entry = OverlayEntry(
      builder: (overlayContext) {
        return _UnifiedPopupOverlay<T>(
          animation: _controller,
          rect: Rect.fromLTWH(left, top, menuWidth, anchorRect.height),
          anchor: anchorRect.center,
          entries: widget.entries,
          textAlign: textAlign,
          hoverEnabled: hoverEnabled,
          onDismiss: _removeOverlay,
          onSelected: (value) async {
            if (_closing != null) return;
            if (widget.selectAfterDismiss) {
              await _removeOverlay();
              if (mounted) widget.onSelected(value);
              return;
            }
            unawaited(_removeOverlay());
            if (mounted) widget.onSelected(value);
          },
          onTrailingSelected: (value) async {
            if (_closing != null) return;
            await _removeOverlay();
            if (mounted) widget.onTrailingSelected?.call(value);
          },
        );
      },
    );
    _entry = entry;
    _stopTrackingHover = _enableMenuHoverOnMovement(() {
      hoverEnabled = true;
      entry.markNeedsBuild();
    });
    UiInteractionCoordinator.instance.beginInteraction(_interactionSource);
    _menuDismiss = MobileOverlayInset.menuDismissOf(context);
    _menuDismiss?.value?.call();
    _dismissCallback = () => unawaited(_removeOverlay());
    _menuDismiss?.value = _dismissCallback;
    overlay.insert(entry);
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller.value = 1;
      UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
    } else {
      _controller.forward(from: 0);
    }
  }

  Future<void> _removeOverlay({bool immediate = false}) {
    final entry = _entry;
    if (entry == null) return Future.value();
    final reduceMotion =
        !immediate && (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    if (immediate || reduceMotion) {
      _controller.stop();
      _closing = null;
      _detachOverlay(entry);
      UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
      return Future.value();
    }
    return _closing ??= _animateRemoval(entry);
  }

  Future<void> _animateRemoval(OverlayEntry entry) async {
    try {
      await _controller.reverse().orCancel;
    } on TickerCanceled {
      // Unmounting also removes the entry while reverse is in progress.
    } finally {
      if (identical(_entry, entry)) {
        _detachOverlay(entry);
        _closing = null;
      }
    }
  }

  void _detachOverlay(OverlayEntry entry) {
    if (!identical(_entry, entry)) return;
    _stopTrackingHover?.call();
    _stopTrackingHover = null;
    if (identical(_menuDismiss?.value, _dismissCallback)) {
      _menuDismiss?.value = null;
    }
    _menuDismiss = null;
    _dismissCallback = null;
    _entry = null;
    entry.remove();
    entry.dispose();
    UiInteractionCoordinator.instance.endInteraction(_interactionSource);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: IconButton(
        key: _anchorKey,
        tooltip: widget.tooltip,
        onPressed: widget.enabled ? _toggle : null,
        icon: Icon(widget.icon, size: widget.iconSize),
        padding: widget.padding,
        constraints: widget.constraints,
      ),
    );
  }
}

class _UnifiedPopupOverlay<T> extends StatefulWidget {
  const _UnifiedPopupOverlay({
    required this.animation,
    required this.rect,
    required this.anchor,
    required this.entries,
    required this.textAlign,
    required this.hoverEnabled,
    required this.onDismiss,
    required this.onSelected,
    this.onTrailingSelected,
  });

  final Animation<double> animation;
  final Rect rect;
  final Offset anchor;
  final List<UnifiedMenuEntry<T>> entries;
  final TextAlign textAlign;
  final bool hoverEnabled;
  final Future<void> Function() onDismiss;
  final ValueChanged<T> onSelected;
  final ValueChanged<T>? onTrailingSelected;

  @override
  State<_UnifiedPopupOverlay<T>> createState() =>
      _UnifiedPopupOverlayState<T>();
}

class _UnifiedPopupOverlayState<T> extends State<_UnifiedPopupOverlay<T>> {
  final _focusScope = FocusScopeNode();
  late CurvedAnimation _curved;
  late CurvedAnimation _scaleCurved;
  late Animation<double> _scale;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _bindAnimation();
    widget.animation.addStatusListener(_handleAnimationStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.animation.status == AnimationStatus.reverse) return;
      _focusScope.requestFocus();
    });
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (mounted) setState(() {});
  }

  void _bindAnimation() {
    _curved = CurvedAnimation(
      parent: widget.animation,
      curve: kAppSpringCurve,
      reverseCurve: Curves.easeInCubic,
    );
    _scaleCurved = CurvedAnimation(
      parent: widget.animation,
      curve: const Cubic(0.2, 0.92, 0.25, 1.032),
      reverseCurve: Curves.easeInCubic,
    );
    _scale = Tween<double>(begin: 0.88, end: 1).animate(_scaleCurved);
    final dy = widget.anchor.dy <= widget.rect.center.dy ? -0.025 : 0.025;
    _slide = Tween<Offset>(
      begin: Offset(0, dy),
      end: Offset.zero,
    ).animate(_curved);
  }

  @override
  void didUpdateWidget(covariant _UnifiedPopupOverlay<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_handleAnimationStatus);
      _curved.dispose();
      _scaleCurved.dispose();
      _bindAnimation();
      widget.animation.addStatusListener(_handleAnimationStatus);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_handleAnimationStatus);
    _curved.dispose();
    _scaleCurved.dispose();
    _focusScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
      },
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        child: FocusScope(
          node: _focusScope,
          child: Material(
            color: Colors.transparent,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onDismiss,
                    child: FadeTransition(
                      opacity: _curved,
                      child: ColoredBox(
                        color: theme.colorScheme.scrim.withValues(
                          alpha: isDark ? 0.16 : 0.06,
                        ),
                      ),
                    ),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final size = constraints.biggest;
                    final layout = _PopupMenuPositionDelegate(
                      left: widget.rect.left,
                      preferredTop: widget.rect.top,
                      menuWidth: widget.rect.width,
                    );
                    return CustomSingleChildLayout(
                      delegate: layout,
                      // Keep the fade's hit bounds inside the animated transforms.
                      child: SlideTransition(
                        position: _slide,
                        child: _AnchoredMenuScale(
                          anchorInMenu: (menuSize) =>
                              widget.anchor -
                              layout.getPositionForChild(size, menuSize),
                          scale: _scale,
                          child: FadeTransition(
                            opacity: _curved,
                            child: ExcludeFocus(
                              excluding:
                                  widget.animation.status ==
                                  AnimationStatus.reverse,
                              child: ExcludeSemantics(
                                excluding:
                                    widget.animation.status ==
                                    AnimationStatus.reverse,
                                child: IgnorePointer(
                                  ignoring:
                                      widget.animation.status ==
                                      AnimationStatus.reverse,
                                  child: SingleChildScrollView(
                                    child: _UnifiedPopupMenuCard<T>(
                                      entries: widget.entries,
                                      textAlign: widget.textAlign,
                                      suppressHover: !widget.hoverEnabled,
                                      onSelected: widget.onSelected,
                                      onTrailingSelected:
                                          widget.onTrailingSelected,
                                    ),
                                  ).withWindowsSmoothScroll(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PopupMenuPositionDelegate extends SingleChildLayoutDelegate {
  const _PopupMenuPositionDelegate({
    required this.left,
    required this.preferredTop,
    required this.menuWidth,
  });

  final double left;
  final double preferredTop;
  final double menuWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxWidth = math.min(
      menuWidth,
      math.max(0.0, constraints.maxWidth - 20.0),
    );
    final maxHeight = math.max(0.0, constraints.maxHeight - 16.0);
    return BoxConstraints(
      minWidth: maxWidth,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = math.max(10.0, size.width - childSize.width - 10.0);
    final resolvedLeft = left.clamp(10.0, maxLeft);
    final maxTop = math.max(8.0, size.height - childSize.height - 8.0);
    final resolvedTop = preferredTop.clamp(8.0, maxTop);
    return Offset(resolvedLeft, resolvedTop);
  }

  @override
  bool shouldRelayout(covariant _PopupMenuPositionDelegate oldDelegate) {
    return left != oldDelegate.left ||
        preferredTop != oldDelegate.preferredTop ||
        menuWidth != oldDelegate.menuWidth;
  }
}

class _UnifiedPopupMenuCard<T> extends StatelessWidget {
  const _UnifiedPopupMenuCard({
    required this.entries,
    required this.textAlign,
    required this.onSelected,
    this.onTrailingSelected,
    this.compact = false,
    this.primaryIcons = false,
    this.suppressHover = false,
  });

  final bool compact;
  final bool primaryIcons;
  final bool suppressHover;
  final List<UnifiedMenuEntry<T>> entries;
  final TextAlign textAlign;
  final ValueChanged<T> onSelected;
  final ValueChanged<T>? onTrailingSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tokens = AppDesignTokens.of(context);
    final background = isDark ? cs.surfaceBright : cs.surfaceContainerHighest;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(tokens.radiusSection),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: isDark ? 0.34 : 0.14),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: cs.shadow.withValues(alpha: isDark ? 0.18 : 0.06),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: AppGlassSurface(
        enabled: tokens.barGlassEnabled,
        blurSigma: 10,
        backgroundColor: background,
        borderRadius: BorderRadius.circular(tokens.radiusSection),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(tokens.radiusSection),
            border: Border.all(
              color: cs.outlineVariant.withValues(
                alpha: tokens.standardBorderAlpha,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < entries.length; index++)
                _UnifiedPopupMenuRow<T>(
                  entry: entries[index],
                  textAlign: textAlign,
                  compact: compact,
                  primaryIcons: primaryIcons,
                  suppressHover: suppressHover,
                  edgePadding: EdgeInsets.only(
                    top: compact && index == 0 ? _compactMenuEdgeExtension : 0,
                    bottom: compact && index == entries.length - 1
                        ? _compactMenuEdgeExtension
                        : 0,
                  ),
                  onSelected: onSelected,
                  onTrailingSelected: onTrailingSelected,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnifiedPopupMenuRow<T> extends StatelessWidget {
  const _UnifiedPopupMenuRow({
    required this.entry,
    required this.textAlign,
    required this.suppressHover,
    required this.edgePadding,
    required this.onSelected,
    this.onTrailingSelected,
    this.compact = false,
    this.primaryIcons = false,
  });

  final bool compact;
  final bool primaryIcons;
  final UnifiedMenuEntry<T> entry;
  final TextAlign textAlign;
  final bool suppressHover;
  final EdgeInsets edgePadding;
  final ValueChanged<T> onSelected;
  final ValueChanged<T>? onTrailingSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (entry.divider) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Divider(
          height: 1,
          thickness: 1,
          color: cs.outlineVariant.withValues(alpha: 0.56),
        ),
      );
    }

    final value = entry.value;
    return Material(
      color: Colors.transparent,
      child: AppEntryInkWell(
        hoverColor: suppressHover ? Colors.transparent : null,
        // InkHighlight locks its alpha tween on creation, so changing
        // borderRadius when hover unlocks recreates any invisible highlight.
        borderRadius: suppressHover ? BorderRadius.zero : null,
        onTap: entry.enabled && value != null
            ? () {
                AppInteractionFeedback.trigger(
                  entry.destructive
                      ? AppInteractionFeedbackType.destructive
                      : AppInteractionFeedbackType.selection,
                );
                onSelected(value);
              }
            : null,
        child: Padding(
          padding: edgePadding,
          child: _UnifiedPopupMenuContent(
            entry: entry,
            textAlign: textAlign,
            compact: compact,
            primaryIcons: primaryIcons,
            onTrailingSelected: onTrailingSelected,
          ),
        ),
      ),
    );
  }
}

class _UnifiedPopupMenuContent<T> extends StatelessWidget {
  const _UnifiedPopupMenuContent({
    required this.entry,
    required this.textAlign,
    required this.compact,
    required this.primaryIcons,
    this.onTrailingSelected,
  });

  final UnifiedMenuEntry<T> entry;
  final TextAlign textAlign;
  final bool compact;
  final bool primaryIcons;
  final ValueChanged<T>? onTrailingSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final foreground = entry.destructive ? cs.error : cs.onSurface;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: compact ? 40 : 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            if (entry.icon != null || entry.iconWidget != null) ...[
              IconTheme(
                data: IconThemeData(
                  size: compact ? 18 : 21,
                  color: primaryIcons && !entry.destructive
                      ? cs.primary
                      : foreground,
                ),
                child: entry.iconWidget ?? Icon(entry.icon),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                entry.label,
                textAlign: entry.trailingValue == null
                    ? textAlign
                    : TextAlign.left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: entry.enabled
                      ? foreground
                      : cs.onSurface.withValues(alpha: 0.38),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (entry.trailing != null) ...[
              const SizedBox(width: 10),
              if (entry.trailingValue != null && onTrailingSelected != null)
                IconButton(
                  constraints: const BoxConstraints.tightFor(
                    width: 38,
                    height: 38,
                  ),
                  padding: EdgeInsets.zero,
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).deleteButtonTooltip,
                  onPressed: () {
                    AppInteractionFeedback.trigger(
                      AppInteractionFeedbackType.confirmation,
                    );
                    onTrailingSelected!(entry.trailingValue as T);
                  },
                  icon: entry.trailing!,
                )
              else
                entry.trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _DockMenuLayout extends SingleChildLayoutDelegate {
  _DockMenuLayout(this.position);
  final RelativeRect position;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(
      Size(
        (constraints.maxWidth - 16).clamp(0.0, double.infinity),
        (constraints.maxHeight - 16).clamp(0.0, double.infinity),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Right-align to button right edge.
    double x = size.width - position.right - childSize.width;
    if (x + childSize.width > size.width - 8) {
      x = size.width - 8 - childSize.width;
    }
    if (x < 8) x = 8;

    // Keep the first row's content aligned to the original anchor.
    double y = position.top - _compactMenuEdgeExtension;
    if (y + childSize.height > size.height - 8) {
      y = size.height - 8 - childSize.height;
    }
    if (y < 8) y = 8;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_DockMenuLayout oldDelegate) =>
      position != oldDelegate.position;
}

VoidCallback _enableMenuHoverOnMovement(VoidCallback onMovement) {
  final router = GestureBinding.instance.pointerRouter;
  var tracking = true;

  void handleMovement(PointerEvent event) {
    final isMouseDrag =
        event is PointerMoveEvent && event.kind == PointerDeviceKind.mouse;
    if (event.delta == Offset.zero ||
        (event is! PointerHoverEvent && !isMouseDrag)) {
      return;
    }
    tracking = false;
    router.removeGlobalRoute(handleMovement);
    onMovement();
  }

  // Movement can arrive before layout or while a held mouse button still
  // routes events to the launcher's original hit target.
  router.addGlobalRoute(handleMovement);
  return () {
    if (!tracking) return;
    tracking = false;
    router.removeGlobalRoute(handleMovement);
  };
}

Future<T?> showDockAwareMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<UnifiedMenuEntry<T>> entries,
  Listenable? dismissOn,
}) => _showDockAwareMenu(
  context: context,
  position: position,
  entries: entries,
  dismissOn: dismissOn,
);

Future<T?> _showDockAwareMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<UnifiedMenuEntry<T>> entries,
  Listenable? dismissOn,
  bool pointerAnchored = false,
}) async {
  final overlayState =
      MobileOverlayInset.menuOverlayOf(context) ?? Overlay.maybeOf(context);
  if (overlayState == null) return null;
  final tickerMode = TickerMode.getValuesNotifier(context);
  if (!tickerMode.value.enabled) return null;

  final completer = Completer<T?>();
  final interactionSource = Object();
  final themes = InheritedTheme.capture(from: context, to: null);
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  final hostRoute = readAppRoute(context);
  final menuDismiss = MobileOverlayInset.menuDismissOf(context);
  final menuKey = GlobalKey<_DockMenuOverlayState<T>>();
  var hoverEnabled = false;
  late OverlayEntry entry;

  void removeImmediately() {
    if (completer.isCompleted) return;
    UiInteractionCoordinator.instance.cancelInteraction(interactionSource);
    completer.complete(null);
  }

  void cancelMenu() {
    if (completer.isCompleted) return;
    final state = menuKey.currentState;
    if (state != null) {
      unawaited(state._dismiss(null));
    } else {
      // A cancellation before the first overlay frame has no visible content.
      removeImmediately();
    }
  }

  void cancelWhenHidden() {
    if (!tickerMode.value.enabled) removeImmediately();
  }

  entry = OverlayEntry(
    builder: (_) => _DockMenuOverlay<T>(
      key: menuKey,
      position: position,
      pointerAnchored: pointerAnchored,
      entries: entries,
      themes: themes,
      reducedMotion: reducedMotion,
      interactionSource: interactionSource,
      hoverEnabled: hoverEnabled,
      onResult: (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      externallyManagedDismiss: menuDismiss != null,
    ),
  );

  UiInteractionCoordinator.instance.beginInteraction(interactionSource);
  tickerMode.addListener(cancelWhenHidden);
  // This notifier belongs to the launching widget's disposal. Its overlay
  // cannot remain interactive after the host is gone.
  dismissOn?.addListener(removeImmediately);
  menuDismiss?.value?.call();
  menuDismiss?.value = cancelMenu;
  final stopTrackingHover = _enableMenuHoverOnMovement(() {
    hoverEnabled = true;
    entry.markNeedsBuild();
  });
  overlayState.insert(entry);
  // A root overlay outlives its launching page. Remove its menu when that
  // route completes, including a pop before the menu's first layout.
  unawaited(hostRoute?.popped.then((_) => removeImmediately()));
  try {
    return await completer.future;
  } finally {
    stopTrackingHover();
    if (identical(menuDismiss?.value, cancelMenu)) menuDismiss?.value = null;
    tickerMode.removeListener(cancelWhenHidden);
    dismissOn?.removeListener(removeImmediately);
    entry.remove();
    entry.dispose();
    UiInteractionCoordinator.instance.cancelInteraction(interactionSource);
  }
}

class _DockMenuOverlay<T> extends StatefulWidget {
  const _DockMenuOverlay({
    super.key,
    required this.position,
    required this.pointerAnchored,
    required this.entries,
    required this.themes,
    required this.reducedMotion,
    required this.interactionSource,
    required this.hoverEnabled,
    required this.onResult,
    required this.externallyManagedDismiss,
  });

  final RelativeRect position;
  final bool pointerAnchored;
  final List<UnifiedMenuEntry<T>> entries;
  final CapturedThemes themes;
  final bool reducedMotion;
  final Object interactionSource;
  final bool hoverEnabled;
  final ValueChanged<T?> onResult;
  final bool externallyManagedDismiss;

  @override
  State<_DockMenuOverlay<T>> createState() => _DockMenuOverlayState<T>();
}

class _DockMenuOverlayState<T> extends State<_DockMenuOverlay<T>>
    with SingleTickerProviderStateMixin {
  final _focusScope = FocusScopeNode();
  late final AnimationController _controller;
  late final CurvedAnimation _curved;
  late final CurvedAnimation _scaleCurved;
  late final Animation<double> _scale;
  bool _dismissed = false;
  bool _started = false;
  bool _resultCompleted = false;
  T? _dismissValue;
  bool get _reducedMotion =>
      widget.reducedMotion || MediaQuery.disableAnimationsOf(context);
  Object get _interactionSource => widget.interactionSource;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _menuEnterDuration,
      reverseDuration: _menuExitDuration,
    )..addStatusListener(_handleAnimationStatus);
    _curved = CurvedAnimation(
      parent: _controller,
      curve: kAppSpringCurve,
      reverseCurve: Curves.easeInCubic,
    );
    _scaleCurved = CurvedAnimation(
      parent: _controller,
      // Overshoot makes the free edges move back toward the pointer at rest.
      curve: widget.pointerAnchored
          ? kAppSpringCurve
          : const Cubic(0.2, 0.92, 0.25, 1.032),
      reverseCurve: Curves.easeInCubic,
    );
    _scale = Tween<double>(begin: 0.88, end: 1).animate(_scaleCurved);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dismissed) return;
      _focusScope.requestFocus();
    });
  }

  void _handleAnimationStatus(AnimationStatus status) {
    final interaction = UiInteractionCoordinator.instance;
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      interaction.beginInteraction(_interactionSource);
    } else {
      interaction.endInteraction(_interactionSource);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reducedMotion) {
      _controller.value = _dismissed ? 0 : 1;
      UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
      if (_dismissed) _completeResult(_dismissValue);
    } else if (!_started) {
      _controller.forward(from: 0);
    }
    _started = true;
  }

  @override
  void dispose() {
    _focusScope.dispose();
    _curved.dispose();
    _scaleCurved.dispose();
    _controller.dispose();
    UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
    _completeResult(null);
    super.dispose();
  }

  Future<void> _dismiss(T? value) async {
    if (_dismissed) return;
    setState(() => _dismissed = true);
    _dismissValue = value;
    try {
      if (!_reducedMotion) {
        await _controller.reverse().orCancel;
      }
    } on TickerCanceled {
      return;
    }
    _completeResult(value);
  }

  void _completeResult(T? value) {
    if (_resultCompleted) return;
    _resultCompleted = true;
    widget.onResult(value);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => _dismiss(null),
      },
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        child: FocusScope(
          node: _focusScope,
          autofocus: true,
          child: PopScope(
            canPop: widget.externallyManagedDismiss,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && !widget.externallyManagedDismiss) _dismiss(null);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _dismiss(null),
                  child: FadeTransition(
                    opacity: _curved,
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.scrim.withValues(
                        alpha: Theme.of(context).brightness == Brightness.dark
                            ? 0.16
                            : 0.06,
                      ),
                    ),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final size = constraints.biggest;
                    final layout = _DockMenuLayout(widget.position);
                    final anchor = widget.position
                        .toRect(Offset.zero & size)
                        .center;
                    return CustomSingleChildLayout(
                      delegate: layout,
                      // Keep hit testing within the painted bounds, including
                      // the brief expansion beyond the resting menu edges.
                      child: _AnchoredMenuScale(
                        anchorInMenu: (menuSize) =>
                            anchor - layout.getPositionForChild(size, menuSize),
                        scale: _scale,
                        child: FadeTransition(
                          opacity: _curved,
                          child: widget.themes.wrap(
                            Material(
                              color: Colors.transparent,
                              child: SingleChildScrollView(
                                child: IntrinsicWidth(
                                  child: ExcludeFocus(
                                    excluding: _dismissed,
                                    child: ExcludeSemantics(
                                      excluding: _dismissed,
                                      child: IgnorePointer(
                                        ignoring: _dismissed,
                                        child: _UnifiedPopupMenuCard<T>(
                                          entries: widget.entries,
                                          textAlign: TextAlign.left,
                                          suppressHover: !widget.hoverEnabled,
                                          compact: true,
                                          primaryIcons: true,
                                          onSelected: (value) =>
                                              _dismiss(value),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ).withWindowsSmoothScroll(),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<T?> showUnifiedContextMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<UnifiedMenuEntry<T>> entries,
}) {
  final localOverlay = MobileOverlayInset.menuOverlayOf(context);
  final overlay = localOverlay ?? Overlay.of(context);
  final box = overlay.context.findRenderObject()! as RenderBox;
  final point = box.globalToLocal(globalPosition);
  final position = RelativeRect.fromRect(
    point & Size.zero,
    Offset.zero & box.size,
  );
  return _showDockAwareMenu<T>(
    context: context,
    position: position,
    entries: entries,
    pointerAnchored: true,
  );
}
