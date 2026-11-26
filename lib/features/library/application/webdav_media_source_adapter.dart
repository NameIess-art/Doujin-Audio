import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/network/webdav_client.dart';
import '../../asmr/domain/asmr_models.dart';
import '../data/audio_detail_json_codec.dart';
import '../domain/remote_media_source.dart';
import 'library_facade.dart' show AudioDetailRenameException;

const Set<String> _webDavSubtitleExts = <String>{
  '.lrc',
  '.vtt',
  '.srt',
  '.ass',
  '.ssa',
};

const Set<String> _webDavImageExts = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.avif',
  '.heic',
  '.heif',
};

const Set<String> _webDavTextExts = <String>{
  '.txt',
  '.md',
  '.markdown',
  '.pdf',
};

final RegExp _leadingBracketCirclePattern = RegExp(
  r'^\s*\[([^\]]+)\]\s*(.+)$',
);

final RegExp _illegalRemoteEntryNamePattern = RegExp(r'[\\/:*?"<>|\x00]');

class WebDavMediaSourceAdapter {
  const WebDavMediaSourceAdapter();

  static const AudioDetailJsonCodec _jsonCodec = AudioDetailJsonCodec();

  Future<List<RemoteLibraryWork>> fetchWorks({
    required RemoteMediaSource source,
    required WebDavClient client,
  }) async {
    final topEntries = await client.listDirectory(client.baseUri);
    final directories = topEntries
        .where(
          (e) =>
              e.isDirectory &&
              !e.name.startsWith('.') &&
              e.name != 'DoujinAudioSync',
        )
        .toList(growable: false);

    final excludedSet = source.excludedWorkIds.toSet();
    final pinnedSet = source.pinnedWorkIds.toSet();
    final works = <RemoteLibraryWork>[];
    final nonRjDirs = <WebDavEntry>[];

    for (final dir in directories) {
      final parsed = parseFolderWorkMetadata(dir.name);
      if (parsed.rjCode.isNotEmpty) {
        works.add(
          _workFromEntry(
            source.id,
            dir,
            parsed,
            isPinned: pinnedSet.contains(_stableWorkId(dir.uri.toString())),
          ),
        );
      } else {
        nonRjDirs.add(dir);
      }
    }

    // Support 1-level category directories (e.g. /WebDAV/ASMR/RJ123456) while
    // keeping non-RJ direct work folders if they have no child work folders.
    if (nonRjDirs.isNotEmpty) {
      final inspectLimit = nonRjDirs.length <= 12 ? nonRjDirs.length : 0;
      for (var i = 0; i < nonRjDirs.length; i++) {
        final dir = nonRjDirs[i];
        if (i < inspectLimit) {
          try {
            final children = await client.listDirectory(dir.uri);
            final childDirs = children
                .where((c) => c.isDirectory && !c.name.startsWith('.'))
                .toList(growable: false);
            final rjChildDirs = childDirs
                .where((c) => AudioDetail.findRjCodeInText(c.name) != null)
                .toList(growable: false);
            if (rjChildDirs.isNotEmpty) {
              for (final child in childDirs) {
                final childId = _stableWorkId(child.uri.toString());
                works.add(
                  _workFromEntry(
                    source.id,
                    child,
                    parseFolderWorkMetadata(child.name),
                    isPinned: pinnedSet.contains(childId),
                  ),
                );
              }
              continue;
            }
            final coverCandidate = _pickPreferredCoverUrl(children);
            final hasSub = children.any(
              (c) =>
                  !c.isDirectory &&
                  _webDavSubtitleExts.contains(
                    path.posix.extension(c.name).toLowerCase(),
                  ),
            );
            final dirId = _stableWorkId(dir.uri.toString());
            works.add(
              _workFromEntry(
                source.id,
                dir,
                parseFolderWorkMetadata(dir.name),
                coverUrl: coverCandidate,
                hasSubtitle: hasSub,
                isPinned: pinnedSet.contains(dirId),
              ),
            );
            continue;
          } on Object {
            // Fall through and keep the top-level folder entry.
          }
        }
        final dirId = _stableWorkId(dir.uri.toString());
        works.add(
          _workFromEntry(
            source.id,
            dir,
            parseFolderWorkMetadata(dir.name),
            isPinned: pinnedSet.contains(dirId),
          ),
        );
      }
    }

    // If root itself directly holds loose audio/video files and no subfolders.
    if (works.isEmpty) {
      final looseMedia = topEntries
          .where((e) => !e.isDirectory && isSupportedMediaFile(e.name))
          .toList(growable: false);
      if (looseMedia.isNotEmpty) {
        final rootWorkId = _stableWorkId(client.baseUri.toString());
        works.add(
          RemoteLibraryWork(
            sourceId: source.id,
            workId: rootWorkId,
            rjCode: AudioDetail.findRjCodeInText(source.name) ?? '',
            title: source.name,
            folderName: source.name,
            circleName: '',
            trackCount: looseMedia.length,
            isPinned: pinnedSet.contains(rootWorkId),
            coverUrl: _pickPreferredCoverUrl(topEntries),
            directoryUri: client.baseUri.toString(),
          ),
        );
      }
    }

    final visibleWorks = works
        .where((w) => !excludedSet.contains(w.workId))
        .toList(growable: false);

    // Hydrate `doujin-audio.json` metadata & user reviews when present in folders.
    if (visibleWorks.length <= 120) {
      final hydrated = List<RemoteLibraryWork>.of(visibleWorks);
      const concurrency = 4;
      for (var offset = 0; offset < hydrated.length; offset += concurrency) {
        final end = (offset + concurrency).clamp(0, hydrated.length);
        await Future.wait(<Future<void>>[
          for (var idx = offset; idx < end; idx++)
            () async {
              hydrated[idx] = await _hydrateFromFolderJson(
                hydrated[idx],
                client,
              );
            }(),
        ]);
      }
      hydrated.sort((a, b) => compareNatural(a.title, b.title));
      return hydrated;
    }

    visibleWorks.sort((a, b) => compareNatural(a.title, b.title));
    return visibleWorks;
  }

