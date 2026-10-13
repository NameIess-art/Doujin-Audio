import 'dart:io';
import 'package:path/path.dart' as path;
import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import '../domain/asmr_models.dart';
import 'asmr_download_internal_models.dart';
import 'asmr_download_models.dart';
import 'asmr_api_service.dart';

class AsmrDownloadPlanner {
  const AsmrDownloadPlanner();
  List<PlannedDownloadFile> collectPlannedFiles(List<AsmrTrackFile> roots) {
    final result = <PlannedDownloadFile>[];
    for (final root in roots) {
      _collectPlannedFilesRecursively(root, result);
    }
    return result;
  }

  List<PlannedDownloadFile> collectTaskFiles(AsmrDownloadTaskSnapshot task) {
    final files = collectPlannedFiles(task.selectedRoots);
    final cover = task.saveCover ? plannedCoverFile(task.work) : null;
    if (cover != null) files.add(cover);
    return files;
  }

  PlannedDownloadFile? findPlannedFile(
    AsmrDownloadTaskSnapshot task,
    String relativePath,
  ) {
    for (final file in collectTaskFiles(task)) {
      if (file.relativePath == relativePath) return file;
    }
    return null;
  }

  PlannedDownloadFile? plannedCoverFile(AsmrWork work) {
    final url = work.preferredCoverUrl.trim();
    if (url.isEmpty) return null;
    return PlannedDownloadFile.cover(
      url: url,
      relativePath: 'cover/cover.cover',
      coverFileStem: 'cover',
      maxBytes: 5 * 1024 * 1024,
    );
  }

  void _collectPlannedFilesRecursively(
    AsmrTrackFile node,
    List<PlannedDownloadFile> result,
  ) {
    if (node.isFolder) {
      if (node.children.isEmpty) {
        return;
      }
      for (final child in node.children) {
        _collectPlannedFilesRecursively(child, result);
      }
      return;
    }
    final url = downloadUrlFor(node);
    if (url == null || url.isEmpty) {
      return;
    }
    result.add(
      PlannedDownloadFile(
        url: url,
        relativePath: node.relativePath,
        size: node.size,
      ),
    );
  }

  String joinFolderPath(String basePath, String relativePath) {
    final normalizedRelative = validatedDownloadRelativePath(relativePath);
    if (PathMatcher.isContentUri(basePath)) {
      if (basePath.contains('::')) {
        final prefix = PathMatcher.trimRightSlash(basePath);
        return '$prefix/$normalizedRelative';
      }
      return '${PathMatcher.trimRightSlash(basePath)}::$normalizedRelative';
    }
    return resolveLocalPathWithin(basePath, normalizedRelative);
  }

  String validatedDownloadRelativePath(String relativePath) {
    final normalized = relativePath.trim().replaceAll('\\', '/');
    if (normalized.isEmpty ||
        path.posix.isAbsolute(normalized) ||
        path.windows.isAbsolute(normalized) ||
        normalized.startsWith('//') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw FormatException('Invalid download path: $relativePath');
    }
    final segments = normalized.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw FormatException('Invalid download path: $relativePath');
    }
    return segments.join('/');
  }

  String resolveLocalPathWithin(String basePath, String relativePath) {
    final normalizedRelative = localRelativePath(relativePath);
    final root = path.normalize(path.absolute(basePath));
    final target = path.normalize(
      path.absolute(
        path.join(root, normalizedRelative.replaceAll('/', path.separator)),
      ),
    );
    if (!path.isWithin(root, target)) {
      throw const FormatException('Download path escapes its destination.');
    }
    return target;
  }

  String localRelativePath(String relativePath) {
    final normalized = validatedDownloadRelativePath(relativePath);
    if (!Platform.isWindows) return normalized;
    return normalized
        .split('/')
        .map((segment) {
          var safe = PathDisplay.safeFileName(
            segment,
            replacement: '_',
            collapseWhitespace: false,
            fallback: '_',
          );
          if (RegExp(
            r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)',
            caseSensitive: false,
          ).hasMatch(safe)) {
            safe = '_$safe';
          }
          return safe;
        })
        .join('/');
  }

  void validateLocalOutputs(
    List<PlannedDownloadFile> files, {
    required bool saveMetadata,
  }) {
    if (!Platform.isWindows) return;
    final owners = <String, String>{};
    final kinds = <String, bool>{};
    void register(
      String original, {
      bool directory = false,
      bool generated = false,
    }) {
      final output = localRelativePath(original).toLowerCase();
      final owner = generated ? 'generated:$original' : original;
      if ((owners.containsKey(output) && owners[output] != owner) ||
          (kinds.containsKey(output) && kinds[output] != directory)) {
        throw FormatException('Download paths collide on Windows: $original');
      }
      owners[output] = owner;
      kinds[output] = directory;
    }

    if (saveMetadata) register('doujin-audio.json', generated: true);
    for (final file in files) {
      final original = validatedDownloadRelativePath(file.relativePath);
      // The generated metadata already owns this remote document name.
      if (saveMetadata && original.toLowerCase() == 'doujin-audio.json') {
        continue;
      }
      final segments = original.split('/');
      for (var count = 1; count < segments.length; count++) {
        register(segments.take(count).join('/'), directory: true);
      }
      register(original);
      if (file.isCover) {
        for (final extension in ['.jpg', '.jpeg', '.png', '.webp', '.gif']) {
          register('cover/${file.coverFileStem}$extension', generated: true);
        }
      }
    }
  }

  AudioDetail buildBackupDetail(AsmrWork work, String workRootPath) {
    return AudioDetail(
      target: AudioDetailTarget.libraryRootFolder(workRootPath),
      rjCode: work.rjCode,
      workTitle: work.title,
      circleName: work.circleName,
      voiceActors: work.voiceActors,
      tags: work.tags,
      releaseDate: work.releaseDate,
      duration: work.duration > Duration.zero ? work.duration : null,
      salesCount: work.dlCount > 0 ? work.dlCount : null,
      rating: work.rating > 0 ? work.rating.clamp(0, 5).toDouble() : null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ).normalizedForSave(DateTime.now());
  }

  String? downloadUrlFor(AsmrTrackFile node) {
    final candidates = <String?>[
      if (<String?>[
        node.streamUrl,
        node.downloadUrl,
        node.lowQualityUrl,
      ].any(AsmrApiService.isOfficialMediaUrl))
        ...AsmrApiService.mediaDownloadUrlsForHash(node.hash),
      node.downloadUrl,
      node.streamUrl,
      node.lowQualityUrl,
    ];
    for (final candidate in candidates) {
      final value = candidate?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  String coverExtension(String url, String? mimeType) {
    final urlExtension = coverUrlExtension(url);
    if (urlExtension != null) return urlExtension;
    return switch (mimeType?.toLowerCase()) {
      'image/png' => '.png',
      'image/webp' => '.webp',
      'image/gif' => '.gif',
      'image/jpeg' || 'image/jpg' => '.jpg',
      _ => '.jpg',
    };
  }

  String? coverUrlExtension(String url) {
    final extension = path
        .extension(Uri.tryParse(url)?.path ?? '')
        .toLowerCase();
    return const <String>{
          '.jpg',
          '.jpeg',
          '.png',
          '.webp',
          '.gif',
        }.contains(extension)
        ? extension
        : null;
  }
}
