import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/path_display.dart';

void main() {
  test('hides the Android shared storage prefix from display paths', () {
    expect(
      PathDisplay.displayPathFor('/storage/emulated/0/Download/ASMR'),
      'Download/ASMR',
    );
    expect(
      PathDisplay.displayPathFor(
        '/storage/emulated/0/Download/ASMR.ONE/actual-work-folder',
      ),
      'Download/ASMR.ONE/actual-work-folder',
    );
    expect(PathDisplay.displayPathFor('/storage/emulated/0'), '/');
  });

  test('does not hide similar non-shared-storage prefixes', () {
    expect(
      PathDisplay.displayPathFor(
        '/storage/emulated/01/Download/ASMR',
      ).replaceAll('\\', '/'),
      '/storage/emulated/01/Download/ASMR',
    );
  });

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
