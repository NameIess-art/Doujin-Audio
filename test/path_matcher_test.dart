import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/path_matcher.dart';

void main() {
  test('SAF tree, document, and synthetic child paths match by document id', () {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic';
    const childDocument = '$root/document/primary%3AMusic%2FAlbum';
    const childTree =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic%2FAlbum';
    const childSynthetic = '$root::Album';
    const childTrack = '$root/document/primary%3AMusic%2FAlbum%2F01.mp3';

    expect(PathMatcher.equalsNormalized(childDocument, childTree), isTrue);
    expect(PathMatcher.equalsNormalized(childDocument, childSynthetic), isTrue);
    expect(PathMatcher.isWithinOrEqual(childTrack, root), isTrue);
    expect(PathMatcher.isWithinOrEqual(childTrack, childSynthetic), isTrue);
  });

  test('SAF paths with bare percent characters do not throw', () {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic%2F100%_Album';
    const child = '$root/document/primary%3AMusic%2F100%_Album%2F01.mp3';

    expect(PathMatcher.safeDecodeComponent('100%_Album'), '100%_Album');
    expect(PathMatcher.contentPathSegmentAfter(root, 'tree'), isNotNull);
    expect(PathMatcher.lastContentPathSegment(child), isNotNull);
    expect(PathMatcher.isWithinOrEqual(child, root), isTrue);
  });

  test('SAF tree rename retargets document and synthetic child paths', () {
    const oldRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AOld';
    const newRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ANew';
    const oldTrack = '$oldRoot/document/primary%3AOld%2FDisc%2F01.mp3';
    const oldGroup = '$oldRoot::Disc';

    expect(
      PathMatcher.replaceWithinOrEqual(oldTrack, oldRoot, newRoot),
      '$newRoot/document/primary%3ANew%2FDisc%2F01.mp3',
    );
    expect(
      PathMatcher.replaceWithinOrEqual(oldGroup, oldRoot, newRoot),
      '$newRoot::Disc',
    );
  });

  test('SAF relativeWithin bridges document and synthetic paths', () {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3ALibrary';
    const childDocument = '$root/document/primary%3ALibrary%2FAlbum';
    const nestedSynthetic = '$root::Album/Disc';

    expect(PathMatcher.relativeWithin(nestedSynthetic, childDocument), 'Disc');
    expect(PathMatcher.relativeWithin(childDocument, root), 'Album');
    expect(PathMatcher.relativeWithin(childDocument, childDocument), '');
  });

  test('containsEquivalent matches normalized file-system paths', () {
    expect(
      PathMatcher.containsEquivalent(const <String>{
        '/library/root/album/../track.mp3',
      }, '/library/root/track.mp3'),
      isTrue,
    );
  });

  test('Windows paths keep their semantics on every host platform', () {
    const root = r'C:\Audio\Library';
    const work = r'C:\Audio\Library\Work A';
    const track = r'C:\Audio\Library\Work A\Disc 1\01.mp3';

    expect(PathMatcher.normalize(track), track);
    expect(PathMatcher.isWithinOrEqual(track, root), isTrue);
    expect(PathMatcher.relativeWithin(track, work), 'Disc 1/01.mp3');
    expect(PathMatcher.join(root, 'Work A'), work);
  });
}
