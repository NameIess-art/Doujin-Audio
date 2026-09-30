import 'dart:io';
import 'package:path/path.dart' as path;

import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../library/application/work_text_service.dart';
import '../domain/asmr_models.dart';
import 'asmr_api_service.dart';
import 'asmr_download_manager.dart';

List<MusicTrack> flattenAsmrPlayableTracks(
  AsmrWork work,
  Iterable<AsmrTrackFile> roots, {
  required Set<String> hiddenTracks,
  bool Function(AsmrTrackFile node)? includeAudioNode,
}) {
  final result = <MusicTrack>[];
  final subtitleByStem = <String, AsmrTrackFile>{};
  final subtitlesByBaseName = <String, List<AsmrTrackFile>>{};

  void indexSubtitles(Iterable<AsmrTrackFile> nodes) {
    for (final node in nodes) {
      if (node.isSubtitle) {
        subtitleByStem.putIfAbsent(node.stemKey, () => node);
        subtitlesByBaseName
            .putIfAbsent(node.baseNameStem, () => <AsmrTrackFile>[])
            .add(node);
      }
      if (node.children.isNotEmpty) {
        indexSubtitles(node.children);
      }
    }
  }

  Map<String, Object?> remoteMetadataForTrack(AsmrTrackFile node) {
    final metadata = Map<String, Object?>.from(work.toJson());
    metadata['trackRelativePath'] = node.relativePath;
    metadata['trackStableKey'] = node.stableKey;
    metadata['trackDirectoryPath'] = path.dirname(node.relativePath);
    final subtitle =
        subtitleByStem[node.stemKey] ??
        switch (subtitlesByBaseName[node.baseNameStem]) {
          final List<AsmrTrackFile> matches when matches.length == 1 =>
            matches.first,
          _ => null,
        };
    final subtitleUrl = (subtitle?.streamUrl ?? subtitle?.downloadUrl ?? '')
        .trim();
    if (subtitleUrl.isEmpty) {
      return metadata;
    }
    metadata['subtitleUrl'] = subtitleUrl;
    metadata['subtitleExtension'] = subtitle!.resolvedExtension;
    metadata['subtitleSourcePath'] = subtitle.relativePath;
    metadata['subtitleTitle'] = subtitle.title;
    return metadata;
  }

  indexSubtitles(roots);

  void visit(Iterable<AsmrTrackFile> nodes) {
    for (final node in nodes) {
      if (node.isAudio) {
        if (hiddenTracks.contains('${work.id}:${node.stableKey}')) continue;
        if (includeAudioNode != null && !includeAudioNode(node)) {
          continue;
        }
        final usesOfficialMedia = <String?>[
          node.streamUrl,
          node.downloadUrl,
          node.lowQualityUrl,
        ].any(AsmrApiService.isOfficialMediaUrl);
        final track = node.toMusicTrack(
          groupTitleOverride: work.title,
          remoteCoverUrl: work.preferredCoverUrl,
          remoteMetadataKind: 'asmr.one',
          remoteMetadata: remoteMetadataForTrack(node),
          preferredPlaybackUrls: usesOfficialMedia
              ? AsmrApiService.mediaStreamUrlsForHash(node.hash)
              : const <String>[],
        );
        if (track.path.isNotEmpty) {
          result.add(track);
        }
        continue;
      }
      if (node.children.isNotEmpty) {
        visit(node.children);
      }
    }
  }

  visit(roots);
  return result;
}

List<WorkTextFile> collectAsmrWorkTextFiles(
  Iterable<AsmrTrackFile> tree, {
  AsmrDownloadManager? downloadManager,
  int? workId,
}) {
  final result = <WorkTextFile>[];
  final task = workId != null ? downloadManager?.getTask(workId) : null;
  final destinationRoot = task?.destinationRoot;
  final workFolderName = task?.workFolderName;

  void visit(Iterable<AsmrTrackFile> nodes) {
    for (final node in nodes) {
      if (node.isFolder) {
        visit(node.children);
      } else if (node.isText) {
        String? localPath;
        if (destinationRoot != null &&
            destinationRoot.isNotEmpty &&
            workFolderName != null &&
            workFolderName.isNotEmpty &&
            !PathMatcher.isContentUri(destinationRoot)) {
          final candidate = path.join(
            destinationRoot,
            workFolderName,
            node.relativePath,
          );
          if (File(candidate).existsSync()) {
            localPath = candidate;
          }
        }

        final usesOfficialMedia = <String?>[
          node.streamUrl,
          node.downloadUrl,
          node.lowQualityUrl,
        ].any(AsmrApiService.isOfficialMediaUrl);

        final urls = <String>[
          node.downloadUrl ?? '',
          node.streamUrl ?? '',
          if (usesOfficialMedia)
            ...AsmrApiService.mediaDownloadUrlsForHash(node.hash),
          if (usesOfficialMedia)
            ...AsmrApiService.mediaStreamUrlsForHash(node.hash),
        ].where((url) => url.trim().isNotEmpty).toSet().toList(growable: false);

        final resolvedPath = localPath ?? urls.firstOrNull ?? '';
        if (resolvedPath.isNotEmpty) {
          result.add(
            WorkTextFile(
              name: node.title,
              relativePath: node.relativePath,
              path: resolvedPath,
              fallbackUrls: localPath == null
                  ? urls.skip(1).toList(growable: false)
                  : const [],
            ),
          );
        }
      }
    }
  }

  visit(tree);
  return result;
}
