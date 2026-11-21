import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../domain/audio_library_category.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/search_highlight.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../../core/widgets/unified_popup_menu.dart';

class DlsiteMetadataWorkPickerPage extends ConsumerStatefulWidget {
  const DlsiteMetadataWorkPickerPage({
    super.key,
    required this.entries,
    required this.initialSelection,
  });

  final List<AudioLibraryCategoryEntry> entries;
  final List<AudioLibraryCategoryEntry> initialSelection;

  @override
  ConsumerState<DlsiteMetadataWorkPickerPage> createState() =>
      _DlsiteMetadataWorkPickerPageState();
}

class _DlsiteMetadataWorkPickerPageState
    extends ConsumerState<DlsiteMetadataWorkPickerPage> {
  late final Set<String> _selectedIds;
  String _searchQuery = '';
  late final TextEditingController _searchController;
  late List<AudioLibraryCategoryEntry> _filteredEntries;
  late Map<String, int> _filteredIndexByKey;

  @override
  void initState() {
    super.initState();
    _selectedIds = widget.initialSelection
        .map((e) => AudioLibraryCategorySnapshot.targetKey(e.target))
        .toSet();
    _searchController = TextEditingController();
    _updateFilteredEntries();
  }

  @override
  void didUpdateWidget(covariant DlsiteMetadataWorkPickerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.entries, widget.entries)) {
      _updateFilteredEntries();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSelection(String id, bool? selected) {
    setState(() {
      if (selected == true) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
    });
  }

  void _updateFilteredEntries() {
    final query = _searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.entries
        : widget.entries
              .where((e) {
                final title =
                    (e.detail.workTitle.isNotEmpty
                            ? e.detail.workTitle
                            : e.title)
                        .toLowerCase();
                final rjCode = e.detail.rjCode.toLowerCase();
                return title.contains(query) || rjCode.contains(query);
              })
              .toList(growable: false);
    _filteredEntries = filtered;
    _filteredIndexByKey = <String, int>{
      for (var i = 0; i < filtered.length; i++) ...{
        'batch_metadata_picker_${AudioLibraryCategorySnapshot.targetKey(filtered[i].target)}':
            i,
        'batch_metadata_picker_row_${AudioLibraryCategorySnapshot.targetKey(filtered[i].target)}':
            i,
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final filtered = _filteredEntries;
    final cs = Theme.of(context).colorScheme;

    final topInset = AppPageHeaderMetrics.contentTopInset(context);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SearchHighlightScope(
        query: _searchQuery,
        child: PageHeaderInset(
          topInset: topInset,
          child: Stack(
            children: [
              Positioned.fill(
                child: AppPageContentTransition(
                  child: ListView.builder(
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: AppPageHeaderMetrics.contentTopInset(context),
                      bottom: 78 +
                          MediaQuery.paddingOf(context).bottom +
                          MobileOverlayInset.of(context),
                    ),
                    itemCount: filtered.isEmpty ? 1 : filtered.length,
                    findChildIndexCallback: filtered.isEmpty
                        ? null
                        : (key) => key is ValueKey<String>
                              ? _filteredIndexByKey[key.value]
                              : null,
                    itemBuilder: (context, index) {
                      if (filtered.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 80),
                          child: Center(
                            child: AppEmptyState(
                              icon: Icons.search_off_rounded,
                              title: i18n.tr('no_results_found'),
                              message: i18n.tr('search_no_match'),
                            ),
                          ),
                        );
                      }
                      final entry = filtered[index];
                      final id = AudioLibraryCategorySnapshot.targetKey(
                        entry.target,
                      );
                      final selected = _selectedIds.contains(id);
                      return MergeSemantics(
                        key: ValueKey<String>('batch_metadata_picker_row_$id'),
                        child: FileTreeRow(
                          key: ValueKey<String>('batch_metadata_picker_$id'),
                          minHeight: 48,
                          verticalPadding: 2,
                          reserveSubtitleSpace: true,
                          title: entry.detail.workTitle.isNotEmpty
                              ? entry.detail.workTitle
                              : entry.title,
                          subtitle: entry.detail.rjCode.isNotEmpty
                              ? entry.detail.rjCode
                              : null,
                          trailing: Checkbox(
                            value: selected,
                            visualDensity: VisualDensity.compact,
                            onChanged: (val) => _toggleSelection(id, val),
                          ),
                          onTap: () => _toggleSelection(id, !selected),
                        ),
                      );
                    },
                  ).withWindowsSmoothScroll(),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: TopPageHeader(
                  key: const ValueKey<String>('batch_metadata_picker_header'),
                  leading: const AppHeaderBackButton(),
                  titleWidget: HeaderFloatingSurface(
                    key: const ValueKey<String>('batch_metadata_picker_search'),
                    child: TextSelectionTheme(
                      data: TextSelectionThemeData(
                        cursorColor: cs.primary,
                        selectionColor: cs.primary.withValues(alpha: 0.24),
                        selectionHandleColor: cs.primary,
                      ),
                      child: TextField(
                        contextMenuBuilder: buildAppEditableTextMenu,
                        controller: _searchController,
                        cursorColor: cs.primary,
                        textInputAction: TextInputAction.search,
                        textAlignVertical: TextAlignVertical.center,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(fontSize: 14),
                        decoration: InputDecoration(
                          filled: false,
                          fillColor: Colors.transparent,
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            color: cs.onSurfaceVariant,
                            size: 20,
                          ),
                          prefixIconConstraints: const BoxConstraints.tightFor(
                            width: 38,
                            height: 38,
                          ),
                          hintText: i18n.tr('batch_metadata_picker_search'),
                          hintStyle: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontSize: 14,
                              ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.only(right: 10),
                          suffixIcon: _searchQuery.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: i18n.tr('clear'),
                                  icon: const Icon(
                                    Icons.clear_rounded,
                                    size: 18,
                                  ),
                                  color: cs.onSurfaceVariant,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 38,
                                    height: 38,
                                  ),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                      _updateFilteredEntries();
                                    });
                                  },
                                ),
                          suffixIconConstraints: const BoxConstraints.tightFor(
                            width: 38,
                            height: 38,
                          ),
                          isDense: true,
                        ),
                        onChanged: (val) {
                          setState(() {
                            _searchQuery = val;
                            _updateFilteredEntries();
                          });
                        },
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 16,
                bottom: 16 +
                    MediaQuery.paddingOf(context).bottom +
                    MobileOverlayInset.of(context),
                child: AppPageContentTransition(
                  child: HeaderFloatingActionPill(
                    pillKey: const ValueKey<String>('batch_metadata_picker_done'),
                    icon: Icons.check_rounded,
                    label: i18n.tr('batch_metadata_picker_done', {
                      'count': _selectedIds.length,
                    }),
                    onTap: () {
                      final result = widget.entries
                          .where(
                            (e) => _selectedIds.contains(
                              AudioLibraryCategorySnapshot.targetKey(e.target),
                            ),
                          )
                          .toList(growable: false);
                      Navigator.of(context).pop(result);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
