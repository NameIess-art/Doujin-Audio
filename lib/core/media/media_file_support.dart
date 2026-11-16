import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;

const Set<String> supportedAudioExtensions = <String>{
  '.flac',
  '.wav',
  '.mp3',
  '.m4a',
  '.aac',
  '.ogg',
  '.opus',
  '.3gp',
};

const Set<String> supportedVideoExtensions = <String>{
  '.mp4',
  '.mkv',
  '.webm',
  '.mov',
  '.m4v',
  '.avi',
};

bool isSupportedMediaFile(String filePath) {
  final lowerPath = filePath.toLowerCase();
  final extension = path.extension(lowerPath);
  if (supportedAudioExtensions.contains(extension) ||
      supportedVideoExtensions.contains(extension)) {
    return true;
  }
  final mimeType = lookupMimeType(filePath);
  if (mimeType == null) return false;
  return mimeType.startsWith('audio/') ||
      mimeType.startsWith('video/') ||
      mimeType == 'application/ogg';
}

bool isVideoMediaFile(String filePath) {
  final lowerPath = filePath.toLowerCase();
  final extension = path.extension(lowerPath);
  if (supportedVideoExtensions.contains(extension)) {
    return true;
  }
  final mimeType = lookupMimeType(filePath);
  if (mimeType == null) return false;
  return mimeType.startsWith('video/');
}

String formatMediaFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}';
}
