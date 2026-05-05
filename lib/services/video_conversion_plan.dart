import 'dart:io';

import 'package:path/path.dart' as path;

class VideoConversionPlan {
  const VideoConversionPlan({
    required this.inputPath,
    required this.outputPath,
    required this.format,
    required this.bitrate,
    required this.command,
  });

  final String inputPath;
  final String outputPath;
  final String format;
  final String bitrate;
  final String command;
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

String buildVideoConversionCommand({
  required String inputPath,
  required String outputPath,
  required String format,
  required String bitrate,
}) {
  final codecArgs = switch (format) {
    'mp3' => '-vn -ar 44100 -ac 2 -b:a $bitrate',
    'flac' => '-vn -c:a flac',
    'wav' => '-vn -c:a pcm_s16le -ar 44100 -ac 2',
    'aac' => '-vn -c:a aac -b:a $bitrate',
    'ogg' => '-vn -c:a libvorbis -b:a $bitrate',
    _ => '-vn',
  };
  return '-i "$inputPath" $codecArgs "$outputPath"';
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
    command: buildVideoConversionCommand(
      inputPath: inputPath,
      outputPath: outputPath,
      format: format,
      bitrate: bitrate,
    ),
  );
}
