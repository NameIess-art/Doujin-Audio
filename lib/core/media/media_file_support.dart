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
