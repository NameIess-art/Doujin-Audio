import 'dart:convert';

import 'package:doujin_audio/core/media/cover_image_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detectCoverMimeType recognizes BMP and AVIF by magic bytes', () {
    const bmpHeader = <int>[0x42, 0x4D, 0x36, 0x00, 0x00, 0x00];
    const avifHeader = <int>[
      0x00, 0x00, 0x00, 0x1C,
      0x66, 0x74, 0x79, 0x70, // ftyp
      0x61, 0x76, 0x69, 0x66, // avif
    ];
    const avisHeader = <int>[
      0x00, 0x00, 0x00, 0x1C,
      0x66, 0x74, 0x79, 0x70, // ftyp
      0x61, 0x76, 0x69, 0x73, // avis
    ];

    expect(detectCoverMimeType('', bmpHeader), 'image/bmp');
    expect(detectCoverMimeType('', avifHeader), 'image/avif');
    expect(detectCoverMimeType('', avisHeader), 'image/avif');
  });

  test('detectCoverMimeType recognizes standard cover image headers', () {
    const jpegHeader = <int>[0xFF, 0xD8, 0xFF, 0xE0];
    const pngHeader = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    const gifHeader = <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
    const webpHeader = <int>[
      0x52, 0x49, 0x46, 0x46,
      0x24, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
    ];
    const heicHeader = <int>[
      0x00, 0x00, 0x00, 0x18,
      0x66, 0x74, 0x79, 0x70,
      0x68, 0x65, 0x69, 0x63,
    ];

    expect(detectCoverMimeType('', jpegHeader), 'image/jpeg');
    expect(detectCoverMimeType('', pngHeader), 'image/png');
    expect(detectCoverMimeType('', gifHeader), 'image/gif');
    expect(detectCoverMimeType('', webpHeader), 'image/webp');
    expect(detectCoverMimeType('', heicHeader), 'image/heic');
  });

  test(
    'detectCoverMimeType rejects non-image bytes even with an image extension',
    () {
      final htmlBytes = utf8.encode('<html><body>Not an image</body></html>');
      expect(detectCoverMimeType('cover.jpg', htmlBytes), isNull);
      expect(detectCoverMimeType('cover.png', htmlBytes), isNull);
      expect(detectCoverMimeType('cover.bmp', htmlBytes), isNull);
    },
  );

  test('detectCoverMimeType falls back to file path when headerBytes is empty', () {
    expect(detectCoverMimeType('cover.jpg', const <int>[]), 'image/jpeg');
    expect(detectCoverMimeType('cover.bmp', const <int>[]), 'image/bmp');
    expect(detectCoverMimeType('notes.txt', const <int>[]), isNull);
  });
}
