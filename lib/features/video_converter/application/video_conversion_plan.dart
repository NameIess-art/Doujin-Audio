import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../core/immutable_collections.dart';

class VideoConversionPlan {
  VideoConversionPlan({
    required this.inputPath,
    required this.outputPath,
    required this.format,
    required this.bitrate,
    required List<String> commandArgs,
  }) : commandArgs = immutableList(commandArgs);

  final String inputPath;
  final String outputPath;
  final String format;
  final String bitrate;
  final List<String> commandArgs;

  String get command => buildVideoConversionCommand(
    inputPath: inputPath,
    outputPath: outputPath,
    format: format,
    bitrate: bitrate,
  );
}

int parseVideoDurationMs(String? durationStr) {
  if (durationStr == null || durationStr.isEmpty) return 0;
  final seconds = double.tryParse(durationStr);
  if (seconds == null || !seconds.isFinite || seconds <= 0) {
    return 0;
  }
  return (seconds * 1000).round();
}

Future<String> resolveVideoConversionOutputPath({
  required String outputDirectoryPath,
  required String fileNameNoExt,
  required String format,
}) async {
  var suffix = 0;
  while (true) {
    final candidateName = suffix == 0
        ? '$fileNameNoExt.$format'
        : '$fileNameNoExt ($suffix).$format';
    final candidatePath = path.join(outputDirectoryPath, candidateName);
    if (!await File(candidatePath).exists()) {
      return candidatePath;
    }
    suffix++;
  }
}

List<String> buildVideoConversionCommandArgs({
  required String inputPath,
  required String outputPath,
  required String format,
  required String bitrate,
}) {
  final codecArgs = switch (format) {
    'mp3' => ['-vn', '-ar', '44100', '-ac', '2', '-b:a', bitrate],
    'flac' => ['-vn', '-c:a', 'flac'],
    'wav' => ['-vn', '-c:a', 'pcm_s16le', '-ar', '44100', '-ac', '2'],
    'aac' => ['-vn', '-c:a', 'aac', '-b:a', bitrate],
    'ogg' => ['-vn', '-c:a', 'libvorbis', '-b:a', bitrate],
    _ => ['-vn'],
  };
  return ['-i', inputPath, ...codecArgs, outputPath];
}

String buildVideoConversionCommand({
  required String inputPath,
  required String outputPath,
  required String format,
  required String bitrate,
}) {
  final args = buildVideoConversionCommandArgs(
    inputPath: inputPath,
    outputPath: outputPath,
    format: format,
    bitrate: bitrate,
  );
  return [
    args[0],
    _quoteCommandPath(args[1]),
    ...args.skip(2).take(args.length - 3),
    _quoteCommandPath(args.last),
  ].join(' ');
}

int parseFfmpegProgressTimeMs(String text) {
  final match = RegExp(
    r'time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
  ).firstMatch(text);
  if (match == null) return 0;
  final hours = int.tryParse(match.group(1)!);
  final minutes = int.tryParse(match.group(2)!);
  final seconds = double.tryParse(match.group(3)!);
  if (hours == null || minutes == null || seconds == null) return 0;
  return ((hours * 3600 + minutes * 60 + seconds) * 1000).round();
}

String _quoteCommandPath(String value) {
  final escaped = value.replaceAll('"', r'\"');
  return '"$escaped"';
}

Future<VideoConversionPlan> createVideoConversionPlan({
  required String inputPath,
  required String outputDirectoryPath,
  required String format,
  required String bitrate,
}) async {
  final outputPath = await resolveVideoConversionOutputPath(
    outputDirectoryPath: outputDirectoryPath,
    fileNameNoExt: path.basenameWithoutExtension(inputPath),
    format: format,
  );
  return VideoConversionPlan(
    inputPath: inputPath,
    outputPath: outputPath,
    format: format,
    bitrate: bitrate,
    commandArgs: buildVideoConversionCommandArgs(
      inputPath: inputPath,
      outputPath: outputPath,
      format: format,
      bitrate: bitrate,
    ),
  );
}
