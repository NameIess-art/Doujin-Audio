import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/ui_interaction_coordinator.dart';
import '../../app/theme/app_design_tokens.dart';
import 'app_feedback.dart';
import 'mobile_overlay_inset.dart';

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
  late final AnimationController _controller;
  final Object _interactionSource = Object();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 100),
    );
  }

  @override
  void dispose() {
    _removeOverlay(immediate: true);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!widget.enabled) return;
    if (_entry != null) {
      await _removeOverlay();
      return;
    }
    _showOverlay();
  }

  void _showOverlay() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;

    final anchorOffset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final anchorRect = anchorOffset & box.size;
    final screenWidth = overlayBox.size.width;
    final left = (anchorRect.right - widget.menuWidth).clamp(
      10.0,
      screenWidth - widget.menuWidth - 10.0,
    );
    final top = anchorRect.top.clamp(8.0, overlayBox.size.height - 64.0);

    _entry = OverlayEntry(
      builder: (overlayContext) {
        return _UnifiedPopupOverlay<T>(
          animation: _controller,
          rect: Rect.fromLTWH(left, top, widget.menuWidth, anchorRect.height),
          entries: widget.entries,
          onDismiss: _removeOverlay,
          onSelected: (value) async {
            if (widget.selectAfterDismiss) {
              await _removeOverlay();
              widget.onSelected(value);
              return;
            }
            await _removeOverlay(immediate: true);
            widget.onSelected(value);
          },
          onTrailingSelected: (value) async {
            await _removeOverlay();
            widget.onTrailingSelected?.call(value);
          },
        );
      },
    );
    UiInteractionCoordinator.instance.beginInteraction(_interactionSource);
    overlay.insert(_entry!);
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  Future<void> _removeOverlay({bool immediate = false}) async {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!immediate && !reduceMotion) {
      try {
        await _controller.reverse();
      } catch (_) {
        // The entry may be disposed while its closing animation is running.
      }
    }
    entry.remove();
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

class _UnifiedPopupOverlay<T> extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onDismiss},
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
                    onTap: onDismiss,
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned(
                  left: rect.left,
                  top: rect.top,
                  width: rect.width,
                  child: FadeTransition(
                    opacity: curved,
                    child: ScaleTransition(
                      alignment: Alignment.topRight,
                      scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
                      child: _UnifiedPopupMenuCard<T>(
                        entries: entries,
                        onSelected: onSelected,
                        onTrailingSelected: onTrailingSelected,
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
  });

  final bool compact;
  final bool primaryIcons;
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
              final firstAutofocusEntry = entries
                  .where((item) => item.enabled && !item.divider)
                  .firstOrNull;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: entries
                    .map(
                      (entry) => _UnifiedPopupMenuRow<T>(
                        entry: entry,
                        compact: compact,
                        primaryIcons: primaryIcons,
                        autofocus: identical(entry, firstAutofocusEntry),
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
    return SizedBox(
      height: compact ? 40 : 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
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
            Expanded(
              child: Text(
                entry.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: foreground,
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
}) async {
  final overlayState =
      MobileOverlayInset.menuOverlayOf(context) ?? Overlay.maybeOf(context);
  if (overlayState == null) return null;

  final completer = Completer<T?>();
  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (_) => _DockMenuOverlay<T>(
      position: position,
      entries: entries,
      themeContext: context,
      onResult: (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
    ),
  );

  overlayState.insert(entry);
  final result = await completer.future;
  entry.remove();
  entry.dispose();
  return result;
}

class _DockMenuOverlay<T> extends StatefulWidget {
  const _DockMenuOverlay({
    required this.position,
    required this.entries,
    required this.themeContext,
    required this.onResult,
  });

  final RelativeRect position;
  final List<UnifiedMenuEntry<T>> entries;
  final BuildContext themeContext;
  final ValueChanged<T?> onResult;

  @override
  State<_DockMenuOverlay<T>> createState() => _DockMenuOverlayState<T>();
}

class _DockMenuOverlayState<T> extends State<_DockMenuOverlay<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 100),
    );
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss(T? value) async {
    if (_dismissed) return;
    _dismissed = true;
    try {
      await _controller.reverse();
    } catch (_) {
      // Animation controller may be disposed if unmounted.
    }
    widget.onResult(value);
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => _dismiss(null),
      },
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _dismiss(null);
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
                opacity: curved,
                child: ScaleTransition(
                  alignment: Alignment.topRight,
                  scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
                  child: InheritedTheme.captureAll(
                    widget.themeContext,
                    Material(
                      color: Colors.transparent,
                      child: IntrinsicWidth(
                        child: _UnifiedPopupMenuCard<T>(
                          entries: widget.entries,
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
          ],
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
  final box = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final point = box.globalToLocal(globalPosition);
  return showMenu<T>(
    context: context,
    requestFocus: true,
    position: RelativeRect.fromRect(point & Size.zero, Offset.zero & box.size),
    items: [
      for (final entry in entries)
        if (entry.divider)
          const PopupMenuDivider()
        else
          PopupMenuItem<T>(
            value: entry.value,
            enabled: entry.enabled,
            height: 40,
            padding: EdgeInsets.zero,
            child: _UnifiedPopupMenuContent(
              entry: entry,
              compact: true,
              primaryIcons: true,
            ),
          ),
    ],
  );
}
