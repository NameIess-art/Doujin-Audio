import 'library_tab_edit.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/path_display.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';
import 'library_removal_feedback.dart';

class LibraryManagementPage extends ConsumerWidget {
  const LibraryManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final libraries = ref.watch(
      libraryListUiProvider.select((state) => state.watchedLibraries),
    );
    final removalState = ref.watch(undoableRemovalStateProvider);
    final visibleLibraries = libraries
        .where(
          (libraryPath) =>
              !removalState.isHidden(libraryRemovalKey(libraryPath)),
        )
        .toList(growable: false);
    final headerTopInset = MediaQuery.paddingOf(context).top + 60;
    return Scaffold(
      backgroundColor: cs.surface,
      body: PageHeaderInset(
        topInset: headerTopInset,
        child: Stack(
          children: [
            AppPageContentTransition(
              child: visibleLibraries.isEmpty
                  ? Center(
                      child: Text(
                        i18n.tr('library_manage_empty'),
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        MediaQuery.paddingOf(context).top + 60,
                        16,
                        24,
                      ),
                      itemCount: visibleLibraries.length,
                      itemBuilder: (context, index) {
                        final libraryPath = visibleLibraries[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 6),
                          elevation: 0,
                          color: cs.surfaceContainerHigh,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(
                              buildAppPageRoute<void>(
                                context: context,
                                child: LibraryEditPage(
                                  libraryPath: libraryPath,
                                ),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 8,
                              ),
                              child: ListTile(
                                title: Text(
                                  PathDisplay.folderName(libraryPath),
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    PathDisplay.displayPathFor(libraryPath),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: cs.onSurfaceVariant),
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
                              ),
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
              ),
            ),
          ],
        ),
      ),
    );
  }
}
