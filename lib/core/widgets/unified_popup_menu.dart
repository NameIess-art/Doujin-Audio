import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/ui_interaction_coordinator.dart';
import '../../app/theme/app_design_tokens.dart';
import 'app_feedback.dart';

class UnifiedMenuEntry<T> {
  const UnifiedMenuEntry.action({
    required this.value,
    required this.icon,
    required this.label,
    this.trailing,
    this.trailingValue,
    this.destructive = false,
    this.enabled = true,
  }) : divider = false;

  const UnifiedMenuEntry.divider()
    : value = null,
      icon = null,
      label = '',
      trailing = null,
      trailingValue = null,
      destructive = false,
      enabled = false,
      divider = true;

  final T? value;
  final IconData? icon;
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

    return Material(
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
    );
  }
}

class _UnifiedPopupMenuCard<T> extends StatelessWidget {
  const _UnifiedPopupMenuCard({
    required this.entries,
    required this.onSelected,
    this.onTrailingSelected,
  });

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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: entries
                .map(
                  (entry) => _UnifiedPopupMenuRow<T>(
                    entry: entry,
                    onSelected: onSelected,
                    onTrailingSelected: onTrailingSelected,
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ),
    );
  }
}

class _UnifiedPopupMenuRow<T> extends StatelessWidget {
  const _UnifiedPopupMenuRow({
    required this.entry,
    required this.onSelected,
    this.onTrailingSelected,
  });

  final UnifiedMenuEntry<T> entry;
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
    final foreground = entry.destructive ? cs.error : cs.onSurface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
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
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(entry.icon, size: 21, color: foreground),
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
        ),
      ),
    );
  }
}
