import 'dart:io';
import 'package:path/path.dart' as path;

class WindowsFfmpegService {
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
