import 'library_tab_edit.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/path_display.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/file_tree_row.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/search_highlight.dart';
import '../../../core/widgets/top_page_header.dart';
import 'library_removal_feedback.dart';

class LibraryManagementPage extends ConsumerStatefulWidget {
  const LibraryManagementPage({super.key});

  @override
  ConsumerState<LibraryManagementPage> createState() =>
      _LibraryManagementPageState();
}

class _LibraryManagementPageState extends ConsumerState<LibraryManagementPage> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final libraries = ref.watch(
      libraryListUiProvider.select((state) => state.watchedLibraries),
    );
    final removalState = ref.watch(undoableRemovalStateProvider);
    final query = _searchController.text.trim().toLowerCase();
    final visibleLibraries = libraries
        .where(
          (libraryPath) =>
              !removalState.isHidden(libraryRemovalKey(libraryPath)) &&
              PathDisplay.displayPathFor(
                libraryPath,
              ).toLowerCase().contains(query),
        )
        .toList(growable: false);
    final headerTopInset = MediaQuery.paddingOf(context).top + 98;
    return Scaffold(
      backgroundColor: appPageBackgroundColor(context, cs.surface),
      body: SearchHighlightScope(
        query: _searchController.text,
        child: PageHeaderInset(
          topInset: headerTopInset,
          child: Stack(
            children: [
              AppPageContentTransition(
                child: visibleLibraries.isEmpty
                    ? Center(
                        child: Text(
                          i18n.tr(
                            query.isEmpty
                                ? 'library_manage_empty'
                                : 'no_search_results',
                          ),
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          headerTopInset,
                          16,
                          24,
                        ),
                        itemCount: visibleLibraries.length,
                        itemBuilder: (context, index) {
                          final libraryPath = visibleLibraries[index];
                          return FileTreeRow(
                            surfaceKey: ValueKey(
                              'library-management-surface:$libraryPath',
                            ),
                            title: PathDisplay.folderName(libraryPath),
                            subtitle: PathDisplay.displayPathFor(libraryPath),
                            subtitleMaxLines: 2,
                            minHeight: 64,
                            verticalPadding: 2,
                            isFolder: true,
                            leading: const Icon(
                              AppDesignTokens.folderIcon,
                              size: AppDesignTokens.fileEntryIconSize,
                              color: AppDesignTokens.folderIconColor,
                            ),
                            onTap: () => Navigator.of(context).push(
                              buildAppPageRoute<void>(
                                context: context,
                                child: LibraryEditPage(
                                  libraryPath: libraryPath,
                                ),
                              ),
                            ),
                            trailing: IconButton(
                              tooltip: i18n.tr('remove_library'),
                              onPressed: () => stageLibraryRemoval(
                                context,
                                ref,
                                targetPath: libraryPath,
                                target: LibraryRemovalTarget.library,
                              ),
                              icon: Icon(
                                Icons.delete_outline_rounded,
                                color: cs.error.withValues(alpha: 0.8),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: TopPageHeader(
                  icon: Icons.edit_note_rounded,
                  title: i18n.tr('edit_library'),
                  leading: IconButton(
                    tooltip: i18n.tr('close'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  additionalChild: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                    child: HeaderFloatingSurface(
                      key: const ValueKey('library-management-search'),
                      child: TextField(
                        controller: _searchController,
                        textInputAction: TextInputAction.search,
                        textAlignVertical: TextAlignVertical.center,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(fontSize: 13.5),
                        decoration: InputDecoration(
                          filled: false,
                          fillColor: Colors.transparent,
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            color: cs.onSurfaceVariant,
                            size: 18,
                          ),
                          prefixIconConstraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 38,
                          ),
                          suffixIcon: _searchController.text.isEmpty
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
                                    width: 36,
                                    height: 38,
                                  ),
                                  onPressed: () =>
                                      setState(_searchController.clear),
                                ),
                          hintText: i18n.tr('search_library_placeholder'),
                          hintStyle: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontSize: 13.5,
                              ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.only(right: 12),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
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
