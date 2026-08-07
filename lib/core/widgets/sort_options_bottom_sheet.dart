import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_bottom_sheet.dart';

class SortOption<T> {
  const SortOption({required this.value, required this.label});

  final T value;
  final String label;
}

class SortSelection<T> {
  const SortSelection({
    required this.criterion,
    required this.ascending,
    required this.groupByLibrary,
  });

  final T criterion;
  final bool ascending;
  final bool groupByLibrary;
}

Future<SortSelection<T>?> showSortOptionsBottomSheet<T>({
  required BuildContext context,
  required List<SortOption<T>> options,
  required T selectedCriterion,
  required bool ascending,
  required bool groupByLibrary,
  required String title,
  required String descriptionLabel,
  required String ascendingLabel,
  required String descendingLabel,
  required String groupByLibraryLabel,
  required String cancelLabel,
  required String confirmLabel,
}) {
  return AppBottomSheet.show<SortSelection<T>>(
    context: context,
    builder: (sheetContext) => _SortOptionsSheet<T>(
      options: options,
      selectedCriterion: selectedCriterion,
      ascending: ascending,
      groupByLibrary: groupByLibrary,
      title: title,
      descriptionLabel: descriptionLabel,
      ascendingLabel: ascendingLabel,
      descendingLabel: descendingLabel,
      groupByLibraryLabel: groupByLibraryLabel,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
    ),
  );
}

class _SortOptionsSheet<T> extends StatefulWidget {
  const _SortOptionsSheet({
    required this.options,
    required this.selectedCriterion,
    required this.ascending,
    required this.groupByLibrary,
    required this.title,
    required this.descriptionLabel,
    required this.ascendingLabel,
    required this.descendingLabel,
    required this.groupByLibraryLabel,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  final List<SortOption<T>> options;
  final T selectedCriterion;
  final bool ascending;
  final bool groupByLibrary;
  final String title;
  final String descriptionLabel;
  final String ascendingLabel;
  final String descendingLabel;
  final String groupByLibraryLabel;
  final String cancelLabel;
  final String confirmLabel;

  @override
  State<_SortOptionsSheet<T>> createState() => _SortOptionsSheetState<T>();
}

class _SortOptionsSheetState<T> extends State<_SortOptionsSheet<T>> {
  late T _selectedCriterion = widget.selectedCriterion;
  late bool _ascending = widget.ascending;
  late bool _groupByLibrary = widget.groupByLibrary;

  SortSelection<T> get _selection => SortSelection<T>(
    criterion: _selectedCriterion,
    ascending: _ascending,
    groupByLibrary: _groupByLibrary,
  );

  Set<_SortControl> get _selectedControls => <_SortControl>{
    if (_groupByLibrary) _SortControl.groupByLibrary,
    _ascending ? _SortControl.ascending : _SortControl.descending,
  };

  void _updateControls(Set<_SortControl> values) {
    final hasAscending = values.contains(_SortControl.ascending);
    final hasDescending = values.contains(_SortControl.descending);
    var nextAscending = _ascending;
    if (hasAscending && hasDescending) {
      nextAscending = !_ascending;
    } else if (hasAscending) {
      nextAscending = true;
    } else if (hasDescending) {
      nextAscending = false;
    }
    setState(() {
      _ascending = nextAscending;
      _groupByLibrary = values.contains(_SortControl.groupByLibrary);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final view = View.of(context);
        final viewportHeight = view.physicalSize.height / view.devicePixelRatio;
        final maxHeight = math.min(constraints.maxHeight, viewportHeight);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight * 0.9),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            widget.title,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 18),
                          RadioGroup<T>(
                            groupValue: _selectedCriterion,
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() => _selectedCriterion = value);
                            },
                            child: Column(
                              children: widget.options
                                  .map(
                                    (option) => RadioListTile<T>(
                                      value: option.value,
                                      title: Text(option.label),
                                      contentPadding: EdgeInsets.zero,
                                      visualDensity: const VisualDensity(
                                        vertical: -1,
                                      ),
                                      activeColor: cs.primary,
                                    ),
                                  )
                                  .toList(growable: false),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            widget.descriptionLabel,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SegmentedButton<_SortControl>(
                            segments: [
                              ButtonSegment<_SortControl>(
                                value: _SortControl.groupByLibrary,
                                label: Text(widget.groupByLibraryLabel),
                              ),
                              ButtonSegment<_SortControl>(
                                value: _SortControl.ascending,
                                label: Text(widget.ascendingLabel),
                              ),
                              ButtonSegment<_SortControl>(
                                value: _SortControl.descending,
                                label: Text(widget.descendingLabel),
                              ),
                            ],
                            selected: _selectedControls,
                            multiSelectionEnabled: true,
                            onSelectionChanged: _updateControls,
                            expandedInsets: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    key: const ValueKey('sort_options_actions'),
                    width: double.infinity,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          key: const ValueKey('sort_options_cancel'),
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(widget.cancelLabel),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          key: const ValueKey('sort_options_confirm'),
                          onPressed: () =>
                              Navigator.of(context).pop(_selection),
                          child: Text(widget.confirmLabel),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _SortControl { groupByLibrary, ascending, descending }
