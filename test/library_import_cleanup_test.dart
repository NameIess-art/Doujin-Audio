import 'dart:io';

import 'package:file_picker/file_picker.dart';
// The plugin exposes its platform test seam from this library.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/library/application/library_scan_data_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed picked stream removes its partial output and preserves existing imports',
    () async {
      final root = await Directory.systemTemp.createTemp('import_cleanup_');
      final imports = await Directory(
        '${root.path}/doujin_audio_imports',
      ).create();
      final existing = await File(
        '${imports.path}/existing.mp3',
      ).writeAsString('original');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (_) async => root.path);
      final originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _Picker();
      try {
        final source = PlatformLibraryScanDataSource(isAndroid: () => false);
        expect(await source.pickAudioFiles(dialogTitle: 'import'), isEmpty);
        expect(await existing.readAsString(), 'original');
        expect(
          await imports
              .list()
              .map((file) => file.path.replaceAll('\\', '/'))
              .toList(),
          [existing.path.replaceAll('\\', '/')],
        );
      } finally {
        FilePickerPlatform.instance = originalPicker;
        messenger.setMockMethodCallHandler(paths, null);
        await root.delete(recursive: true);
      }
    },
  );
}

final class _Picker extends FilePickerPlatform {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async => FilePickerResult([
    PlatformFile(name: 'broken.mp3', size: 10, readStream: _brokenStream()),
  ]);
}

Stream<List<int>> _brokenStream() async* {
  yield [1, 2, 3];
  throw const FileSystemException('source disconnected');
}
