import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../settings/application/app_preferences.dart';

typedef PlaybackTrackResolver = MusicTrack? Function(String trackPath);
typedef PlaybackSubtitleLoader =
    Future<SubtitleTrack?> Function(String trackPath, MusicTrack? track);

class PlaybackSubtitleService extends ChangeNotifier {
  PlaybackSubtitleService({
    required PlaybackTrackResolver trackResolver,
    FileCachePlatformGateway? fileCacheGateway,
    void Function(String trackPath, SubtitleTrack? track)? onTrackLoaded,
    PlaybackSubtitleLoader? subtitleLoader,
    Future<Directory> Function()? subtitlesDirectoryResolver,
    Map<String, Duration>? initialOffsets,
    Map<String, String>? initialCustomPaths,
  }) : _trackResolver = trackResolver,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _onTrackLoaded = onTrackLoaded,
       _subtitleLoader = subtitleLoader,
       _subtitlesDirectoryResolver =
           subtitlesDirectoryResolver ?? _defaultSubtitlesDirectory {
    if (initialOffsets != null) _offsets.addAll(initialOffsets);
    if (initialCustomPaths != null) _customPaths.addAll(initialCustomPaths);
    unawaited(_loadPersistedSettings());
  }

  final PlaybackTrackResolver _trackResolver;
  final FileCachePlatformGateway _fileCacheGateway;
  final void Function(String trackPath, SubtitleTrack? track)? _onTrackLoaded;
  final PlaybackSubtitleLoader? _subtitleLoader;
  final Future<Directory> Function() _subtitlesDirectoryResolver;

  final Map<String, Future<SubtitleTrack?>> _loading =
      <String, Future<SubtitleTrack?>>{};
  final Map<String, SubtitleTrack?> _tracks = <String, SubtitleTrack?>{};
  final Map<String, Future<SubtitleTrack?>> _results =
      <String, Future<SubtitleTrack?>>{};
  final Map<String, Duration> _offsets = <String, Duration>{};
  final Map<String, String> _customPaths = <String, String>{};
  int _generation = 0;

  bool hasResult(String trackPath) => _tracks.containsKey(trackPath);
  bool isLoading(String trackPath) => _loading.containsKey(trackPath);
  bool hasKnownSubtitle(String trackPath) =>
      _tracks[trackPath] != null ||
      _customPaths.containsKey(trackPath) ||
      _hasRemoteSubtitleUrl(_trackResolver(trackPath));

  Duration getOffset(String trackPath) =>
      _offsets[trackPath] ?? Duration.zero;

  bool hasCustomSubtitle(String trackPath) => _customPaths.containsKey(trackPath);

  String? getCustomSubtitlePath(String trackPath) => _customPaths[trackPath];

  Future<void> setTrackOffset(String trackPath, Duration offset) async {
    if (offset == Duration.zero) {
      _offsets.remove(trackPath);
    } else {
      _offsets[trackPath] = offset;
    }
    unawaited(_persistOffsets());
    final currentTrack = _tracks[trackPath];
    if (currentTrack != null) {
      final updatedTrack = currentTrack.withOffset(offset);
      _tracks[trackPath] = updatedTrack;
      _results[trackPath] = SynchronousFuture<SubtitleTrack?>(updatedTrack);
      _onTrackLoaded?.call(trackPath, updatedTrack);
    }
    notifyListeners();
  }

