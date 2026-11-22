import 'package:flutter/material.dart';

import 'app_buttons.dart';
import 'app_dialog.dart';
import 'app_tap_highlight.dart';
import 'app_transitions.dart';

import '../../app/theme/app_styles.dart';

List<DropdownMenuItem<T>> _alignItems<T>(
  List<DropdownMenuItem<T>> items,
  AlignmentGeometry alignment,
  bool multilineItems, {
  double trailingPadding = 0,
}) {
  final verticalPadding = multilineItems ? 8.0 : 0.0;
  final padding = EdgeInsetsDirectional.only(
    top: verticalPadding,
    end: trailingPadding,
    bottom: verticalPadding,
  );
  return items.map((item) {
    return DropdownMenuItem<T>(
      key: item.key,
      value: item.value,
      onTap: item.onTap,
      enabled: item.enabled,
      alignment: alignment,
      child: multilineItems || trailingPadding > 0
          ? Padding(padding: padding, child: item.child)
          : item.child,
    );
  }).toList();
}

class UnifiedDropdownButton<T> extends StatefulWidget {
  const UnifiedDropdownButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.isDense = false,
    this.alignment = AlignmentDirectional.centerStart,
    this.insetTrigger = true,
    this.menuMaxHeight,
    this.multilineItems = false,
    this.blurBackground = true,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool isDense;
  final AlignmentGeometry alignment;
  final bool insetTrigger;
  final double? menuMaxHeight;
  final bool multilineItems;
  final bool blurBackground;

  @override
  State<UnifiedDropdownButton<T>> createState() =>
      _UnifiedDropdownButtonState<T>();
}

class _UnifiedDropdownButtonState<T> extends State<UnifiedDropdownButton<T>> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onChanged = widget.onChanged;
    final button = _UnifiedDropdownPointerShell(
      enabled: onChanged != null,
      paintSurface: true,
      blurBackground: widget.blurBackground,
      builder: (context, feedback) {
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: ButtonTheme.fromButtonThemeData(
            data: ButtonTheme.of(
              context,
            ).copyWith(alignedDropdown: widget.insetTrigger),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                mouseCursor: WidgetStateMouseCursor.clickable,
                dropdownMenuItemMouseCursor: WidgetStateMouseCursor.clickable,
                focusColor: Colors.transparent,
                focusNode: _focusNode,
                value: widget.value,
                icon: const Icon(Icons.arrow_drop_down),
                items: _alignItems(
                  widget.items,
                  widget.alignment,
                  widget.multilineItems,
                  // The unpadded Material trigger expands its popup by 16px
                  // at the start and 24px at the end to align the labels.
                  // Reserve the extra end space so the text wraps identically.
                  trailingPadding: widget.insetTrigger ? 12 : 32,
                ),
                selectedItemBuilder: (context) =>
                    _buildSelectedItems(widget.items, widget.alignment),
                onChanged: onChanged == null
                    ? null
                    : (value) {
                        if (FocusManager.instance.highlightMode !=
                            FocusHighlightMode.traditional) {
                          _focusNode.unfocus(
                            disposition:
                                UnfocusDisposition.previouslyFocusedChild,
                          );
                        }
                        onChanged(value);
                      },
                isExpanded: true,
                isDense: widget.isDense,
                alignment: widget.alignment,
                menuMaxHeight: widget.menuMaxHeight,
                itemHeight: widget.multilineItems
                    ? null
                    : kMinInteractiveDimension,
                dropdownColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHigh,
                borderRadius: AppRadius.borderMedium,
              ),
            ),
          ),
        );
      },
    );
    // Keep the fitted trigger anchored inside its slot so the popup shares
    // both its width and its selected label's position.
    return Align(
      alignment: widget.alignment,
      widthFactor: 1,
      heightFactor: 1,
      child: IntrinsicWidth(child: button),
    );
  }
}

class UnifiedDropdownButtonFormField<T> extends StatelessWidget {
  const UnifiedDropdownButtonFormField({
    super.key,
    required this.initialValue,
    required this.items,
    required this.onChanged,
    required this.decoration,
    this.alignment = AlignmentDirectional.centerStart,
    this.expandWidth = false,
    this.menuMaxHeight,
    this.multilineItems = false,
  });

  final T? initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final AlignmentGeometry alignment;
  final bool expandWidth;
  final double? menuMaxHeight;
  final bool multilineItems;

  @override
  Widget build(BuildContext context) {
    final field = _UnifiedDropdownPointerShell(
      enabled: onChanged != null,
      paintSurface: false,
      builder: (context, feedback) {
        return ButtonTheme.fromButtonThemeData(
          data: ButtonTheme.of(context).copyWith(alignedDropdown: true),
          child: DropdownButtonFormField<T>(
            mouseCursor: WidgetStateMouseCursor.clickable,
            dropdownMenuItemMouseCursor: WidgetStateMouseCursor.clickable,
            initialValue: initialValue,
            icon: const Icon(Icons.arrow_drop_down),
            items: _alignItems(items, alignment, multilineItems),
            selectedItemBuilder: (context) =>
                _buildSelectedItems(items, alignment),
            onChanged: onChanged,
            focusColor: Colors.transparent,
            decoration: _hoverFormDecoration(context, decoration, feedback),
            isExpanded: true,
            alignment: alignment,
            menuMaxHeight: menuMaxHeight,
            itemHeight: multilineItems ? null : kMinInteractiveDimension,
            dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: AppRadius.borderMedium,
          ),
        );
      },
    );
    if (expandWidth) return SizedBox(width: double.infinity, child: field);
    return Align(
      alignment: alignment,
      widthFactor: 1,
      heightFactor: 1,
      child: IntrinsicWidth(child: field),
    );
  }
}

