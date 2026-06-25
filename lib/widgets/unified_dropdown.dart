import 'package:flutter/material.dart';

const double _dropdownRadius = 12;

List<DropdownMenuItem<T>> _alignItems<T>(
  List<DropdownMenuItem<T>> items,
  AlignmentGeometry alignment,
) {
  return items.map((item) {
    return DropdownMenuItem<T>(
      key: item.key,
      value: item.value,
      onTap: item.onTap,
      enabled: item.enabled,
      alignment: alignment,
      child: item.child,
    );
  }).toList();
}

class UnifiedDropdownButton<T> extends StatelessWidget {
  const UnifiedDropdownButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.isExpanded = false,
    this.isDense = false,
    this.alignment = AlignmentDirectional.centerEnd,
    this.menuMaxHeight,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool isExpanded;
  final bool isDense;
  final AlignmentGeometry alignment;
  final double? menuMaxHeight;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        items: _alignItems(items, alignment),
        onChanged: onChanged,
        isExpanded: isExpanded,
        isDense: isDense,
        alignment: alignment,
        menuMaxHeight: menuMaxHeight,
        dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(_dropdownRadius),
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
  });

  final T? initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final AlignmentGeometry alignment;
  final double? menuMaxHeight;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: initialValue,
      items: _alignItems(items, alignment),
      onChanged: onChanged,
      decoration: decoration,
      alignment: alignment,
      menuMaxHeight: menuMaxHeight,
      dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(_dropdownRadius),
    );
  }
}