  Future<RemoteLibraryWork> _hydrateFromFolderJson(
    RemoteLibraryWork base,
    WebDavClient client,
  ) async {
    final dirRaw = base.directoryUri;
    if (dirRaw == null || dirRaw.isEmpty) return base;
    try {
      final dirUri = WebDavClient.normalizeDirectoryUri(Uri.parse(dirRaw));
      final jsonBytes = await client.getBytesOrNull(
        dirUri.resolve('doujin-audio.json'),
        maxBytes: 2 * 1024 * 1024,
      );
      if (jsonBytes == null) return base;
      final target = AudioDetailTarget.libraryRootFolder(dirUri.path);
      final detail = _jsonCodec.decode(jsonBytes, target);
      String? resolvedCover = base.coverUrl;
      final relCover = detail.cardCoverPath?.trim() ?? '';
      if (relCover.isNotEmpty && !relCover.contains('://')) {
        final cleanRel = relCover.replaceAll('\\', '/');
        final segments = cleanRel
            .split('/')
            .where((s) => s.isNotEmpty && s != '.' && s != '..')
            .toList(growable: false);
        if (segments.isNotEmpty) {
          resolvedCover = dirUri
              .resolve(segments.map(Uri.encodeComponent).join('/'))
              .toString();
        }
      }
      return base.copyWith(
        rjCode: detail.rjCode.trim().isNotEmpty ? detail.rjCode.trim() : base.rjCode,
        title: detail.workTitle.trim().isNotEmpty
            ? detail.workTitle.trim()
            : base.title,
        circleName: detail.circleName.trim().isNotEmpty
            ? detail.circleName.trim()
            : base.circleName,
        voiceActors: detail.voiceActors.isNotEmpty
            ? detail.voiceActors
            : base.voiceActors,
        tags: detail.tags.isNotEmpty ? detail.tags : base.tags,
        releaseDateMs:
            detail.releaseDate?.millisecondsSinceEpoch ?? base.releaseDateMs,
        durationMs:
            detail.duration != null && detail.duration! > Duration.zero
            ? detail.duration!.inMilliseconds
            : base.durationMs,
        salesCount: detail.salesCount ?? base.salesCount,
        rating: detail.rating ?? base.rating,
        listenStatus: detail.listenStatus?.wireValue,
        userRating: detail.userRating,
        reviewText: detail.reviewText,
        hasReviewNote: detail.reviewText.trim().isNotEmpty,
        reviewUpdatedAtMs: detail.reviewUpdatedAt?.millisecondsSinceEpoch ?? 0,
        detailUpdatedAtMs: detail.updatedAt?.millisecondsSinceEpoch ?? 0,
        coverUrl: resolvedCover,
        updatedAtMs:
            detail.updatedAt?.millisecondsSinceEpoch ?? base.updatedAtMs,
      );
    } on Object {
      return base;
    }
  }

