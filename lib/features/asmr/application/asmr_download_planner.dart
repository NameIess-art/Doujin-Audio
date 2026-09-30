import 'package:path/path.dart' as path;
import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_matcher.dart';
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

  PlannedDownloadFile? findPlannedFile(
    AsmrDownloadTaskSnapshot task,
    String relativePath,
  ) {
    final files = collectPlannedFiles(task.selectedRoots);
    if (task.saveCover) {
      final coverFile = plannedCoverFile(task.work);
      if (coverFile != null) files.add(coverFile);
    }
    for (final file in files) {
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
    final normalizedRelative = validatedDownloadRelativePath(relativePath);
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
