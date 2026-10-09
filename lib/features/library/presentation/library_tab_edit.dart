import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/path_display.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/library_entry_editor_service.dart';
import 'library_removal_feedback.dart';

import 'library_edit_tree.dart';
export 'library_management_page.dart' show LibraryManagementPage;

class LibraryEditPage extends ConsumerWidget {
  const LibraryEditPage({
    super.key,
    required this.libraryPath,
    @visibleForTesting this.entryEditorService,
  });
  final String libraryPath;
  @visibleForTesting
  final LibraryEntryEditorService? entryEditorService;
  Future<void> _confirmRemoveLibrary(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final removed = await stageLibraryRemoval(
      context,
      ref,
      targetPath: libraryPath,
      target: LibraryRemovalTarget.library,
    );
    if (removed && context.mounted) await Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: appPageBackgroundColor(context, cs.surface),
      body: LibraryEditTree(
        libraryPath: libraryPath,
        entryEditorService: entryEditorService,
        headerBuilder: (context, searchBar) => TopPageHeader(
          icon: Icons.edit_note_rounded,
          title: i18n.tr('edit_library'),
          titleSuffix: Text(
            PathDisplay.folderName(libraryPath),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          leading: IconButton(
            tooltip: i18n.tr('close'),
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          trailing: IconButton(
            tooltip: i18n.tr('remove_library'),
            onPressed: () => _confirmRemoveLibrary(context, ref),
            icon: Icon(Icons.delete_outline_rounded, color: cs.error),
          ),
          additionalChild: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: searchBar,
          ),
        ),
      ),
    );
  }
}
