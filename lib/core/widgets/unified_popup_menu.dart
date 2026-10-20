import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/ui_interaction_coordinator.dart';
import '../../app/theme/app_design_tokens.dart';
import 'app_feedback.dart';
import 'app_transitions.dart';
import 'mobile_overlay_inset.dart';

class UnifiedMenuEntry<T> {
  const UnifiedMenuEntry.action({
    required this.value,
    this.icon,
    this.iconWidget,
    required this.label,
    this.labelWidget,
    this.selected = false,
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
      labelWidget = null,
      selected = false,
      trailing = null,
      trailingValue = null,
      destructive = false,
      enabled = false,
      divider = true;

  final T? value;
  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final Widget? labelWidget;
  final bool selected;
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

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kAppFadeDuration,
      reverseDuration: kAppFadeDuration,
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
    final screenWidth = overlayBox.size.width;
    final availableWidth = (screenWidth - 20).clamp(0.0, double.infinity);
    final menuWidth = widget.menuWidth.clamp(0.0, availableWidth);
    if (menuWidth == 0) return;
    final left = (anchorRect.right - menuWidth).clamp(
      10.0,
      screenWidth - menuWidth - 10.0,
    );
    final maxTop = (overlayBox.size.height - 64).clamp(8.0, double.infinity);
    final top = anchorRect.top.clamp(8.0, maxTop);

    _entry = OverlayEntry(
      builder: (overlayContext) {
        return _UnifiedPopupOverlay<T>(
          animation: _controller,
          rect: Rect.fromLTWH(left, top, menuWidth, anchorRect.height),
          entries: widget.entries,
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
    UiInteractionCoordinator.instance.beginInteraction(_interactionSource);
    _menuDismiss = MobileOverlayInset.menuDismissOf(context);
    _menuDismiss?.value?.call();
    _dismissCallback = () => unawaited(_removeOverlay());
    _menuDismiss?.value = _dismissCallback;
    overlay.insert(_entry!);
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
    required this.entries,
    required this.onDismiss,
    required this.onSelected,
    this.onTrailingSelected,
  });

  final Animation<double> animation;
  final Rect rect;
  final List<UnifiedMenuEntry<T>> entries;
  final Future<void> Function() onDismiss;
  final ValueChanged<T> onSelected;
  final ValueChanged<T>? onTrailingSelected;

  @override
  State<_UnifiedPopupOverlay<T>> createState() =>
      _UnifiedPopupOverlayState<T>();
}

class _UnifiedPopupOverlayState<T> extends State<_UnifiedPopupOverlay<T>> {
  late CurvedAnimation _curved;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _bindAnimation();
    widget.animation.addStatusListener(_handleAnimationStatus);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (mounted) setState(() {});
  }

  void _bindAnimation() {
    _curved = CurvedAnimation(
      parent: widget.animation,
      curve: kAppFadeCurve,
      reverseCurve: kAppFadeCurve,
    );
    _scale = Tween<double>(begin: 0.96, end: 1).animate(_curved);
  }

  @override
  void didUpdateWidget(covariant _UnifiedPopupOverlay<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_handleAnimationStatus);
      _curved.dispose();
      _bindAnimation();
      widget.animation.addStatusListener(_handleAnimationStatus);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_handleAnimationStatus);
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          autofocus: true,
          child: Material(
            color: Colors.transparent,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onDismiss,
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned(
                  left: widget.rect.left,
                  top: widget.rect.top,
                  width: widget.rect.width,
                  child: FadeTransition(
                    opacity: _curved,
                    child: ScaleTransition(
                      alignment: Alignment.topRight,
                      scale: _scale,
                      child: ExcludeFocus(
                        excluding:
                            widget.animation.status == AnimationStatus.reverse,
                        child: ExcludeSemantics(
                          excluding:
                              widget.animation.status ==
                              AnimationStatus.reverse,
                          child: IgnorePointer(
                            ignoring:
                                widget.animation.status ==
                                AnimationStatus.reverse,
                            child: _UnifiedPopupMenuCard<T>(
                              entries: widget.entries,
                              onSelected: widget.onSelected,
                              onTrailingSelected: widget.onTrailingSelected,
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
        ),
      ),
    );
  }
}

class _UnifiedPopupMenuCard<T> extends StatelessWidget {
  const _UnifiedPopupMenuCard({
    required this.entries,
    required this.onSelected,
    this.onTrailingSelected,
    this.compact = false,
    this.primaryIcons = false,
    this.autofocusFirstEntry = true,
    this.selectedEntryKey,
  });

  final bool compact;
  final bool primaryIcons;
  final bool autofocusFirstEntry;
  final Key? selectedEntryKey;
  final List<UnifiedMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final ValueChanged<T>? onTrailingSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tokens = AppDesignTokens.of(context);
    final background = isDark ? cs.surfaceBright : cs.surfaceContainerHighest;

    return ClipRRect(
      borderRadius: BorderRadius.circular(tokens.radiusSection),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(tokens.radiusSection),
          border: Border.all(
            color: cs.outlineVariant.withValues(
              alpha: tokens.standardBorderAlpha,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: isDark ? 0.36 : 0.18),
              blurRadius: 30,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Builder(
            builder: (context) {
              final enabledEntries = entries
                  .where((item) => item.enabled && !item.divider)
                  .toList(growable: false);
              final selectedEntry = entries
                  .where((item) => item.selected)
                  .firstOrNull;
              final firstAutofocusEntry =
                  enabledEntries.where((item) => item.selected).firstOrNull ??
                  enabledEntries.firstOrNull;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: entries
                    .map(
                      (entry) => _UnifiedPopupMenuRow<T>(
                        key: identical(entry, selectedEntry)
                            ? selectedEntryKey
                            : null,
                        entry: entry,
                        compact: compact,
                        primaryIcons: primaryIcons,
                        autofocus:
                            autofocusFirstEntry &&
                            identical(entry, firstAutofocusEntry),
                        onSelected: onSelected,
                        onTrailingSelected: onTrailingSelected,
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _UnifiedPopupMenuRow<T> extends StatelessWidget {
  const _UnifiedPopupMenuRow({
    super.key,
    required this.entry,
    required this.autofocus,
    required this.onSelected,
    this.onTrailingSelected,
    this.compact = false,
    this.primaryIcons = false,
  });

  final bool compact;
  final bool primaryIcons;
  final UnifiedMenuEntry<T> entry;
  final bool autofocus;
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
      child: InkWell(
        autofocus: autofocus,
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
        child: _UnifiedPopupMenuContent(
          entry: entry,
          compact: compact,
          primaryIcons: primaryIcons,
          onTrailingSelected: onTrailingSelected,
        ),
      ),
    );
  }
}

class _UnifiedPopupMenuContent<T> extends StatelessWidget {
  const _UnifiedPopupMenuContent({
    required this.entry,
    required this.compact,
    required this.primaryIcons,
    this.onTrailingSelected,
  });

  final UnifiedMenuEntry<T> entry;
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
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: entry.enabled
                      ? foreground
                      : cs.onSurface.withValues(alpha: 0.38),
                ),
                child:
                    entry.labelWidget ??
                    Text(
                      entry.label,
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
            ),
            if (entry.selected) ...[
              const SizedBox(width: 10),
              Icon(Icons.check, size: 18, color: cs.primary),
            ],
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
    return BoxConstraints.loose(constraints.biggest);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Right-align to button right edge.
    double x = size.width - position.right - childSize.width;
    if (x + childSize.width > size.width - 8) {
      x = size.width - 8 - childSize.width;
    }
    if (x < 8) x = 8;

    // Top-align to button top (covering the button).
    double y = position.top;
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

Future<T?> showDockAwareMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<UnifiedMenuEntry<T>> entries,
  Listenable? dismissOn,
  bool autofocusFirstEntry = true,
  double? menuMaxHeight,
  double? menuWidth,
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
      entries: entries,
      autofocusFirstEntry: autofocusFirstEntry,
      menuMaxHeight: menuMaxHeight,
      menuWidth: menuWidth,
      themes: themes,
      reducedMotion: reducedMotion,
      interactionSource: interactionSource,
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
  overlayState.insert(entry);
  // A root overlay outlives its launching page. Remove its menu when that
  // route completes, including a pop before the menu's first layout.
  unawaited(hostRoute?.popped.then((_) => removeImmediately()));
  try {
    return await completer.future;
  } finally {
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
    required this.entries,
    required this.themes,
    required this.reducedMotion,
    required this.interactionSource,
    required this.onResult,
    required this.externallyManagedDismiss,
    required this.autofocusFirstEntry,
    this.menuMaxHeight,
    this.menuWidth,
  });

  final RelativeRect position;
  final List<UnifiedMenuEntry<T>> entries;
  final CapturedThemes themes;
  final bool reducedMotion;
  final Object interactionSource;
  final ValueChanged<T?> onResult;
  final bool externallyManagedDismiss;
  final bool autofocusFirstEntry;
  final double? menuMaxHeight;
  final double? menuWidth;

  @override
  State<_DockMenuOverlay<T>> createState() => _DockMenuOverlayState<T>();
}

class _DockMenuOverlayState<T> extends State<_DockMenuOverlay<T>>
    with SingleTickerProviderStateMixin {
  final _focusScope = FocusScopeNode();
  final _selectedEntryKey = GlobalKey();
  late final AnimationController _controller;
  late final CurvedAnimation _curved;
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
      duration: kAppFadeDuration,
      reverseDuration: kAppFadeDuration,
    )..addStatusListener(_handleAnimationStatus);
    _curved = CurvedAnimation(
      parent: _controller,
      curve: kAppFadeCurve,
      reverseCurve: kAppFadeCurve,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dismissed) return;
      _focusScope.requestFocus();
      final selectedContext = _selectedEntryKey.currentContext;
      if (selectedContext != null) {
        // Match dropdown behavior: open at the current selection, before the
        // first visible fade tick, including long and multiline menus.
        Scrollable.ensureVisible(selectedContext, alignment: 0.5);
      }
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
                  child: const SizedBox.expand(),
                ),
                CustomSingleChildLayout(
                  delegate: _DockMenuLayout(widget.position),
                  child: FadeTransition(
                    opacity: _curved,
                    child: ScaleTransition(
                      alignment: Alignment.topRight,
                      scale: Tween<double>(
                        begin: 0.96,
                        end: 1,
                      ).animate(_curved),
                      child: widget.themes.wrap(
                        Material(
                          color: Colors.transparent,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: widget.menuWidth ?? 0,
                              maxWidth: widget.menuWidth ?? double.infinity,
                              maxHeight:
                                  widget.menuMaxHeight ?? double.infinity,
                            ),
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
                                        selectedEntryKey: _selectedEntryKey,
                                        autofocusFirstEntry:
                                            widget.autofocusFirstEntry,
                                        compact: true,
                                        primaryIcons: true,
                                        onSelected: (value) => _dismiss(value),
                                      ),
                                    ),
                                  ),
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
  return showDockAwareMenu<T>(
    context: context,
    position: position,
    entries: entries,
    // Keep keyboard focus in the menu without preselecting a mouse action.
    autofocusFirstEntry: false,
  );
}
