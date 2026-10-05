import '../../../app/presentation/app_presentation_providers.dart';
import 'library_removal_feedback.dart';
import '../../player/presentation/playback_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/audio_detail.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';
import 'dlsite_metadata_batch_page.dart';

bool isSelectableLibraryNode(LibraryNode node) =>
    node is FolderNode && node.depth == 0 ||
    node is TrackNode && node.track.isSingle;

String selectionKeyForLibraryNode(LibraryNode node) =>
    PathMatcher.normalize(node.path);

List<LibraryBatchSelection> selectedLibraryNodeSelections(
  List<LibraryNode> nodes,
  Set<String> selectedPaths,
) => nodes
    .where(isSelectableLibraryNode)
    .where((node) => selectedPaths.contains(selectionKeyForLibraryNode(node)))
    .map(LibraryBatchSelection.fromNode)
    .toList(growable: false);

class LibraryBatchSelection {
  const LibraryBatchSelection({
    required this.path,
    required this.firstTrack,
    required this.target,
    required this.removalTarget,
  });

  factory LibraryBatchSelection.fromNode(LibraryNode node) {
    return switch (node) {
      FolderNode() => LibraryBatchSelection(
        path: node.path,
        firstTrack: node.firstTrack,
        target: AudioDetailTarget.libraryRootFolder(node.path),
        removalTarget: LibraryRemovalTarget.folder,
      ),
      TrackNode() => LibraryBatchSelection(
        path: node.path,
        firstTrack: node.track,
        target: AudioDetailTarget.singleAudioFile(node.track.path),
        removalTarget: LibraryRemovalTarget.track,
      ),
      _ => throw StateError('Unexpected library selection.'),
    };
  }

  factory LibraryBatchSelection.fromCategoryEntry(
    AudioLibraryCategoryEntry entry,
  ) => LibraryBatchSelection(
    path: entry.path,
    firstTrack: entry.firstTrack,
    target: entry.target,
    removalTarget: entry.isFolder
        ? LibraryRemovalTarget.folder
        : LibraryRemovalTarget.track,
  );

  final String path;
  final MusicTrack? firstTrack;
  final AudioDetailTarget target;
  final LibraryRemovalTarget removalTarget;
}

Future<void> addLibraryBatchSelectionsToPlaylist({
  required BuildContext context,
  required WidgetRef ref,
  required List<LibraryBatchSelection> selections,
  required VoidCallback exitSelectionMode,
}) async {
  final playback = ref.read(playbackFacadeProvider);
  var addedCount = 0;
  for (final selection in selections) {
    final track = selection.firstTrack;
    if (track != null && await playback.spawnSession(track)) {
      addedCount += 1;
    }
  }
  if (!context.mounted) return;
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  exitSelectionMode();
  showAppSnackBar(
    context,
    addedCount > 0
        ? i18n.tr('batch_added_to_playlist', {'count': addedCount.toString()})
        : i18n.tr('operation_failed_retry'),
    tone: addedCount > 0
        ? AppFeedbackTone.success
        : AppFeedbackTone.destructive,
    icon: addedCount > 0
        ? Icons.playlist_add_check_rounded
        : Icons.error_outline_rounded,
  );
}

Future<void> completeLibraryBatchSelectionsMetadata({
  required BuildContext context,
  required WidgetRef ref,
  required List<LibraryBatchSelection> selections,
  required VoidCallback exitSelectionMode,
}) async {
  final targets = selections.map((selection) => selection.target).toSet();
  if (targets.isEmpty) return;
  exitSelectionMode();
  await Navigator.of(context).push(
    buildAppPageRoute<void>(
      context: context,
      child: DlsiteMetadataBatchPage(
        initialTargets: targets,
        initialScope: DlsiteMetadataBatchScope.all,
      ),
    ),
  );
}

Future<void> toggleLibraryBatchSelectionsPinned({
  required BuildContext context,
  required WidgetRef ref,
  required List<LibraryBatchSelection> selections,
  required VoidCallback exitSelectionMode,
}) async {
  if (selections.isEmpty) return;
  unawaited(
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
  );
  final paths = selections
      .map((selection) => selection.path)
      .toList(growable: false);
  exitSelectionMode();
  await saveSettingsWithFeedback(
    context,
    () => ref.read(settingsRepositoryProvider).toggleLibraryPathsPinned(paths),
  );
}

