import 'package:flutter/material.dart';

const double _dropdownRadius = 12;

class UnifiedDropdownButton<T> extends StatelessWidget {
  const UnifiedDropdownButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.isExpanded = false,
    this.isDense = false,
    this.menuMaxHeight,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool isExpanded;
  final bool isDense;
  final double? menuMaxHeight;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        isExpanded: isExpanded,
        isDense: isDense,
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
    this.menuMaxHeight,
  });

  final T? initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final double? menuMaxHeight;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: initialValue,
      items: items,
      onChanged: onChanged,
      decoration: decoration,
      menuMaxHeight: menuMaxHeight,
      dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(_dropdownRadius),
    );
  }
}
