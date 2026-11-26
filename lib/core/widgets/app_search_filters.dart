import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_design_tokens.dart';
import '../media/audio_detail.dart';
import '../media/search_query_utils.dart';
import 'app_edit_panel.dart';
import 'app_entry_ink_well.dart';
import 'app_fixed_extent_wheel.dart';
import 'unified_popup_menu.dart';
import 'work_listen_status_badge.dart';

class AppSearchFiltersPanel extends StatelessWidget {
  const AppSearchFiltersPanel({
    super.key,
    required this.filters,
    required this.onChanged,
    required this.translate,
    required this.titleStyle,
  });

  final SearchFilters filters;
  final ValueChanged<SearchFilters> onChanged;
  final String Function(String) translate;
  final TextStyle? titleStyle;

  void _update({
    (bool?,)? subtitle,
    (double?,)? rating,
    (int?,)? userRating,
    (WorkListenStatus?,)? listenStatus,
    (Duration?,)? minimumDuration,
    (Duration?,)? maximumDuration,
    (DateTime?,)? firstReleaseDate,
    (DateTime?,)? lastReleaseDate,
  }) {
    onChanged((
      hasSubtitle: subtitle == null ? filters.hasSubtitle : subtitle.$1,
      minimumRating: rating == null ? filters.minimumRating : rating.$1,
      minimumUserRating: userRating == null
          ? filters.minimumUserRating
          : userRating.$1,
      listenStatus: listenStatus == null
          ? filters.listenStatus
          : listenStatus.$1,
      minimumDuration: minimumDuration == null
          ? filters.minimumDuration
          : minimumDuration.$1,
      maximumDuration: maximumDuration == null
          ? filters.maximumDuration
          : maximumDuration.$1,
      firstReleaseDate: firstReleaseDate == null
          ? filters.firstReleaseDate
          : firstReleaseDate.$1,
      lastReleaseDate: lastReleaseDate == null
          ? filters.lastReleaseDate
          : lastReleaseDate.$1,
    ));
  }

  String _ratingLabel(int index) => index == 0
      ? translate('search_filter_any')
      : (index / 10).toStringAsFixed(1);

  String _userRatingLabel(int index) => index == 0
      ? translate('search_filter_any')
      : translate('work_user_rating_stars').replaceAll('{count}', '$index');

