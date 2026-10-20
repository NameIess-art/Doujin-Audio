import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mobile_overlay_inset.dart';
import 'unified_popup_menu.dart';

class UnifiedDropdownButton<T> extends StatefulWidget {
  const UnifiedDropdownButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.isExpanded = false,
    this.isDense = false,
    this.alignment = AlignmentDirectional.centerEnd,
    this.menuMaxHeight,
    this.multilineItems = false,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool isExpanded;
  final bool isDense;
  final AlignmentGeometry alignment;
  final double? menuMaxHeight;
  final bool multilineItems;

  @override
  State<UnifiedDropdownButton<T>> createState() =>
      _UnifiedDropdownButtonState<T>();
}

class _UnifiedDropdownButtonState<T> extends State<UnifiedDropdownButton<T>> {
  final _anchorKey = GlobalKey();
  final _dismiss = ValueNotifier<bool>(false);
  bool _open = false;

  @override
  void dispose() {
    _dismiss.value = true;
    _dismiss.dispose();
    super.dispose();
  }

  Future<void> _showMenu() async {
    if (_open || widget.onChanged == null || widget.items.isEmpty) return;
    final items = widget.items;
    final box = _anchorKey.currentContext!.findRenderObject()! as RenderBox;
    final overlay =
        MobileOverlayInset.menuOverlayOf(context) ?? Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject()! as RenderBox;
    final rect =
        box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
    _open = true;
    try {
      final index = await showDockAwareMenu<int>(
        context: context,
        position: RelativeRect.fromRect(rect, Offset.zero & overlayBox.size),
        dismissOn: _dismiss,
        menuMaxHeight: widget.menuMaxHeight,
        entries: [
          for (var index = 0; index < items.length; index++)
            UnifiedMenuEntry.action(
              value: index,
              label: '',
              enabled: items[index].enabled,
              selected: items[index].value == widget.value,
              labelWidget: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: widget.multilineItems ? 8 : 0,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: switch (items[index].child) {
                    Text(:final data?, :final style) => Text(
                      data,
                      style: style,
                      textAlign: TextAlign.start,
                      softWrap: widget.multilineItems,
                      maxLines: widget.multilineItems ? null : 1,
                      overflow: widget.multilineItems
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                    ),
                    final child => child,
                  },
                ),
              ),
            ),
        ],
      );
      if (!mounted || index == null) return;
      final item = items[index];
      item.onTap?.call();
      widget.onChanged?.call(item.value);
    } finally {
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null && widget.items.isNotEmpty;
    final selected = widget.items
        .where((item) => item.value == widget.value)
        .firstOrNull;
    Widget label = Align(
      widthFactor: widget.isExpanded ? null : 1,
      alignment: widget.alignment,
      child: selected?.child ?? const SizedBox.shrink(),
    );
    if (widget.isExpanded) label = Expanded(child: label);
    return Semantics(
      button: true,
      enabled: enabled,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): _showMenu,
          const SingleActivator(LogicalKeyboardKey.arrowUp): _showMenu,
        },
        child: InkWell(
          key: _anchorKey,
          onTap: enabled ? _showMenu : null,
          child: DefaultTextStyle.merge(
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: enabled ? null : Theme.of(context).disabledColor,
            ),
            child: SizedBox(
              height: widget.isDense ? 24 : kMinInteractiveDimension,
              child: Row(
                mainAxisSize: widget.isExpanded
                    ? MainAxisSize.max
                    : MainAxisSize.min,
                children: [
                  label,
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_drop_down,
                    color: enabled ? null : Theme.of(context).disabledColor,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
    this.alignment = AlignmentDirectional.centerEnd,
    this.menuMaxHeight,
    this.multilineItems = false,
  });

  final T? initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final AlignmentGeometry alignment;
  final double? menuMaxHeight;
  final bool multilineItems;

  @override
  Widget build(BuildContext context) {
    return _UnifiedDropdownField<T>(
      initialValue: initialValue,
      enabled: onChanged != null,
      onChanged: onChanged,
      builder: (field) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        child: Builder(
          builder: (context) => InputDecorator(
            decoration: decoration.copyWith(
              enabled: onChanged != null,
              errorText: field.errorText,
            ),
            isEmpty: field.value == null,
            isFocused: Focus.of(context).hasFocus,
            child: UnifiedDropdownButton<T>(
              value: field.value,
              items: items,
              onChanged: onChanged == null
                  ? null
                  : (value) {
                      field.didChange(value);
                      onChanged!(value);
                    },
              isExpanded: true,
              isDense: true,
              alignment: alignment,
              menuMaxHeight: menuMaxHeight,
              multilineItems: multilineItems,
            ),
          ),
        ),
      ),
    );
  }
}

class _UnifiedDropdownField<T> extends FormField<T> {
  const _UnifiedDropdownField({
    required super.initialValue,
    required super.enabled,
    required super.builder,
    required this.onChanged,
  });

  final ValueChanged<T?>? onChanged;

  @override
  FormFieldState<T> createState() => _UnifiedDropdownFieldState<T>();
}

class _UnifiedDropdownFieldState<T> extends FormFieldState<T> {
  @override
  void reset() {
    super.reset();
    (widget as _UnifiedDropdownField<T>).onChanged?.call(value);
  }

  @override
  void didUpdateWidget(covariant _UnifiedDropdownField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      setValue(widget.initialValue);
    }
  }
}
