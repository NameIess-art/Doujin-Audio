import 'dart:io';

void main() async {
  stdout.writeln('Downloading FFmpeg from GitHub...');
  const url =
      'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip';
  final zipFile = File('ffmpeg.zip');

  // Download using PowerShell
  final result = await Process.run('powershell', [
    '-Command',
    'Invoke-WebRequest -Uri "$url" -OutFile "${zipFile.path}"',
  ]);
  if (result.exitCode != 0) {
    stderr.writeln('Failed to download: ${result.stderr}');
    return;
  }

  stdout.writeln('Extracting FFmpeg...');
  final extractResult = await Process.run('powershell', [
    '-Command',
    'Expand-Archive -Path ffmpeg.zip -DestinationPath ffmpeg_extracted -Force',
  ]);

  if (extractResult.exitCode != 0) {
    stderr.writeln('Failed to extract: ${extractResult.stderr}');
    return;
  }

  stdout.writeln('Moving executables to assets...');
  final dir = Directory('ffmpeg_extracted');
  final binDir =
      dir
              .listSync(recursive: true)
              .firstWhere(
                (e) => e is Directory && e.path.endsWith('bin'),
                orElse: () => throw Exception(
                  'Could not find bin directory in extracted zip.',
                ),
              )
          as Directory;

  final assetsDir = Directory('assets/ffmpeg');
  if (!assetsDir.existsSync()) {
    assetsDir.createSync(recursive: true);
  }

  final ffmpegExe = File('${binDir.path}/ffmpeg.exe');
  final ffprobeExe = File('${binDir.path}/ffprobe.exe');

  ffmpegExe.copySync('${assetsDir.path}/ffmpeg.exe');
  ffprobeExe.copySync('${assetsDir.path}/ffprobe.exe');

  stdout.writeln('Cleaning up...');
  zipFile.deleteSync();
  dir.deleteSync(recursive: true);

  stdout.writeln('Done! ffmpeg.exe and ffprobe.exe are in assets/ffmpeg/');
}
