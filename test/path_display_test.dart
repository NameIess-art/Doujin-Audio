import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/path_display.dart';

void main() {
  test('decodes SAF tree and document paths for display', () {
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR%2FRJ123456';
    const track =
        '$root/document/primary%3AASMR%2FRJ123456%2F%E7%BE%8A%E5%A8%98.mp3';

    expect(PathDisplay.folderName(root), 'RJ123456');
    expect(PathDisplay.displayPathFor(track), 'ASMR/RJ123456/羊娘.mp3');
    expect(PathDisplay.fileName(track, withoutExtension: true), '羊娘');
  });
}
