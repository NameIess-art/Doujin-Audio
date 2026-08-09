import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';

typedef PlaybackTrackResolver = MusicTrack? Function(String trackPath);
typedef PlaybackSubtitleLoader =
    Future<SubtitleTrack?> Function(String trackPath, MusicTrack? track);

final class PlaybackSubtitleService {
  PlaybackSubtitleService({
    required PlaybackTrackResolver trackResolver,
    FileCachePlatformGateway? fileCacheGateway,
    void Function(String trackPath, SubtitleTrack? track)? onTrackLoaded,
    PlaybackSubtitleLoader? subtitleLoader,
  }) : _trackResolver = trackResolver,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _onTrackLoaded = onTrackLoaded,
       _subtitleLoader = subtitleLoader;

  final PlaybackTrackResolver _trackResolver;
  final FileCachePlatformGateway _fileCacheGateway;
  final void Function(String trackPath, SubtitleTrack? track)? _onTrackLoaded;
  final PlaybackSubtitleLoader? _subtitleLoader;
  final Map<String, Future<SubtitleTrack?>> _loading =
      <String, Future<SubtitleTrack?>>{};
  final Map<String, SubtitleTrack?> _tracks = <String, SubtitleTrack?>{};
  final Map<String, Future<SubtitleTrack?>> _results =
      <String, Future<SubtitleTrack?>>{};
  int _generation = 0;

  bool hasResult(String trackPath) => _tracks.containsKey(trackPath);
  bool isLoading(String trackPath) => _loading.containsKey(trackPath);
  bool hasKnownSubtitle(String trackPath) =>
      _tracks[trackPath] != null ||
      _hasRemoteSubtitleUrl(_trackResolver(trackPath));

  Future<SubtitleTrack?> load(String trackPath) {
    if (_tracks.containsKey(trackPath)) {
      return _results.putIfAbsent(
        trackPath,
        () => SynchronousFuture<SubtitleTrack?>(_tracks[trackPath]),
      );
    }
    final existing = _loading[trackPath];
    if (existing != null) return existing;
    final requestGeneration = _generation;
    late final Future<SubtitleTrack?> task;
    task = () async {
      try {
        final track = _trackResolver(trackPath);
        final subtitleTrack =
            await (_subtitleLoader?.call(trackPath, track) ??
                _loadTrack(trackPath, track));
        if (requestGeneration != _generation ||
            !identical(_loading[trackPath], task)) {
          return subtitleTrack;
        }
        if (subtitleTrack != null || !_hasRemoteSubtitleUrl(track)) {
          _tracks[trackPath] = subtitleTrack;
          _results[trackPath] = SynchronousFuture<SubtitleTrack?>(
            subtitleTrack,
          );
          _trimResults();
        }
        _onTrackLoaded?.call(trackPath, subtitleTrack);
        return subtitleTrack;
      } finally {
        if (identical(_loading[trackPath], task)) {
          unawaited(_loading.remove(trackPath));
        }
      }
    }();
    _loading[trackPath] = task;
    return task;
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
    _generation++;
    _loading.clear();
    _tracks.clear();
    _results.clear();
  }

  Future<SubtitleTrack?> _loadTrack(String trackPath, MusicTrack? track) async {
    if (trackPath.startsWith('content://')) {
      return _loadContentTrack(trackPath, track);
    }
    if (track?.remoteMetadataKind == 'asmr.one' && track != null) {
      return _loadAsmrTrack(track);
    }
    return loadSubtitleTrackForAudio(trackPath);
  }

  bool _hasRemoteSubtitleUrl(MusicTrack? track) {
    if (track?.remoteMetadataKind != 'asmr.one') return false;
    return track?.remoteMetadata?['subtitleUrl']
            ?.toString()
            .trim()
            .isNotEmpty ==
        true;
  }

  void _trimResults() {
    if (_tracks.length <= 20) return;
    final oldestKey = _tracks.keys.first;
    _tracks.remove(oldestKey);
    unawaited(_results.remove(oldestKey));
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
      return await loadSubtitleTrackFromUrl(
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