  Future<RemoteLibraryWork> saveWorkDetail({
    required RemoteMediaSource source,
    required RemoteLibraryWork work,
    required WebDavClient client,
    required DlsiteMetadata metadata,
    String? newFolderName,
    Uint8List? coverBytes,
    String coverExtension = 'jpg',
    bool preserveDuration = false,
  }) async {
    final rawDir = work.directoryUri;
    if (rawDir == null || rawDir.isEmpty) {
      throw StateError('Missing WebDAV directory URI');
    }
    var currentDirUri = WebDavClient.normalizeDirectoryUri(Uri.parse(rawDir));
    var currentWork = work;

    final trimmedFolder = newFolderName?.trim() ?? '';
    if (trimmedFolder.isNotEmpty && trimmedFolder != work.folderName) {
      _validateRemoteEntryName(trimmedFolder);
      final destDirUri = _siblingUri(
        currentDirUri,
        trimmedFolder,
        isDirectory: true,
      );
      try {
        await client.moveUri(
          sourceUri: currentDirUri,
          destinationUri: destDirUri,
        );
      } on WebDavException catch (error) {
        if (error.statusCode == 412 || error.statusCode == 409) {
          throw const AudioDetailRenameException('nameConflict');
        }
        throw const AudioDetailRenameException('renameFailed');
      }
      currentDirUri = destDirUri;
      currentWork = currentWork.copyWith(
        workId: _stableWorkId(destDirUri.toString()),
        folderName: trimmedFolder,
        directoryUri: destDirUri.toString(),
      );
    }

    String? savedRelCover;
    String? nextCoverUrl = currentWork.coverUrl;
    if (coverBytes != null && coverBytes.isNotEmpty) {
      final safeExt = coverExtension.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
      final fileName = 'cover.${safeExt.isEmpty ? 'jpg' : safeExt.toLowerCase()}';
      final coverUri = currentDirUri.resolve(Uri.encodeComponent(fileName));
      await client.putBytesAtomic(coverUri, coverBytes);
      savedRelCover = fileName;
      nextCoverUrl = coverUri.toString();
    }

    final jsonUri = currentDirUri.resolve('doujin-audio.json');
    final existingBytes = await client.getBytesOrNull(
      jsonUri,
      maxBytes: 2 * 1024 * 1024,
    );
    final target = AudioDetailTarget.libraryRootFolder(currentDirUri.path);
    AudioDetail baseDetail;
    if (existingBytes != null) {
      try {
        baseDetail = _jsonCodec.decode(existingBytes, target);
      } on Object {
        baseDetail = _detailFromRemoteWork(currentWork, target);
      }
    } else {
      baseDetail = _detailFromRemoteWork(currentWork, target);
    }

    final now = DateTime.now();
    final effectiveDuration = preserveDuration && baseDetail.duration != null
        ? baseDetail.duration
        : metadata.duration;
    final nextDetail = baseDetail.copyWith(
      rjCode: metadata.rjCode.trim(),
      workTitle: metadata.workTitle.trim(),
      circleName: metadata.circleName.trim(),
      voiceActors: AudioDetail.normalizeList(metadata.voiceActors),
      tags: AudioDetail.normalizeList(metadata.tags),
      cardCoverPath: savedRelCover ?? baseDetail.cardCoverPath,
      cardCoverSelected: savedRelCover != null || baseDetail.cardCoverSelected,
      releaseDate: metadata.releaseDate,
      duration: effectiveDuration,
      salesCount: metadata.salesCount ?? baseDetail.salesCount,
      rating: metadata.rating,
      createdAt: baseDetail.createdAt ?? now,
      updatedAt: now,
    );

    final encoded = existingBytes != null
        ? _tryMergeOrEncodeNew(existingBytes, nextDetail)
        : _jsonCodec.encodeNew(nextDetail);
    await client.putBytesAtomic(jsonUri, encoded);

    return currentWork.copyWith(
      rjCode: nextDetail.rjCode,
      title: nextDetail.workTitle.isNotEmpty
          ? nextDetail.workTitle
          : currentWork.folderName,
      circleName: nextDetail.circleName,
      voiceActors: nextDetail.voiceActors,
      tags: nextDetail.tags,
      releaseDateMs: nextDetail.releaseDate?.millisecondsSinceEpoch,
      durationMs: nextDetail.duration?.inMilliseconds ?? currentWork.durationMs,
      salesCount: nextDetail.salesCount,
      rating: nextDetail.rating,
      coverUrl: nextCoverUrl,
      detailUpdatedAtMs: now.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
    );
  }

