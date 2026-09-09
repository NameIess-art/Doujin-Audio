import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/undoable_removal_service.dart';
import '../../../core/widgets/app_feedback.dart';
import 'library_providers.dart';

enum LibraryRemovalTarget { track, folder, library }

UndoableRemovalKey libraryRemovalKey(String targetPath) =>
    UndoableRemovalKey('library', PathMatcher.normalize(targetPath));

Future<bool> stageLibraryRemoval(
  BuildContext context,
  WidgetRef ref, {
  required String targetPath,
  required LibraryRemovalTarget target,
}) async {
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  final messageKey = switch (target) {
    LibraryRemovalTarget.track => 'audio_removed',
    LibraryRemovalTarget.folder => 'folder_removed',
    LibraryRemovalTarget.library => 'library_removed',
  };
  final library = ref.read(libraryFacadeProvider);
  return showUndoableRemovalFeedback(
    context,
    service: ref.read(undoableRemovalServiceProvider),
    action: UndoableRemovalAction(
      key: libraryRemovalKey(targetPath),
      commit: () async {
        final result = target == LibraryRemovalTarget.track
            ? await library.removeTrack(targetPath)
            : await library.removeFolder(targetPath);
        if (result == null) throw StateError('Library removal failed.');
      },
      undo: () {},
    ),
    message: i18n.tr(messageKey),
    batchMessage: (count) => i18n.tr('items_removed_count', {'count': count}),
    undoLabel: i18n.tr('undo'),
    failureMessage: i18n.tr('removal_failed'),
  );
}
