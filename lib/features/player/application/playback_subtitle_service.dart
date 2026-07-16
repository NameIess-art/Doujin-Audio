import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';

typedef PlaybackTrackResolver = MusicTrack? Function(String trackPath);

final class PlaybackSubtitleService {
  PlaybackSubtitleService({
    required PlaybackTrackResolver trackResolver,
    FileCachePlatformGateway? fileCacheGateway,
    void Function(String trackPath, SubtitleTrack? track)? onTrackLoaded,
  }) : _trackResolver = trackResolver,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _onTrackLoaded = onTrackLoaded;

  final PlaybackTrackResolver _trackResolver;
  final FileCachePlatformGateway _fileCacheGateway;
  final void Function(String trackPath, SubtitleTrack? track)? _onTrackLoaded;
  final Map<String, Future<SubtitleTrack?>> _loading =
      <String, Future<SubtitleTrack?>>{};
  final Map<String, SubtitleTrack?> _tracks = <String, SubtitleTrack?>{};
  final Map<String, Future<SubtitleTrack?>> _results =
      <String, Future<SubtitleTrack?>>{};

  bool hasResult(String trackPath) => _tracks.containsKey(trackPath);
  bool isLoading(String trackPath) => _loading.containsKey(trackPath);

  Future<SubtitleTrack?> load(String trackPath) {
    if (_tracks.containsKey(trackPath)) {
      return _results.putIfAbsent(
        trackPath,
        () => SynchronousFuture<SubtitleTrack?>(_tracks[trackPath]),
      );
    }
    return _loading.putIfAbsent(trackPath, () async {
      try {
        final track = _trackResolver(trackPath);
        final SubtitleTrack? subtitleTrack;
        if (trackPath.startsWith('content://')) {
          subtitleTrack = await _loadContentTrack(trackPath, track);
        } else if (track?.remoteMetadataKind == 'asmr.one' && track != null) {
          subtitleTrack = await _loadAsmrTrack(track);
        } else {
          subtitleTrack = await loadSubtitleTrackForAudio(trackPath);
        }
        _tracks[trackPath] = subtitleTrack;
        _results[trackPath] = SynchronousFuture<SubtitleTrack?>(subtitleTrack);
        if (_tracks.length > 20) {
          final oldestKey = _tracks.keys.first;
          _tracks.remove(oldestKey);
          unawaited(_results.remove(oldestKey));
        }
        _onTrackLoaded?.call(trackPath, subtitleTrack);
        return subtitleTrack;
      } finally {
        unawaited(_loading.remove(trackPath));
      }
    });
  }

  SubtitleTrack? trackSync(String trackPath) => _tracks[trackPath];

  String? textAt(
    String trackPath,
    Duration position, {
    SubtitleTrack? subtitleTrack,
  }) {
    final cue = (subtitleTrack ?? _tracks[trackPath])?.cueAt(position);
    final text = cue?.text.trim();
    return text == null || text.isEmpty ? null : text;
  }

  void clear() {
    _loading.clear();
    _tracks.clear();
    _results.clear();
  }

  Future<SubtitleTrack?> _loadContentTrack(
    String trackPath,
    MusicTrack? track,
  ) async {
    try {
      final raw = await _fileCacheGateway.resolveTrackSubtitle(
        path: trackPath,
        groupKey: track?.groupKey,
      );
      if (raw == null) return null;
      final sourcePath = raw['sourcePath']?.toString();
      final text = raw['text']?.toString();
      final extension = raw['extension']?.toString();
      if (sourcePath == null ||
          sourcePath.isEmpty ||
          text == null ||
          text.isEmpty ||
          extension == null ||
          extension.isEmpty) {
        return null;
      }
      return parseSubtitleTrackFromRaw(
        sourcePath: sourcePath,
        raw: text,
        extension: extension,
      );
    } on MissingPluginException {
      return null;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'content_subtitle_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<SubtitleTrack?> _loadAsmrTrack(MusicTrack track) async {
    final metadata = track.remoteMetadata;
    if (metadata == null) return null;
    final subtitleUrl = metadata['subtitleUrl']?.toString().trim() ?? '';
    if (subtitleUrl.isEmpty) return null;
    final subtitleExtension = _resolveAsmrSubtitleExtension(
      metadata['subtitleExtension']?.toString().trim(),
      subtitleUrl: subtitleUrl,
      subtitleSourcePath: metadata['subtitleSourcePath']?.toString(),
      subtitleTitle: metadata['subtitleTitle']?.toString(),
    );
    try {
      return loadSubtitleTrackFromUrl(
        url: subtitleUrl,
        sourcePath:
            metadata['subtitleSourcePath']?.toString().trim().isNotEmpty == true
            ? metadata['subtitleSourcePath']!.toString().trim()
            : metadata['subtitleTitle']?.toString().trim(),
        extension: subtitleExtension,
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'asmr_subtitle_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  String _resolveAsmrSubtitleExtension(
    String? metadataExtension, {
    required String subtitleUrl,
    String? subtitleSourcePath,
    String? subtitleTitle,
  }) {
    final normalized = _normalizedSubtitleExtension(metadataExtension ?? '');
    if (normalized.isNotEmpty) return normalized;
    for (final candidate in <String?>[
      subtitleSourcePath,
      subtitleTitle,
      subtitleUrl,
    ]) {
      final resolved = _normalizedSubtitleExtension(
        _subtitleExtensionFromCandidate(candidate),
      );
      if (resolved.isNotEmpty) return resolved;
    }
    return '';
  }

  String _normalizedSubtitleExtension(String extension) {
    final trimmed = extension.trim().toLowerCase();
    if (trimmed.isEmpty) return '';
    return trimmed.startsWith('.') ? trimmed : '.$trimmed';
  }

  String _subtitleExtensionFromCandidate(String? candidate) {
    if (candidate == null) return '';
    final trimmed = candidate.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    final sourcePath = uri != null && uri.hasScheme ? uri.path : trimmed;
    return path.extension(sourcePath);
  }
}