  Future<RemoteLibraryWork> saveWorkReview({
    required RemoteLibraryWork work,
    required WebDavClient client,
    required WorkListenStatus? listenStatus,
    required int? userRating,
    required String reviewText,
  }) async {
    final rawDir = work.directoryUri;
    if (rawDir == null || rawDir.isEmpty) {
      throw StateError('Missing WebDAV directory URI');
    }
    final dirUri = WebDavClient.normalizeDirectoryUri(Uri.parse(rawDir));
    final jsonUri = dirUri.resolve('doujin-audio.json');
    final existingBytes = await client.getBytesOrNull(
      jsonUri,
      maxBytes: 2 * 1024 * 1024,
    );
    final target = AudioDetailTarget.libraryRootFolder(dirUri.path);
    AudioDetail baseDetail;
    if (existingBytes != null) {
      try {
        baseDetail = _jsonCodec.decode(existingBytes, target);
      } on Object {
        baseDetail = _detailFromRemoteWork(work, target);
      }
    } else {
      baseDetail = _detailFromRemoteWork(work, target);
    }

    final now = DateTime.now();
    final trimmedReview = reviewText.trim();
    final nextDetail = baseDetail.copyWith(
      listenStatus: listenStatus,
      userRating: userRating,
      reviewText: trimmedReview,
      reviewUpdatedAt: now,
      createdAt: baseDetail.createdAt ?? now,
      updatedAt: baseDetail.updatedAt ?? now,
    );

    final encoded = existingBytes != null
        ? _tryMergeOrEncodeNew(existingBytes, nextDetail)
        : _jsonCodec.encodeNew(nextDetail);
    await client.putBytesAtomic(jsonUri, encoded);

    return work.copyWith(
      listenStatus: listenStatus?.wireValue,
      userRating: userRating,
      reviewText: trimmedReview,
      hasReviewNote: trimmedReview.isNotEmpty,
      reviewUpdatedAtMs: now.millisecondsSinceEpoch,
    );
  }

  Future<void> renameWorkEntry({
    required RemoteLibraryWork work,
    required WebDavClient client,
    required String relativePath,
    required String newName,
    required bool isDirectory,
  }) async {
    final rawDir = work.directoryUri;
    if (rawDir == null || rawDir.isEmpty) {
      throw StateError('Missing WebDAV directory URI');
    }
    final trimmedName = newName.trim();
    _validateRemoteEntryName(trimmedName);
    final dirUri = WebDavClient.normalizeDirectoryUri(Uri.parse(rawDir));
    final relSegments = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList(growable: false);
    if (relSegments.isEmpty) {
      throw const AudioDetailRenameException('renameFailed');
    }
    final encodedRel = relSegments.map(Uri.encodeComponent).join('/');
    final sourceUri = dirUri.resolve(isDirectory ? '$encodedRel/' : encodedRel);
    final parentSegments = relSegments.sublist(0, relSegments.length - 1);
    final destSegments = <String>[...parentSegments, trimmedName];
    final encodedDest = destSegments.map(Uri.encodeComponent).join('/');
    final destUri = dirUri.resolve(isDirectory ? '$encodedDest/' : encodedDest);

    try {
      await client.moveUri(
        sourceUri: sourceUri,
        destinationUri: destUri,
      );
    } on WebDavException catch (error) {
      if (error.statusCode == 412 || error.statusCode == 409) {
        throw const AudioDetailRenameException('nameConflict');
      }
      throw const AudioDetailRenameException('renameFailed');
    }
  }

