import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';

List<DropdownMenuItem<T>> _alignItems<T>(
  List<DropdownMenuItem<T>> items,
  AlignmentGeometry alignment,
  bool multilineItems,
) {
  return items.map((item) {
    return DropdownMenuItem<T>(
      key: item.key,
      value: item.value,
      onTap: item.onTap,
      enabled: item.enabled,
      alignment: alignment,
      child: multilineItems
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: item.child,
            )
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
    this.isExpanded = false,
    this.isDense = false,
    this.alignment = AlignmentDirectional.centerStart,
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
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onChanged = widget.onChanged;
    return Theme(
      data: Theme.of(context).copyWith(hoverColor: Colors.transparent),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            focusColor: Colors.transparent,
            focusNode: _focusNode,
            value: widget.value,
            items: _alignItems(
              widget.items,
              widget.alignment,
              widget.multilineItems,
            ),
            selectedItemBuilder: widget.multilineItems
                ? (context) => widget.items
                      .map(
                        (item) => Align(
                          alignment: widget.alignment,
                          child: item.child,
                        ),
                      )
                      .toList(growable: false)
                : null,
            onChanged: onChanged == null
                ? null
                : (value) {
                    _focusNode.unfocus(
                      disposition: UnfocusDisposition.previouslyFocusedChild,
                    );
                    onChanged(value);
                  },
            isExpanded: widget.isExpanded,
            isDense: widget.isDense,
            alignment: widget.alignment,
            menuMaxHeight: widget.menuMaxHeight,
            itemHeight: widget.multilineItems ? null : kMinInteractiveDimension,
            dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: AppRadius.borderMedium,
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
    return DropdownButtonFormField<T>(
      initialValue: initialValue,
      items: _alignItems(items, alignment, multilineItems),
      onChanged: onChanged,
      decoration: decoration,
      alignment: alignment,
      menuMaxHeight: menuMaxHeight,
      itemHeight: multilineItems ? null : kMinInteractiveDimension,
      dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: AppRadius.borderMedium,
    );
  }
}
