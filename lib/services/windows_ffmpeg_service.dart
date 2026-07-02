import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class WindowsFfmpegService {
  static const String _videoFrameCacheVersion = 'v2';

  static String? _resolvedFfmpegPath;
  static String? _resolvedFfprobePath;

  static String get ffmpegPath {
    if (_resolvedFfmpegPath != null) return _resolvedFfmpegPath!;
    _resolvePaths();
    return _resolvedFfmpegPath ?? 'ffmpeg';
  }

  static String get ffprobePath {
    if (_resolvedFfprobePath != null) return _resolvedFfprobePath!;
    _resolvePaths();
    return _resolvedFfprobePath ?? 'ffprobe';
  }

  static bool get isAvailable {
    resolvePaths();
    return _resolvedFfmpegPath != null && _resolvedFfprobePath != null;
  }

  static Future<String?> resolveVideoFrame({
    required String videoPath,
    int? modifiedAtMs,
  }) async {
    if (!Platform.isWindows || !isAvailable || !File(videoPath).existsSync()) {
      return null;
    }

    final cacheRoot = await getTemporaryDirectory();
    final cacheDirectory = Directory(path.join(cacheRoot.path, 'video_frames'));
    await cacheDirectory.create(recursive: true);
    final cacheKey = sha256
        .convert(
          utf8.encode(
            '$videoPath|${modifiedAtMs ?? 0}|$_videoFrameCacheVersion',
          ),
        )
        .toString();
    final output = File(path.join(cacheDirectory.path, '$cacheKey.jpg'));
    if (await output.exists() && await output.length() > 0) {
      return output.path;
    }

    final partial = File('${output.path}.part.jpg');
    try {
      final durationSeconds = await _readDurationSeconds(videoPath);
      for (final seekSeconds in _videoFrameSeekSeconds(durationSeconds)) {
        if (await partial.exists()) await partial.delete();
        final result = await Process.run(ffmpegPath, [
          '-y',
          '-ss',
          seekSeconds,
          '-i',
          videoPath,
          '-frames:v',
          '1',
          '-vf',
          'scale=640:-2',
          '-q:v',
          '3',
          partial.path,
        ]);
        if (result.exitCode == 0 &&
            await partial.exists() &&
            await partial.length() > 0 &&
            await _isUsableVideoFrame(partial)) {
          await partial.rename(output.path);
          return output.path;
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  static Future<String?> resolveAudioCover({
    required String audioPath,
    int? modifiedAtMs,
  }) async {
    if (!isAvailable) return null;
    final file = File(audioPath);
    if (!await file.exists()) return null;

    final cacheRoot = await getTemporaryDirectory();
    final cacheDirectory = Directory(path.join(cacheRoot.path, 'audio_covers'));
    await cacheDirectory.create(recursive: true);
    final cacheKey = sha256
        .convert(utf8.encode('$audioPath|${modifiedAtMs ?? 0}|v1'))
        .toString();
    final output = File(path.join(cacheDirectory.path, '$cacheKey.jpg'));

    if (await output.exists() && await output.length() > 0) {
      return output.path;
    }

    final partial = File('${output.path}.part.jpg');
    try {
      if (await partial.exists()) await partial.delete();
      final result = await Process.run(ffmpegPath, [
        '-y',
        '-i',
        audioPath,
        '-an',
        '-vcodec',
        'mjpeg',
        '-frames:v',
        '1',
        partial.path,
      ]);
      if (result.exitCode == 0 &&
          await partial.exists() &&
          await partial.length() > 0) {
        await partial.rename(output.path);
        return output.path;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  static Future<double> _readDurationSeconds(String videoPath) async {
    final result = await Process.run(ffprobePath, [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=noprint_wrappers=1:nokey=1',
      videoPath,
    ]);
    if (result.exitCode != 0) return 0;
    return double.tryParse(result.stdout.toString().trim()) ?? 0;
  }

  static List<String> _videoFrameSeekSeconds(double durationSeconds) {
    final candidates = durationSeconds > 0
        ? <double>[
            durationSeconds * 0.35,
            durationSeconds * 0.55,
            durationSeconds * 0.75,
            durationSeconds * 0.15,
            1,
            0,
          ]
        : <double>[1, 0];
    final result = <String>[];
    final seen = <int>{};
    for (final candidate in candidates) {
      final bounded = durationSeconds > 0
          ? candidate.clamp(0.0, durationSeconds * 0.95)
          : candidate;
      final milliseconds = (bounded * 1000).round();
      if (!seen.add(milliseconds)) continue;
      result.add((milliseconds / 1000).toStringAsFixed(3));
    }
    return result;
  }

  static Future<bool> _isUsableVideoFrame(File frame) async {
    final result = await Process.run(ffmpegPath, [
      '-hide_banner',
      '-i',
      frame.path,
      '-vf',
      'signalstats,entropy,metadata=print',
      '-frames:v',
      '1',
      '-f',
      'null',
      '-',
    ]);
    final output = '${result.stdout}\n${result.stderr}';
    final yMin = _metadataValue(output, 'lavfi.signalstats.YMIN');
    final yAvg = _metadataValue(output, 'lavfi.signalstats.YAVG');
    final yMax = _metadataValue(output, 'lavfi.signalstats.YMAX');
    final entropy = _metadataValue(
      output,
      'lavfi.entropy.normalized_entropy.normal.Y',
    );
    if (yMin == null || yAvg == null || yMax == null || entropy == null) {
      return false;
    }

    final luminanceRange = yMax - yMin;
    final isBlack = yAvg <= 10 && entropy < 0.35;
    final isWhite = yAvg >= 245 && entropy < 0.35;
    final isLowInformation = luminanceRange < 12 && entropy < 0.2;
    return !isBlack && !isWhite && !isLowInformation;
  }

  static double? _metadataValue(String output, String key) {
    final match = RegExp(
      '${RegExp.escape(key)}=([-+]?[0-9]*\\.?[0-9]+)',
    ).firstMatch(output);
    return double.tryParse(match?.group(1) ?? '');
  }

  static void resolvePaths() => _resolvePaths();

  static void _resolvePaths() {
    final execPath = Platform.resolvedExecutable;
    final execDir = path.dirname(execPath);

    final builtAssetsDir = path.join(
      execDir,
      'data',
      'flutter_assets',
      'assets',
      'ffmpeg',
    );
    final devAssetsDir = path.join(Directory.current.path, 'assets', 'ffmpeg');

    final candidates = [builtAssetsDir, devAssetsDir];

    for (final dir in candidates) {
      final ffmpegCandidate = File(path.join(dir, 'ffmpeg.exe'));
      final ffprobeCandidate = File(path.join(dir, 'ffprobe.exe'));

      if (ffmpegCandidate.existsSync() && ffprobeCandidate.existsSync()) {
        _resolvedFfmpegPath = ffmpegCandidate.path;
        _resolvedFfprobePath = ffprobeCandidate.path;
        return;
      }
    }
  }
}