  Future<RemoteLibraryWork> setWorkCoverFromRelativePath({
    required RemoteLibraryWork work,
    required WebDavClient client,
    required String relativeImagePath,
  }) async {
    final rawDir = work.directoryUri;
    if (rawDir == null || rawDir.isEmpty) {
      throw StateError('Missing WebDAV directory URI');
    }
    final dirUri = WebDavClient.normalizeDirectoryUri(Uri.parse(rawDir));
    final relSegments = relativeImagePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList(growable: false);
    if (relSegments.isEmpty) return work;
    final cleanRel = relSegments.join('/');
    final coverUri = dirUri.resolve(
      relSegments.map(Uri.encodeComponent).join('/'),
    );

    final jsonUri = dirUri.resolve('doujin-audio.json');
    final existingBytes = await client.getBytesOrNull(
      jsonUri,
      maxBytes: 2 * 1024 * 1024,
    );
    final target = AudioDetailTarget.libraryRootFolder(dirUri.path);
    AudioDetail baseDetail;
    if (existingBytes != null) {
      try {
        baseDetail = _jsonCodec.decode(existingBytes, target);
      } on Object {
        baseDetail = _detailFromRemoteWork(work, target);
      }
    } else {
      baseDetail = _detailFromRemoteWork(work, target);
    }

    final now = DateTime.now();
    final nextDetail = baseDetail.copyWith(
      cardCoverPath: cleanRel,
      cardCoverSelected: true,
      createdAt: baseDetail.createdAt ?? now,
      updatedAt: now,
    );
    final encoded = existingBytes != null
        ? _tryMergeOrEncodeNew(existingBytes, nextDetail)
        : _jsonCodec.encodeNew(nextDetail);
    await client.putBytesAtomic(jsonUri, encoded);

    return work.copyWith(
      coverUrl: coverUri.toString(),
      detailUpdatedAtMs: now.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
    );
  }

  static Uint8List _tryMergeOrEncodeNew(
    Uint8List existingBytes,
    AudioDetail nextDetail,
  ) {
    try {
      return _jsonCodec.merge(existingBytes, nextDetail);
    } on Object {
      return _jsonCodec.encodeNew(nextDetail);
    }
  }

  static AudioDetail _detailFromRemoteWork(
    RemoteLibraryWork work,
    AudioDetailTarget target,
  ) => AudioDetail(
    target: target,
    rjCode: work.rjCode,
    workTitle: work.title,
    circleName: work.circleName,
    voiceActors: work.voiceActors,
    tags: work.tags,
    releaseDate: work.releaseDateMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(work.releaseDateMs!),
    duration: work.durationMs > 0
        ? Duration(milliseconds: work.durationMs)
        : null,
    salesCount: work.salesCount,
    rating: work.rating,
    listenStatus: WorkListenStatus.tryFromWireValue(work.listenStatus),
    userRating: work.userRating,
    reviewText: work.reviewText,
    reviewUpdatedAt: work.reviewUpdatedAtMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(work.reviewUpdatedAtMs)
        : null,
    updatedAt: work.detailUpdatedAtMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(work.detailUpdatedAtMs)
        : null,
  );