  Future<SubtitleTrack?> importSubtitle(
    String trackPath,
    String filePath,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      final raw = utf8.decode(bytes, allowMalformed: true);
      final extension = path.extension(filePath).toLowerCase();
      final parsed = await parseSubtitleTrackFromRaw(
        sourcePath: filePath,
        raw: raw,
        extension: extension,
      );
      if (parsed == null || parsed.cues.isEmpty) return null;

      final dir = await _subtitlesDirectoryResolver();
      final safeKey = md5.convert(utf8.encode(trackPath)).toString();
      final destFile = File(path.join(dir.path, '$safeKey$extension'));
      await file.copy(destFile.path);

      _customPaths[trackPath] = destFile.path;
      unawaited(_persistCustomPaths());

      final offset = getOffset(trackPath);
      final readyTrack = parsed.withOffset(offset);
      _tracks[trackPath] = readyTrack;
      _results[trackPath] = SynchronousFuture<SubtitleTrack?>(readyTrack);
      _trimResults();
      _onTrackLoaded?.call(trackPath, readyTrack);
      notifyListeners();
      return readyTrack;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'import_subtitle_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> removeCustomSubtitle(String trackPath) async {
    final custom = _customPaths.remove(trackPath);
    if (custom != null) {
      unawaited(_persistCustomPaths());
      try {
        final file = File(custom);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    _tracks.remove(trackPath);
    unawaited(_results.remove(trackPath));
    notifyListeners();
    unawaited(load(trackPath));
  }

  static Future<Directory> _defaultSubtitlesDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(path.join(supportDir.path, 'imported_subtitles'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _loadPersistedSettings() async {
    try {
      final rawOffsets = await AppPreferences.getStringList(
        'subtitle_track_offsets',
      );
      if (rawOffsets != null) {
        for (final item in rawOffsets) {
          final idx = item.lastIndexOf('|');
          if (idx > 0) {
            final trackKey = item.substring(0, idx);
            final ms = int.tryParse(item.substring(idx + 1));
            if (ms != null && trackKey.isNotEmpty) {
              _offsets.putIfAbsent(trackKey, () => Duration(milliseconds: ms));
            }
          }
        }
      }
      final rawCustom = await AppPreferences.getStringList(
        'subtitle_custom_paths',
      );
      if (rawCustom != null) {
        for (final item in rawCustom) {
          final idx = item.lastIndexOf('|');
          if (idx > 0) {
            final trackKey = item.substring(0, idx);
            final customPath = item.substring(idx + 1);
            if (trackKey.isNotEmpty && customPath.isNotEmpty) {
              _customPaths.putIfAbsent(trackKey, () => customPath);
            }
          }
        }
      }
    } catch (error, stack) {
      AppLogService.warning(
        'Failed to load persisted subtitle settings',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> _persistOffsets() async {
    final list = _offsets.entries
        .map((e) => '${e.key}|${e.value.inMilliseconds}')
        .toList(growable: false);
    await AppPreferences.setStringList('subtitle_track_offsets', list);
  }

  Future<void> _persistCustomPaths() async {
    final list = _customPaths.entries
        .map((e) => '${e.key}|${e.value}')
        .toList(growable: false);
    await AppPreferences.setStringList('subtitle_custom_paths', list);
  }

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
        notifyListeners();
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
    notifyListeners();
  }

  Future<SubtitleTrack?> _loadTrack(String trackPath, MusicTrack? track) async {
    SubtitleTrack? loaded;
    final customPath = _customPaths[trackPath];
    if (customPath != null) {
      loaded = await _loadFromFile(customPath);
    }
    if (loaded == null) {
      if (trackPath.startsWith('content://')) {
        loaded = await _loadContentTrack(trackPath, track);
      } else if (track?.isRemoteAsmr == true && track != null) {
        loaded = await _loadAsmrTrack(track);
      } else {
        loaded = await loadSubtitleTrackForAudio(trackPath);
      }
    }
    if (loaded != null) {
      final offset = getOffset(trackPath);
      if (offset != Duration.zero) {
        loaded = loaded.withOffset(offset);
      }
    }
    return loaded;
  }

  Future<SubtitleTrack?> _loadFromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      final raw = utf8.decode(bytes, allowMalformed: true);
      final extension = path.extension(filePath).toLowerCase();
      return await parseSubtitleTrackFromRaw(
        sourcePath: filePath,
        raw: raw,
        extension: extension,
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'custom_subtitle_file_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  bool _hasRemoteSubtitleUrl(MusicTrack? track) {
    if (track?.isRemoteAsmr != true) return false;
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
