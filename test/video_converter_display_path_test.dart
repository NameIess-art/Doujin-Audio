import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/video_converter/presentation/video_converter_tab.dart';

void main() {
  test('output directory display removes Android primary storage prefix', () {
    expect(
      formatVideoConverterOutputDirectoryPath(
        '/storage/emulated/0/Music/Converted',
      ),
      'Music/Converted',
    );
    expect(
      formatVideoConverterOutputDirectoryPath('/sdcard/Music/Converted'),
      '/sdcard/Music/Converted',
    );
  });
}