  Future<void> _pickDuration(
    BuildContext context, {
    required bool minimum,
  }) async {
    final current = minimum ? filters.minimumDuration : filters.maximumDuration;
    final opposite = minimum
        ? filters.maximumDuration
        : filters.minimumDuration;
    final form = GlobalKey<FormState>();
    Duration? value;
    void confirm(BuildContext context) {
      if (form.currentState?.validate() != true) return;
      form.currentState?.save();
      Navigator.pop(context, value);
    }

    final header = AppEditPanelHeader(
      icon: Icons.schedule_rounded,
      title: translate(
        minimum ? 'search_minimum_duration' : 'search_maximum_duration',
      ),
    );
    final selected = await showAppInputPanel<Duration>(
      context: context,
      header: header,
      preferredHeight: null,
      builder: (context, _) => AppEditPanelForm(
        header: header,
        fields: Form(
          key: form,
          child: TextFormField(
            contextMenuBuilder: buildAppEditableTextMenu,
            autofocus: true,
            initialValue: current?.inMinutes.toString(),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(7),
            ],
            decoration: InputDecoration(
              labelText: translate('search_duration_minutes'),
            ),
            validator: (input) {
              final minutes = int.tryParse(input ?? '');
              if (minutes == null) return translate('search_duration_minutes');
              final duration = Duration(minutes: minutes);
              if (opposite != null &&
                  (minimum ? duration > opposite : duration < opposite)) {
                return translate('search_invalid_duration_range');
              }
              return null;
            },
            onSaved: (input) => value = Duration(minutes: int.parse(input!)),
            onFieldSubmitted: (_) => confirm(context),
          ),
        ),
        cancelLabel: translate('cancel'),
        submitLabel: translate('confirm'),
        onCancel: () => Navigator.pop(context),
        onSubmit: () => confirm(context),
      ),
    );
    if (!context.mounted || selected == null) return;
    if (minimum) {
      _update(minimumDuration: (selected,));
    } else {
      _update(maximumDuration: (selected,));
    }
  }

  Future<void> _pickDate(BuildContext context, {required bool first}) async {
    final lower = first
        ? DateTime(1900)
        : filters.firstReleaseDate ?? DateTime(1900);
    final upper = first
        ? filters.lastReleaseDate ?? DateTime(2100, 12, 31)
        : DateTime(2100, 12, 31);
    final current = first ? filters.firstReleaseDate : filters.lastReleaseDate;
    final reference = current ?? DateUtils.dateOnly(DateTime.now());
    final selected = await showDatePicker(
      context: context,
      initialDate: reference.isBefore(lower)
          ? lower
          : reference.isAfter(upper)
          ? upper
          : reference,
      firstDate: lower,
      lastDate: upper,
      cancelText: translate('cancel'),
      confirmText: translate('confirm'),
      helpText: translate(
        first ? 'search_first_release' : 'search_last_release',
      ),
    );
    if (!context.mounted || selected == null) return;
    if (first) {
      _update(firstReleaseDate: (selected,));
    } else {
      _update(lastReleaseDate: (selected,));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = MaterialLocalizations.of(context);
    const subtitleValues = [null, false, true];
    final subtitleLabels = [
      translate('search_filter_any'),
      translate('search_has_no_subtitle'),
      translate('search_has_subtitle'),
    ];
    const listenStatusValues = <WorkListenStatus?>[
      null,
      ...WorkListenStatus.values,
    ];
    final listenStatusLabels = <String>[
      translate('search_filter_any'),
      for (final status in WorkListenStatus.values)
        translate(workListenStatusTranslationKey(status)),
    ];
    final theme = Theme.of(context);

    Widget title(String key) => Text(translate(key), style: titleStyle);

    // Natural rows size each wheel to its content instead of splitting the row
    // evenly; only the last one may shrink its title to wrap when space runs out.
    Widget wheel({
      required String key,
      required int selected,
      required int itemCount,
      required String Function(int) labelAt,
      required ValueChanged<int> onSelected,
      bool natural = false,
      bool shrinkTitle = false,
    }) {
      final wheelBox = Semantics(
        label: translate(key),
        child: SizedBox(
          key: ValueKey(key),
          height: 84,
          child: AppFixedExtentWheel(
            value: selected,
            itemCount: itemCount,
            labelAt: labelAt,
            onChanged: onSelected,
            itemExtent: 30,
            fontSize: 16,
          ),
        ),
      );
      if (!natural) {
        return Expanded(
          child: Row(
            children: [
              Flexible(child: title(key)),
              const SizedBox(width: 8),
              Expanded(child: wheelBox),
            ],
          ),
        );
      }
      final content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          shrinkTitle ? Flexible(child: title(key)) : title(key),
          const SizedBox(width: 8),
          SizedBox(width: 48, child: wheelBox),
        ],
      );
      return shrinkTitle ? Flexible(child: content) : content;
    }

    Widget endpoint({
      required String key,
      required String label,
      required String? value,
      required VoidCallback pick,
      required VoidCallback clear,
    }) {
      final radius = BorderRadius.circular(
        AppDesignTokens.of(context).radiusControl,
      );
      return Row(
        children: [
          Expanded(
            child: Tooltip(
              message: value == null ? label : '$label · $value',
              child: AppEntryInkWell(
                key: ValueKey(key),
                borderRadius: radius,
                onTap: pick,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    value ?? label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          ),
          if (value != null)
            IconButton(
              onPressed: clear,
              tooltip: translate('clear'),
              icon: const Icon(Icons.close_rounded, size: 16),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(
                width: 40,
                height: 40,
              ),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      );
    }

    Widget range(String key, Widget start, Widget end) => Row(
      children: [
        Expanded(flex: 3, child: title(key)),
        const SizedBox(width: 8),
        Expanded(flex: 4, child: start),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: ExcludeSemantics(child: Text('–')),
        ),
        Expanded(flex: 4, child: end),
      ],
    );

    const gap = SizedBox(height: 8);
    Widget card(Widget child) => DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(
          AppDesignTokens.of(context).radiusControl,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: child,
      ),
    );

    String? durationLabel(Duration? value) => value == null
        ? null
        : translate(
            'minutes_duration',
          ).replaceAll('{count}', locale.formatDecimal(value.inMinutes));

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          card(
            Row(
              children: [
                wheel(
                  key: 'search_subtitle_filter',
                  selected: subtitleValues.indexOf(filters.hasSubtitle),
                  itemCount: subtitleValues.length,
                  labelAt: (index) => subtitleLabels[index],
                  onSelected: (index) =>
                      _update(subtitle: (subtitleValues[index],)),
                ),
                const SizedBox(width: 16),
                wheel(
                  key: 'search_minimum_rating',
                  selected: ((filters.minimumRating ?? 0) * 10).round(),
                  itemCount: 51,
                  labelAt: _ratingLabel,
                  onSelected: (index) =>
                      _update(rating: (index == 0 ? null : index / 10,)),
                ),
              ],
            ),
          ),
          gap,
          card(
            Row(
              children: [
                wheel(
                  key: 'search_listen_status',
                  selected: listenStatusValues
                      .indexOf(filters.listenStatus)
                      .clamp(0, listenStatusValues.length - 1),
                  itemCount: listenStatusValues.length,
                  labelAt: (index) => listenStatusLabels[index],
                  onSelected: (index) =>
                      _update(listenStatus: (listenStatusValues[index],)),
                  natural: true,
                ),
                const SizedBox(width: 16),
                wheel(
                  key: 'search_minimum_user_rating',
                  selected: (filters.minimumUserRating ?? 0).clamp(0, 5),
                  itemCount: 6,
                  labelAt: _userRatingLabel,
                  onSelected: (index) =>
                      _update(userRating: (index == 0 ? null : index,)),
                  natural: true,
                  shrinkTitle: true,
                ),
              ],
            ),
          ),
          gap,
          card(
            range(
              'search_duration_range',
              endpoint(
                key: 'search_minimum_duration',
                label: translate('search_filter_minimum'),
                value: durationLabel(filters.minimumDuration),
                pick: () => _pickDuration(context, minimum: true),
                clear: () => _update(minimumDuration: (null,)),
              ),
              endpoint(
                key: 'search_maximum_duration',
                label: translate('search_filter_maximum'),
                value: durationLabel(filters.maximumDuration),
                pick: () => _pickDuration(context, minimum: false),
                clear: () => _update(maximumDuration: (null,)),
              ),
            ),
          ),
          gap,
          card(
            range(
              'search_release_range',
              endpoint(
                key: 'search_first_release',
                label: translate('search_filter_earliest'),
                value: filters.firstReleaseDate == null
                    ? null
                    : locale.formatCompactDate(filters.firstReleaseDate!),
                pick: () => _pickDate(context, first: true),
                clear: () => _update(firstReleaseDate: (null,)),
              ),
              endpoint(
                key: 'search_last_release',
                label: translate('search_filter_latest'),
                value: filters.lastReleaseDate == null
                    ? null
                    : locale.formatCompactDate(filters.lastReleaseDate!),
                pick: () => _pickDate(context, first: false),
                clear: () => _update(lastReleaseDate: (null,)),
              ),
            ),
          ),
          gap,
        ],
      ),
    );
  }
}
