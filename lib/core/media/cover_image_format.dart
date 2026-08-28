import 'package:mime/mime.dart';

const int maxCoverFileBytes = 8 * 1024 * 1024;
const String coverArtworkStoreDirectoryName = 'cover_artwork_v1';
const Set<String> supportedCoverMimeTypes = <String>{
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
  'image/bmp',
  'image/avif',
  'image/heic',
  'image/heif',
};

String? detectCoverMimeType(String filePath, List<int> headerBytes) {
  final detected = lookupMimeType(
    filePath,
    headerBytes: headerBytes,
  )?.toLowerCase();
  return supportedCoverMimeTypes.contains(detected) ? detected : null;
}

String extensionForCoverMimeType(String mimeType) {
  return switch (mimeType.toLowerCase()) {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    'image/bmp' => 'bmp',
    'image/avif' => 'avif',
    'image/heic' || 'image/heif' => 'heic',
    _ => 'image',
  };
}
