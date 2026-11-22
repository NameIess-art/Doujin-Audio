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

final MimeTypeResolver _coverMimeResolver = MimeTypeResolver()
  ..addMagicNumber(const <int>[0x42, 0x4D], 'image/bmp')
  ..addMagicNumber(
    const <int>[
      0x00, 0x00, 0x00, 0x00,
      0x66, 0x74, 0x79, 0x70,
      0x61, 0x76, 0x69, 0x66,
    ],
    'image/avif',
    mask: const <int>[
      0x00, 0x00, 0x00, 0x00,
      0xFF, 0xFF, 0xFF, 0xFF,
      0xFF, 0xFF, 0xFF, 0xFF,
    ],
  )
  ..addMagicNumber(
    const <int>[
      0x00, 0x00, 0x00, 0x00,
      0x66, 0x74, 0x79, 0x70,
      0x61, 0x76, 0x69, 0x73,
    ],
    'image/avif',
    mask: const <int>[
      0x00, 0x00, 0x00, 0x00,
      0xFF, 0xFF, 0xFF, 0xFF,
      0xFF, 0xFF, 0xFF, 0xFF,
    ],
  );

String? detectCoverMimeType(String filePath, List<int> headerBytes) {
  final detected = (headerBytes.isNotEmpty
          ? _coverMimeResolver.lookup('', headerBytes: headerBytes)
          : _coverMimeResolver.lookup(filePath))
      ?.toLowerCase();
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
