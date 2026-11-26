import 'package:path/path.dart' as path;

import 'audio_detail.dart';
import 'music_track.dart';
import 'path_matcher.dart';

class CrossPlatformTrackIdentity {
  const CrossPlatformTrackIdentity({
    required this.workKey,
    required this.relativePath,
    required this.stemPath,
  });

  final String workKey;
  final String relativePath;
  final String stemPath;

  String get syncKey => '$workKey::${relativePath.toLowerCase()}';
  String get stemSyncKey => '$workKey::${stemPath.toLowerCase()}';
  String get timeSegmentTrackKey => '$workKey::$relativePath';
}

/// Computes platform-independent work and track keys (`rj:RJxxxxxx` + POSIX
/// relative path within the work folder) across Windows paths, Android SAF
/// `content://` trees, ASMR.ONE streams, LAN streams, and WebDAV URLs.
abstract final class CrossPlatformMediaIdentity {
  static String? normalizeRjCode(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    return AudioDetail.findRjCodeInText(text);
  }

  static String resolveWorkKey({
    String? rjCode,
    String? remoteMetadataKind,
    Map<String, Object?>? remoteMetadata,
    String? groupSubtitle,
    String? groupTitle,
    String? groupKey,
    String? trackPath,
  }) {
    for (final candidate in <String?>[
      rjCode,
      remoteMetadata?['rjCode']?.toString(),
      remoteMetadata?['sourceId']?.toString(),
      groupSubtitle,
      groupTitle,
      groupKey,
      trackPath,
    ]) {
      final found = normalizeRjCode(candidate);
      if (found != null) return 'rj:$found';
    }

    if (remoteMetadataKind == MusicTrack.remoteMetadataKindAsmrOne &&
        remoteMetadata?['id'] != null) {
      return 'asmr:${remoteMetadata!['id']}';
    }
    final remoteWorkKey = remoteMetadata?['workKey']?.toString().trim() ?? '';
    if (remoteWorkKey.isNotEmpty) {
      final rjInKey = normalizeRjCode(remoteWorkKey);
      if (rjInKey != null) return 'rj:$rjInKey';
      return 'asmr-key:$remoteWorkKey';
    }

    final titleCandidate = (groupTitle ?? '').trim();
    if (titleCandidate.isNotEmpty) {
      return 'work:${_normalizeWorkFolderTitle(titleCandidate)}';
    }
    final folderFromGroup = _lastSegmentName(groupKey ?? '');
    if (folderFromGroup.isNotEmpty) {
      return 'work:${_normalizeWorkFolderTitle(folderFromGroup)}';
    }
    return '';
  }

  static String resolveRelativeTrackPath({
    required String trackPath,
    String? groupKey,
    bool isSingle = false,
    Map<String, Object?>? remoteMetadata,
  }) {
    final explicitRelative =
        remoteMetadata?['trackRelativePath']?.toString().trim() ?? '';
    if (explicitRelative.isNotEmpty) {
      final normalized = _normalizePosixRelative(explicitRelative);
      if (normalized.isNotEmpty) return normalized;
    }

    if (!isSingle && groupKey != null && groupKey.trim().isNotEmpty) {
      final relative = PathMatcher.relativeWithin(trackPath, groupKey);
      if (relative != null && relative.trim().isNotEmpty) {
        final normalized = _normalizePosixRelative(relative);
        if (normalized.isNotEmpty) return normalized;
      }
    }

    return _normalizePosixRelative(_lastSegmentName(trackPath));
  }

  static CrossPlatformTrackIdentity? fromTrack(
    MusicTrack track, {
    String? rjCodeOverride,
  }) {
    final workKey = resolveWorkKey(
      rjCode: rjCodeOverride,
      remoteMetadataKind: track.remoteMetadataKind,
      remoteMetadata: track.remoteMetadata,
      groupSubtitle: track.groupSubtitle,
      groupTitle: track.groupTitle,
      groupKey: track.groupKey,
      trackPath: track.path,
    );
    if (workKey.isEmpty) return null;
    final relativePath = resolveRelativeTrackPath(
      trackPath: track.path,
      groupKey: track.groupKey,
      isSingle: track.isSingle,
      remoteMetadata: track.remoteMetadata,
    );
    if (relativePath.isEmpty) return null;
    return CrossPlatformTrackIdentity(
      workKey: workKey,
      relativePath: relativePath,
      stemPath: stripExtensionPosix(relativePath),
    );
  }

  static CrossPlatformTrackIdentity? fromWorkAndRelativePath({
    required String workKey,
    required String relativePath,
  }) {
    final cleanWork = workKey.trim();
    final cleanRel = _normalizePosixRelative(relativePath);
    if (cleanWork.isEmpty || cleanRel.isEmpty) return null;
    return CrossPlatformTrackIdentity(
      workKey: cleanWork,
      relativePath: cleanRel,
      stemPath: stripExtensionPosix(cleanRel),
    );
  }

  static String stripExtensionPosix(String posixRelativePath) {
    final normalized = _normalizePosixRelative(posixRelativePath);
    if (normalized.isEmpty) return '';
    final slash = normalized.lastIndexOf('/');
    final dir = slash < 0 ? '' : normalized.substring(0, slash + 1);
    final fileName = slash < 0 ? normalized : normalized.substring(slash + 1);
    final ext = path.posix.extension(fileName);
    final stem = ext.isEmpty
        ? fileName
        : fileName.substring(0, fileName.length - ext.length);
    return '$dir$stem';
  }

  static String _normalizePosixRelative(String raw) {
    final segments = raw
        .replaceAll('\\', '/')
        .split('/')
        .map((s) => PathMatcher.safeDecodeComponent(s).trim())
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList(growable: false);
    return segments.join('/');
  }

  static String _normalizeWorkFolderTitle(String value) =>
      value.replaceAll('\\', '/').trim().toLowerCase();

  static String _lastSegmentName(String rawPath) {
    final trimmed = PathMatcher.trimRightSlash(rawPath.trim());
    if (trimmed.isEmpty) return '';
    if (PathMatcher.isContentUri(trimmed)) {
      final marker = trimmed.indexOf('::');
      if (marker >= 0) {
        final suffix = trimmed.substring(marker + 2);
        final parts = suffix.split('/').where((s) => s.isNotEmpty);
        if (parts.isNotEmpty) {
          return PathMatcher.safeDecodeComponent(parts.last);
        }
      }
      final seg = PathMatcher.lastContentPathSegment(trimmed);
      if (seg != null && seg.isNotEmpty) {
        final decoded = PathMatcher.safeDecodeComponent(seg)
            .replaceAll('\\', '/');
        final parts = decoded.split('/').where((s) => s.isNotEmpty);
        if (parts.isNotEmpty) return parts.last;
      }
    }
    if (PathMatcher.isRemoteUri(trimmed)) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null) {
        final fragmentFile = uri.fragment.startsWith('eara-chapter=')
            ? Uri.splitQueryString(uri.fragment)['file']
            : null;
        if (fragmentFile != null && fragmentFile.trim().isNotEmpty) {
          return fragmentFile.trim();
        }
        if (uri.pathSegments.isNotEmpty) {
          return PathMatcher.safeDecodeComponent(uri.pathSegments.last);
        }
      }
    }
    final normalized = trimmed.replaceAll('\\', '/');
    final parts = normalized.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? trimmed : parts.last;
  }
}
