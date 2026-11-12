import 'package:flutter/material.dart';

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
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool isDense;
  final AlignmentGeometry alignment;
  final bool insetTrigger;
  final double? menuMaxHeight;
  final bool multilineItems;

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
    final button = Theme(
      data: Theme.of(context).copyWith(hoverColor: Colors.transparent),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: ButtonTheme.fromButtonThemeData(
          data: ButtonTheme.of(context).copyWith(
            alignedDropdown: widget.insetTrigger,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              focusColor: Colors.transparent,
              focusNode: _focusNode,
              value: widget.value,
              items: _alignItems(
                widget.items,
                widget.alignment,
                widget.multilineItems,
                // The unpadded Material trigger expands its popup by 16px
                // at the start and 24px at the end to align the labels.
                // Reserve the extra end space so the text wraps identically.
                trailingPadding: widget.insetTrigger ? 12 : 32,
              ),
              selectedItemBuilder: (context) => widget.items
                  .map(
                    (item) =>
                        Align(alignment: widget.alignment, child: item.child),
                  )
                  .toList(growable: false),
              onChanged: onChanged == null
                  ? null
                  : (value) {
                      _focusNode.unfocus(
                        disposition: UnfocusDisposition.previouslyFocusedChild,
                      );
                      onChanged(value);
                    },
              isExpanded: true,
              isDense: widget.isDense,
              alignment: widget.alignment,
              menuMaxHeight: widget.menuMaxHeight,
              itemHeight: widget.multilineItems
                  ? null
                  : kMinInteractiveDimension,
              dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: AppRadius.borderMedium,
            ),
          ),
        ),
      ),
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
    final field = ButtonTheme.fromButtonThemeData(
      data: ButtonTheme.of(context).copyWith(alignedDropdown: true),
      child: DropdownButtonFormField<T>(
        initialValue: initialValue,
        items: _alignItems(items, alignment, multilineItems),
        onChanged: onChanged,
        decoration: decoration,
        isExpanded: true,
        alignment: alignment,
        menuMaxHeight: menuMaxHeight,
        itemHeight: multilineItems ? null : kMinInteractiveDimension,
        dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.borderMedium,
      ),
    );
    return Align(
      alignment: alignment,
      widthFactor: 1,
      heightFactor: 1,
      child: IntrinsicWidth(child: field),
    );
  }
}