ThemeData _unifiedDropdownTheme(BuildContext context) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  return theme.copyWith(
    hoverColor: appHoverTint(cs),
    splashColor: appPressedTint(cs),
    highlightColor: Colors.transparent,
    splashFactory: AppTapHighlightFactory.forPlatform(theme.platform),
  );
}

List<Widget> _buildSelectedItems<T>(
  List<DropdownMenuItem<T>> items,
  AlignmentGeometry alignment,
) => [for (final item in items) Align(alignment: alignment, child: item.child)];

InputDecoration _hoverFormDecoration(
  BuildContext context,
  InputDecoration decoration,
  ({bool hovered, bool pressed}) feedback,
) {
  final theme = Theme.of(context);
  final resolved = decoration.applyDefaults(theme.inputDecorationTheme);
  final restingFill = resolved.filled == true
      ? resolved.fillColor ?? theme.colorScheme.surface
      : Colors.transparent;
  final highlighted = feedback.hovered || feedback.pressed;
  return decoration.copyWith(
    hoverColor: Colors.transparent,
    filled: highlighted ? true : resolved.filled,
    fillColor: highlighted
        ? appSurfaceHighlight(
            theme.colorScheme,
            restingFill,
            pressed: feedback.pressed,
            hovered: feedback.hovered,
          )
        : resolved.fillColor,
  );
}

class _UnifiedDropdownPointerShell extends StatelessWidget {
  const _UnifiedDropdownPointerShell({
    required this.enabled,
    required this.paintSurface,
    required this.builder,
    this.blurBackground = true,
  });

  final bool enabled;
  final bool paintSurface;
  final bool blurBackground;
  final Widget Function(
    BuildContext context,
    ({bool hovered, bool pressed}) feedback,
  )
  builder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trigger = Theme(
      data: _unifiedDropdownTheme(context),
      child: AppButtonPointerRegion(
        enabled: enabled,
        builder: (context, states) => ValueListenableBuilder<Set<WidgetState>>(
          valueListenable: states,
          builder: (context, value, _) {
            final disableAnimations = MediaQuery.disableAnimationsOf(context);
            final isWindows = theme.platform == TargetPlatform.windows;
            final hovered =
                enabled &&
                isWindows &&
                value.contains(WidgetState.hovered);
            final pressed = enabled && value.contains(WidgetState.pressed);
            final innerTrigger = builder(context, (
              hovered: hovered,
              pressed: pressed,
            ));
            final trigger = isWindows
                ? innerTrigger
                : AnimatedScale(
                    scale: pressed ? 0.985 : 1.0,
                    duration: disableAnimations
                        ? Duration.zero
                        : (pressed
                              ? const Duration(milliseconds: 85)
                              : const Duration(milliseconds: 210)),
                    curve: kAppSpringCurve,
                    child: innerTrigger,
                  );
            if (!paintSurface) return trigger;
            return AnimatedContainer(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 130),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                borderRadius: AppRadius.borderMedium,
                color: appSurfaceHighlight(
                  theme.colorScheme,
                  Colors.transparent,
                  pressed: pressed,
                  hovered: hovered,
                ),
              ),
              child: trigger,
            );
          },
        ),
      ),
    );
    return blurBackground ? _DropdownBackdropHost(child: trigger) : trigger;
  }
}

class _DropdownBackdropHost extends StatefulWidget {
  const _DropdownBackdropHost({required this.child});

  final Widget child;

  @override
  State<_DropdownBackdropHost> createState() => _DropdownBackdropHostState();
}

class _DropdownBackdropHostState extends State<_DropdownBackdropHost> {
  final _portal = OverlayPortalController();
  PopupRoute<dynamic>? _route;

  void _showFor(PopupRoute<dynamic> route) {
    if (!mounted || !route.isActive || identical(_route, route)) return;
    _route = route;
    _portal.show();
    route.completed.then((_) {
      if (!mounted || !identical(_route, route)) return;
      _portal.hide();
      _route = null;
    });
  }

  static const Curve _dropdownReverseCurve = Interval(
    0.20,
    1.0,
    curve: Curves.easeInQuad,
  );

  // DropdownButton fades its menu during the first quarter of the pop.
  static const _windowsDropdownReverseCurve = Interval(
    0.75,
    1.0,
    curve: Curves.easeInOut,
  );

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    // The portal paints with the trigger's route, below the dropdown route.
    overlayChildBuilder: (context) {
      final reverseCurve = Theme.of(context).platform == TargetPlatform.windows
          ? _windowsDropdownReverseCurve
          : _dropdownReverseCurve;
      return IgnorePointer(
        child: AppModalBackground(
          animation: MediaQuery.disableAnimationsOf(context)
              ? kAlwaysCompleteAnimation
              : (_route?.animation ?? kAlwaysDismissedAnimation),
          reverseCurve: reverseCurve,
          blurReverseCurve: reverseCurve,
        ),
      );
    },
    child: _DropdownBackdropTheme(onOpen: _showFor, child: widget.child),
  );
}

// Material dropdowns capture the trigger's inherited themes into their route.
// Use that capture to follow the menu animation and every dismissal path.
class _DropdownBackdropTheme extends InheritedTheme {
  const _DropdownBackdropTheme({required this.onOpen, required super.child});

  final ValueChanged<PopupRoute<dynamic>> onOpen;

  @override
  Widget wrap(BuildContext context, Widget child) => Builder(
    builder: (context) {
      final route = ModalRoute.of(context);
      if (route is PopupRoute<dynamic>) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onOpen(route));
      }
      return child;
    },
  );

  @override
  bool updateShouldNotify(_DropdownBackdropTheme oldWidget) =>
      oldWidget.onOpen != onOpen;
}