  static void _validateRemoteEntryName(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        _illegalRemoteEntryNamePattern.hasMatch(name)) {
      throw const AudioDetailRenameException('invalidName');
    }
  }

  static Uri _siblingUri(
    Uri currentDirUri,
    String newName, {
    required bool isDirectory,
  }) {
    final segments = currentDirUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) {
      throw const AudioDetailRenameException('renameFailed');
    }
    final parentSegments = segments.sublist(0, segments.length - 1);
    final nextSegments = <String>[...parentSegments, newName];
    final encodedPath =
        '/${nextSegments.map(Uri.encodeComponent).join('/')}${isDirectory ? '/' : ''}';
    return currentDirUri.replace(path: encodedPath);
  }

  Future<({List<AsmrTrackFile> tree, String? discoveredCoverUrl, bool hasSubtitle})>
  fetchWorkTree({
    required RemoteLibraryWork work,
    required WebDavClient client,
  }) async {
    final rootUri = work.directoryUri != null && work.directoryUri!.isNotEmpty
        ? Uri.parse(work.directoryUri!)
        : client.baseUri;
    String? rootCover;
    var foundSubtitle = false;

    Future<List<AsmrTrackFile>> walk(
      Uri dirUri,
      String parentRelative,
      int depth,
    ) async {
      if (depth > 10) return const <AsmrTrackFile>[];
      final entries = await client.listDirectory(dirUri);
      if (depth == 0) {
        rootCover = _pickPreferredCoverUrl(entries);
      }
      final sorted = entries.where((e) => !e.name.startsWith('.')).toList()
        ..sort((a, b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return compareNatural(a.name, b.name);
        });

      final nodes = <AsmrTrackFile>[];
      for (final entry in sorted) {
        if (entry.name == 'doujin-audio.json') continue;
        final relPath = parentRelative.isEmpty
            ? entry.name
            : '$parentRelative/${entry.name}';
        if (entry.isDirectory) {
          final children = await walk(entry.uri, relPath, depth + 1);
          if (children.isEmpty) continue;
          nodes.add(
            AsmrTrackFile(
              hash: _stableWorkId(entry.uri.toString()),
              title: entry.name,
              type: 'folder',
              streamUrl: null,
              downloadUrl: null,
              lowQualityUrl: null,
              duration: Duration.zero,
              size: 0,
              children: children,
              workId: 0,
              workTitle: work.title,
              sourceId: work.rjCode,
              relativePath: relPath,
              workKey: work.uniqueKey,
            ),
          );
          continue;
        }

        final ext = path.posix.extension(entry.name).toLowerCase();
        String? type;
        if (isVideoMediaFile(entry.name)) {
          type = 'video';
        } else if (isSupportedMediaFile(entry.name)) {
          type = 'audio';
        } else if (_webDavSubtitleExts.contains(ext)) {
          type = 'text';
          foundSubtitle = true;
        } else if (_webDavTextExts.contains(ext)) {
          type = ext == '.pdf' ? 'pdf' : 'text';
        } else if (_webDavImageExts.contains(ext)) {
          type = 'image';
          rootCover ??= entry.uri.toString();
        }
        if (type == null) continue;

        final fileUrl = entry.uri.toString();
        nodes.add(
          AsmrTrackFile(
            hash: _stableWorkId(fileUrl),
            title: entry.name,
            type: type,
            streamUrl: fileUrl,
            downloadUrl: fileUrl,
            lowQualityUrl: null,
            duration: Duration.zero,
            size: entry.contentLength ?? 0,
            children: const <AsmrTrackFile>[],
            workId: 0,
            workTitle: work.title,
            sourceId: work.rjCode,
            relativePath: relPath,
            workKey: work.uniqueKey,
          ),
        );
      }
      return nodes;
    }

    final tree = await walk(rootUri, '', 0);
    return (
      tree: tree,
      discoveredCoverUrl: rootCover,
      hasSubtitle: foundSubtitle,
    );
  }

  static ({String rjCode, String circleName, String title})
  parseFolderWorkMetadata(String folderName) {
    final trimmed = folderName.trim();
    final rjCode = AudioDetail.findRjCodeInText(trimmed) ?? '';
    var working = trimmed;
    var circle = '';

    final circleMatch = _leadingBracketCirclePattern.firstMatch(working);
    if (circleMatch != null) {
      final candidateCircle = circleMatch.group(1)!.trim();
      if (AudioDetail.findRjCodeInText(candidateCircle) == null) {
        circle = candidateCircle;
        working = circleMatch.group(2)!.trim();
      }
    }

    if (rjCode.isNotEmpty) {
      working = working
          .replaceAll(
            RegExp('\\[?\\b${RegExp.escape(rjCode)}\\b\\]?', caseSensitive: false),
            '',
          )
          .trim();
      working = working.replaceFirst(RegExp(r'^[-_–—:\s]+'), '').trim();
    }
    return (
      rjCode: rjCode,
      circleName: circle,
      title: working.isEmpty ? trimmed : working,
    );
  }

  static RemoteLibraryWork _workFromEntry(
    String sourceId,
    WebDavEntry dir,
    ({String rjCode, String circleName, String title}) meta, {
    String? coverUrl,
    bool hasSubtitle = false,
    bool isPinned = false,
  }) => RemoteLibraryWork(
    sourceId: sourceId,
    workId: _stableWorkId(dir.uri.toString()),
    rjCode: meta.rjCode,
    title: meta.title,
    folderName: dir.name,
    circleName: meta.circleName,
    isPinned: isPinned,
    coverUrl: coverUrl,
    hasSubtitle: hasSubtitle,
    directoryUri: dir.uri.toString(),
    updatedAtMs: dir.lastModified?.millisecondsSinceEpoch ?? 0,
  );

  static String? _pickPreferredCoverUrl(List<WebDavEntry> entries) {
    final images = entries
        .where(
          (e) =>
              !e.isDirectory &&
              _webDavImageExts.contains(
                path.posix.extension(e.name).toLowerCase(),
              ),
        )
        .toList(growable: false);
    if (images.isEmpty) return null;
    for (final keyword in const ['cover', 'main', 'folder', 'jacket', 'sam']) {
      for (final img in images) {
        if (img.name.toLowerCase().contains(keyword)) {
          return img.uri.toString();
        }
      }
    }
    return images.first.uri.toString();
  }

  static String _stableWorkId(String raw) =>
      sha256.convert(utf8.encode(raw)).toString().substring(0, 24);
}
