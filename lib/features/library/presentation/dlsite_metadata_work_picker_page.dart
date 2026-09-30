import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../domain/audio_library_category.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';

class DlsiteMetadataWorkPickerPage extends StatefulWidget {
  const DlsiteMetadataWorkPickerPage({
    super.key,
    required this.entries,
    required this.initialSelection,
  });

  final List<AudioLibraryCategoryEntry> entries;
  final List<AudioLibraryCategoryEntry> initialSelection;

  @override
  State<DlsiteMetadataWorkPickerPage> createState() =>
      _DlsiteMetadataWorkPickerPageState();
}

class _DlsiteMetadataWorkPickerPageState
    extends State<DlsiteMetadataWorkPickerPage> {
  late final Set<String> _selectedIds;
  String _searchQuery = '';
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _selectedIds = widget.initialSelection
        .map((e) => AudioLibraryCategorySnapshot.targetKey(e.target))
        .toSet();
    _searchController = TextEditingController();
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

  List<AudioLibraryCategoryEntry> get _filteredEntries {
    if (_searchQuery.trim().isEmpty) return widget.entries;
    final query = _searchQuery.trim().toLowerCase();
    return widget.entries
        .where((e) {
          final title =
              (e.detail.workTitle.isNotEmpty ? e.detail.workTitle : e.title)
                  .toLowerCase();
          final rjCode = e.detail.rjCode.toLowerCase();
          return title.contains(query) || rjCode.contains(query);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final filtered = _filteredEntries;
    final cs = Theme.of(context).colorScheme;

    final topInset = AppPageHeaderMetrics.contentTopInset(context);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: PageHeaderInset(
        topInset: topInset,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                child: ListView.builder(
                  padding: EdgeInsets.only(
                    top: AppPageHeaderMetrics.contentTopInset(context),
                    bottom: 78 + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final entry = filtered[index];
                    final id = AudioLibraryCategorySnapshot.targetKey(
                      entry.target,
                    );
                    final selected = _selectedIds.contains(id);
                    return CheckboxListTile(
                      value: selected,
                      onChanged: (val) => _toggleSelection(id, val),
                      title: Text(
                        entry.detail.workTitle.isNotEmpty
                            ? entry.detail.workTitle
                            : entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: entry.detail.rjCode.isNotEmpty
                          ? Text(entry.detail.rjCode)
                          : null,
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: const ValueKey<String>('batch_metadata_picker_header'),
                leading: const BackButton(),
                titleWidget: HeaderFloatingSurface(
                  key: const ValueKey<String>('batch_metadata_picker_search'),
                  child: TextSelectionTheme(
                    data: TextSelectionThemeData(
                      cursorColor: cs.primary,
                      selectionColor: cs.primary.withValues(alpha: 0.24),
                      selectionHandleColor: cs.primary,
                    ),
                    child: TextField(
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
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                color: cs.onSurfaceVariant,
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {
                                    _searchQuery = '';
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
                        });
                      },
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              child: AppPageContentTransition(
                child: HeaderFloatingSurface(
                  key: const ValueKey<String>('batch_metadata_picker_done'),
                  height: 46,
                  radius: 23,
                  padding: EdgeInsets.zero,
                  child: Material(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(23),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(23),
                      onTap: () {
                        final result = widget.entries
                            .where(
                              (e) => _selectedIds.contains(
                                AudioLibraryCategorySnapshot.targetKey(
                                  e.target,
                                ),
                              ),
                            )
                            .toList(growable: false);
                        Navigator.of(context).pop(result);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: cs.onPrimary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              i18n.tr('batch_metadata_picker_done', {
                                'count': _selectedIds.length,
                              }),
                              style: TextStyle(
                                color: cs.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
