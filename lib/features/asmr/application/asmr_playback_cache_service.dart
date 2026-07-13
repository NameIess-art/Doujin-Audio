import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/music_track.dart';
import '../../settings/application/app_cache_service.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';

class AsmrPlaybackCacheService {
  const AsmrPlaybackCacheService();

  static const String cacheDirectoryName = 'asmr_playback_cache';

  Future<String?> cacheTrack(MusicTrack track, {String? playedPath}) async {
    if (track.remoteMetadataKind != 'asmr.one') return null;

    final source = _cacheableSource(track, playedPath: playedPath);
    if (source == null) return null;

    try {
      final root = await _cacheRoot();
      await root.create(recursive: true);
      final target = File(path.join(root.path, _fileNameFor(source, track)));
      if (await target.exists() && await target.length() > 0) {
        await target.setLastModified(DateTime.now());
        return target.path;
      }

      final temp = File('${target.path}.part');
      if (await temp.exists()) {
        await temp.delete();
      }
      await _download(source, temp);
      if (await temp.length() <= 0) {
        await temp.delete();
        return null;
      }
      await temp.rename(target.path);
      AppCacheService.scheduleEnforce();
      return target.path;
    } catch (error, stackTrace) {
      AppLogService.error(
        'asmr_playback_cache_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static String? _cacheableSource(MusicTrack track, {String? playedPath}) {
    final candidates = <String>[
      ?playedPath,
      track.path,
      ..._playbackUrls(track),
    ];
    for (final candidate in candidates) {
      final value = candidate.trim();
      if (PathMatcher.isRemoteUri(value)) return value;
    }
    return null;
  }

  static Iterable<String> _playbackUrls(MusicTrack track) sync* {
    final raw = track.remoteMetadata?['playbackUrls'];
    if (raw is! List) return;
    for (final value in raw.whereType<String>()) {
      yield value;
    }
  }

  static Future<Directory> _cacheRoot() async {
    final temp = await getTemporaryDirectory();
    return Directory(path.join(temp.path, cacheDirectoryName));
  }

  static String _fileNameFor(String source, MusicTrack track) {
    final hash = sha1.convert(utf8.encode(source)).toString();
    final extension = _extensionFor(source, track.displayName);
    return extension.isEmpty ? hash : '$hash$extension';
  }

  static String _extensionFor(String source, String displayName) {
    final uri = Uri.tryParse(source);
    final uriExtension = uri == null ? '' : path.extension(uri.path);
    if (_isSafeExtension(uriExtension)) return uriExtension.toLowerCase();
    final nameExtension = path.extension(displayName);
    return _isSafeExtension(nameExtension) ? nameExtension.toLowerCase() : '';
  }

  static bool _isSafeExtension(String value) {
    return value.length > 1 &&
        value.length <= 10 &&
        RegExp(r'^\.[A-Za-z0-9]+$').hasMatch(value);
  }

  static Future<void> _download(String source, File target) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(source));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Unexpected ASMR playback cache status ${response.statusCode}',
          uri: Uri.parse(source),
        );
      }
      await response.pipe(target.openWrite());
    } finally {
      client.close(force: true);
    }
  }
}
