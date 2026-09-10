import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// The installer ships both tools beside the application, never on PATH.
class WindowsMediaTools {
  WindowsMediaTools({String? executableDirectory})
    : _directory =
          executableDirectory ?? path.dirname(Platform.resolvedExecutable);

  static final instance = WindowsMediaTools();
  final String _directory;

  Future<Process> start(String tool, List<String> arguments) async {
    if (tool != 'ffmpeg' && tool != 'ffprobe') {
      throw ArgumentError.value(tool, 'tool');
    }
    final executable = path.join(_directory, 'tools', '$tool.exe');
    if (!await File(executable).exists()) {
      throw FileSystemException('Bundled media tool is missing', executable);
    }
    // Normal mode redirects all handles and Dart starts Windows children without
    // a console. No shell parsing: spaces and metacharacters stay in arguments.
    return Process.start(executable, arguments);
  }

  Future<({int exitCode, String output, String error})> _run(
    String tool,
    List<String> arguments,
  ) async {
    final process = await start(tool, arguments);
    final output = process.stdout.transform(utf8.decoder).join();
    final error = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 30),
      );
      return (exitCode: exitCode, output: await output, error: await error);
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      await Future.wait([output, error]);
      rethrow;
    }
  }

  Future<Duration?> readDuration(String mediaPath) async {
    final result = await _run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=noprint_wrappers=1:nokey=1',
      '-i',
      mediaPath,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'ffprobe',
        [mediaPath],
        result.error,
        result.exitCode,
      );
    }
    final seconds = double.tryParse(result.output.trim());
    if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
    return Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round(),
    );
  }

  Future<String?> extractImage(
    String mediaPath, {
    required bool videoFrame,
  }) async {
    final stat = await File(mediaPath).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    final key = sha256.convert(
      utf8.encode(
        '$mediaPath:${stat.modified.microsecondsSinceEpoch}:${stat.size}:$videoFrame',
      ),
    );
    final directory = Directory(
      path.join(
        (await getTemporaryDirectory()).path,
        videoFrame ? 'video_frames' : 'embedded_covers',
      ),
    );
    await directory.create(recursive: true);
    final output = File(path.join(directory.path, '$key.jpg'));
    if (await output.exists()) return output.path;
    // Separate scratch directories also make concurrent requests for a cover safe.
    final work = await directory.createTemp('extract_');
    final temporary = File(path.join(work.path, 'image.jpg'));
    try {
      final result = await _run('ffmpeg', [
        '-nostdin',
        '-v',
        'error',
        '-i',
        mediaPath,
        '-map',
        videoFrame ? '0:V:0' : '0:v:0',
        '-frames:v',
        '1',
        '-vf',
        'scale=640:640:force_original_aspect_ratio=decrease',
        '-q:v',
        '3',
        temporary.path,
      ]);
      // Audio without an embedded image legitimately has no video stream.
      if (result.exitCode != 0 || !await temporary.exists()) return null;
      if (await output.exists()) return output.path;
      await temporary.rename(output.path);
      return output.path;
    } finally {
      await work.delete(recursive: true);
    }
  }
}