Future<void> removeLibraryBatchSelections({
  required BuildContext context,
  required WidgetRef ref,
  required List<LibraryBatchSelection> selections,
  required VoidCallback exitSelectionMode,
}) async {
  exitSelectionMode();
  for (final selection in selections) {
    await stageLibraryRemoval(
      context,
      ref,
      targetPath: selection.path,
      target: selection.removalTarget,
    );
  }
}

class VisibleLibraryItem {
  const VisibleLibraryItem({
    required this.node,
    required this.depth,
    this.revealed = true,
    this.animateInitialReveal = false,
    this.isFolderError = false,
    this.errorFolderPath,
  });

  final LibraryNode node;
  final int depth;
  final bool revealed;
  final bool animateInitialReveal;
  final bool isFolderError;
  final String? errorFolderPath;
}

class LibraryBatchSelectionHeader extends StatelessWidget {
  const LibraryBatchSelectionHeader({
    super.key,
    required this.keyPrefix,
    required this.i18n,
    required this.selectedCount,
    required this.onAddToPlaylist,
    required this.onCompleteMetadata,
    this.onTogglePin,
    this.isPinned = false,
    required this.onRemove,
    required this.onExit,
  });

  final String keyPrefix;
  final AppLanguageProvider i18n;
  final int selectedCount;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onCompleteMetadata;
  final VoidCallback? onTogglePin;
  final bool isPinned;
  final VoidCallback? onRemove;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return TopPageHeader(
      key: ValueKey<String>('${keyPrefix}_batch_selection_header'),
      icon: Icons.library_music_rounded,
      topCapsuleTitle: i18n.tr('multi_select'),
      topCapsuleData: i18n.tr('selected_count', {
        'count': selectedCount.toString(),
      }),
      titleWidget: const SizedBox.shrink(),
      leading: HeaderActionPill(
        children: [
          AppHeaderActionTransition(
            child: IconButton(
              key: ValueKey<String>('${keyPrefix}_batch_add_button'),
              onPressed: onAddToPlaylist,
              icon: const Icon(Icons.playlist_add_rounded),
              tooltip: i18n.tr('batch_add_to_playlist'),
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: HeaderActionPill.buttonConstraints,
            ),
          ),
          AppHeaderActionTransition(
            delayIndex: 1,
            child: IconButton(
              key: ValueKey<String>(
                '${keyPrefix}_batch_metadata_action_button',
              ),
              onPressed: onCompleteMetadata,
              icon: const Icon(Icons.library_add_check_rounded),
              tooltip: i18n.tr('batch_metadata'),
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: HeaderActionPill.buttonConstraints,
            ),
          ),
          AppHeaderActionTransition(
            delayIndex: 2,
            child: IconButton(
              key: ValueKey<String>('${keyPrefix}_batch_pin_button'),
              onPressed: onTogglePin,
              icon: isPinned
                  ? const PushPinOffIcon()
                  : const Icon(Icons.push_pin_rounded),
              tooltip: i18n.tr(isPinned ? 'unpin_from_top' : 'pin_to_top'),
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: HeaderActionPill.buttonConstraints,
            ),
          ),
          AppHeaderActionTransition(
            delayIndex: 3,
            child: IconButton(
              key: ValueKey<String>('${keyPrefix}_batch_remove_button'),
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: i18n.tr('remove'),
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: HeaderActionPill.buttonConstraints,
            ),
          ),
        ],
      ),
      trailing: AppHeaderLeadingTransition(
        child: HeaderFloatingButton(
          child: IconButton(
            key: ValueKey<String>('${keyPrefix}_exit_selection_button'),
            onPressed: onExit,
            icon: const Icon(Icons.close_rounded),
            tooltip: i18n.tr('cancel'),
          ),
        ),
      ),
    ).withAppHeaderTransition();
  }
}

void showLibrarySessionCreatedSnack(BuildContext context, String message) {
  showAppSnackBar(
    context,
    message,
    tone: AppFeedbackTone.success,
    icon: Icons.queue_music_rounded,
  );
}
