import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/work_detail_navigation.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../app/localization/app_language_provider.dart';
import '../../../core/ui/interaction_deferred_stream.dart';
import '../../library/presentation/work_detail_entries.dart';
import '../../library/presentation/work_image_viewer_page.dart';
import '../application/asmr_library_controller.dart';
import '../../library/presentation/work_detail_page.dart';
import '../domain/asmr_models.dart';
import 'asmr_download_page.dart';
import 'asmr_error_text.dart';
import 'asmr_favorite_action.dart';
import 'asmr_providers.dart';

Future<void> showAsmrWorkDetailSheet(
  BuildContext context,
  AsmrWork work, {
  bool returnToMain = false,
}) => WorkDetailNavigation.openFrom(
  context,
  ('asmr', work.workKey),
  (routeContext) => buildAppPageRoute<void>(
    context: routeContext,
    settings: const RouteSettings(name: workDetailRouteName),
    separateHeader: true,
    child: buildAsmrWorkDetailPage(work: work),
  ),
  returnToMain: returnToMain,
);

WorkDetailPage buildAsmrWorkDetailPage({Key? key, required AsmrWork work}) =>
    WorkDetailPage.forRemote(key: key, work: _AsmrWorkDetail(work));

final _workFavoriteProvider = StreamProvider.autoDispose.family<bool?, String>((
  ref,
  workKey,
) {
  final controller = ref.watch(asmrLibraryControllerProvider);
  if (controller == null) return Stream.value(null);
  return interactionDeferredListenableStream(
    source: controller,
    read: () => controller.isFavorite(workKey),
  ).distinct();
});

class _AsmrWorkDetail implements RemoteWorkDetail {
  const _AsmrWorkDetail(this.work);

  final AsmrWork work;

  @override
  String get title => work.title;
  @override
  String get workCode => work.workCode;
  @override
  String get rjCode => work.rjCode;
  @override
  String get circleName => work.circleName;
  @override
  bool get hasSubtitle => work.hasSubtitle;
  @override
  List<String> get voiceActors => work.voiceActors;
  @override
  List<String> get tags => work.tags;
  @override
  String? get preferredCoverUrl => work.preferredCoverUrl;
  @override
  List<String?> get alternateCoverUrls => [work.thumbnailUrl, work.coverUrl];

  AsmrLibraryController _controller(WidgetRef ref) =>
      ref.read(asmrLibraryControllerProvider) ??
      (throw StateError('asmr_controller_unavailable'));

  @override
  WorkDirectorySource? cachedDirectory(WidgetRef ref) {
    final tree = ref
        .read(asmrLibraryControllerProvider)
        ?.trackTreeFor(work.workKey);
    return tree == null ? null : AsmrWorkDirectoryInput(tree);
  }

  @override
  Future<void> initialize(WidgetRef ref) =>
      _controller(ref).initializeForVisiblePage();

  @override
  Future<WorkDirectorySource> refreshDirectory(WidgetRef ref) async =>
      AsmrWorkDirectoryInput(
        await _controller(ref).ensureTrackTree(work, forceRefresh: true),
      );

  @override
  String directoryErrorLabel(AppLanguageProvider i18n, Object error) =>
      localizedAsmrCatalogErrorText(i18n, error);

  @override
  bool isFavorite(WidgetRef ref) =>
      ref.watch(_workFavoriteProvider(work.workKey)).value ??
      ref.read(asmrLibraryControllerProvider)?.isFavorite(work.workKey) ??
      work.isFavorite;

  @override
  Future<void> toggleFavorite(BuildContext context, WidgetRef ref) async {
    await setAsmrWorksFavoriteWithFeedback(context, ref, [work]);
  }

  @override
  Future<void> download(BuildContext context) async {
    await Navigator.of(context).push<AsmrDownloadPageResult>(
      buildAppPageRoute<AsmrDownloadPageResult>(
        context: context,
        child: AsmrDownloadPage(work: work),
      ),
    );
  }

  @override
  Future<bool> play(WidgetRef ref, WorkEntryItem item) =>
      ref
          .read(asmrPlaybackCoordinatorProvider)
          ?.playDirectTrack(work, item.remoteReference as AsmrTrackFile) ??
      (throw StateError('Playback is unavailable.'));

  @override
  Future<bool> addToPlaylist(WidgetRef ref, WorkEntryItem item) =>
      ref
          .read(asmrPlaybackCoordinatorProvider)
          ?.addTrackToPlaylist(work, item.remoteReference as AsmrTrackFile) ??
      (throw StateError('Playback is unavailable.'));
}

class AsmrWorkDirectoryInput implements WorkDirectorySource {
  const AsmrWorkDirectoryInput(this.tree);

  final List<AsmrTrackFile> tree;

  @override
  WorkDirectorySnapshot? get resolved => resolvedWorkDirectory(tree, tree);

  @override
  Future<WorkDirectorySnapshot> load() =>
      prepareWorkDirectory(tree, tree, tree, buildAsmrWorkDirectorySnapshot);
}

WorkDirectorySnapshot buildAsmrWorkDirectorySnapshot(List<AsmrTrackFile> tree) {
  final directories = <String, List<WorkEntryItem>>{'': []};
  final images = <WorkImageItem>[];
  var hasSubtitle = false;

  String childPath(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  final texts = collectAsmrWorkTextFiles(tree);
  final textsByPath = {for (final text in texts) text.relativePath: text};
  void remoteTree(List<AsmrTrackFile> nodes, String path) {
    final entries = directories.putIfAbsent(path, () => []);
    for (final node in nodes) {
      hasSubtitle |= node.isSubtitle;
      // Japanese ASMR wraps its catalog in a site-name folder. It is not a
      // work directory; keep the source nodes and paths for playback/downloads.
      if (path.isEmpty && node.isFolder && node.title == 'japaneseasmr.com') {
        remoteTree(node.children, path);
        continue;
      }
      if (node.isFolder) {
        entries.add(
          WorkEntryItem(
            name: node.title,
            relativePath: node.relativePath,
            type: WorkEntryType.folder,
            remoteReference: node,
          ),
        );
        remoteTree(node.children, childPath(path, node.title));
      } else if (node.isAudio) {
        entries.add(
          WorkEntryItem(
            name: node.displayTitle,
            relativePath: node.relativePath,
            type: WorkEntryType.audio,
            remoteExtension: node.resolvedExtension,
            isRemoteVideo: node.isVideo,
            fullPathOrUrl: node.streamUrl ?? '',
            duration: node.duration,
            fileSizeBytes: node.size,
            remoteReference: node,
          ),
        );
      } else if (node.isText) {
        entries.add(
          WorkEntryItem(
            name: node.title,
            relativePath: node.relativePath,
            type: WorkEntryType.text,
            remoteExtension: node.resolvedExtension,
            textFile: textsByPath[node.relativePath],
            fileSizeBytes: node.size,
            remoteReference: node,
          ),
        );
      } else if (node.isImage) {
        final image = WorkImageItem(
          name: node.title,
          path: node.streamUrl ?? node.downloadUrl ?? '',
          relativePath: node.relativePath,
        );
        images.add(image);
        entries.add(
          WorkEntryItem(
            name: image.name,
            relativePath: image.relativePath,
            type: WorkEntryType.image,
            remoteExtension: node.resolvedExtension,
            fileSizeBytes: node.size,
            fullPathOrUrl: image.path,
            remoteReference: node,
            imageItem: image,
          ),
        );
      }
    }
  }

  remoteTree(tree, '');
  return WorkDirectorySnapshot(
    directories: directories,
    images: images,
    texts: texts,
    hasSubtitle: hasSubtitle,
  );
}
