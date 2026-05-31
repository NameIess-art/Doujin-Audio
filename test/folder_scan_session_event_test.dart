import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/library_scanner_service.dart';
import 'package:nameless_audio/services/path_matcher.dart';

void main() {
  test('parses Android folder scan chunk events', () {
    final event = FolderScanSessionEvent.fromPayload(<Object?, Object?>{
      'sessionId': 'scan-1',
      'type': 'chunk',
      'tracks': <Object?>[
        <Object?, Object?>{
          'path': '/music/work/01.mp3',
          'title': '01',
          'groupKey': '/music/work',
          'groupTitle': 'work',
          'groupSubtitle': '/music/work',
          'isVideo': false,
          'scannedAtMs': 1000,
          'fileSizeBytes': 42,
          'modifiedAtMs': 2000,
        },
      ],
      'paths': <Object?>['/music/work/01.mp3'],
      'folders': <Object?>['/music/work'],
      'failureCount': 2,
    });

    expect(event.sessionId, 'scan-1');
    expect(event.isChunk, isTrue);
    expect(event.chunk.tracks, hasLength(1));
    expect(event.chunk.tracks.single.displayName, '01');
    expect(
      event.chunk.paths,
      contains(PathMatcher.normalize('/music/work/01.mp3')),
    );
    expect(event.chunk.folders, contains(PathMatcher.normalize('/music/work')));
    expect(event.chunk.failureCount, 2);
  });

  test('parses Android folder scan error events', () {
    final event = FolderScanSessionEvent.fromPayload(<Object?, Object?>{
      'sessionId': 'scan-2',
      'type': 'error',
      'code': 'scan_provider_error',
      'message': 'provider failed',
      'failureCount': 1,
    });

    expect(event.isError, isTrue);
    expect(event.errorCode, 'scan_provider_error');
    expect(event.errorMessage, 'provider failed');
    expect(event.chunk.failureCount, 1);
  });
}
