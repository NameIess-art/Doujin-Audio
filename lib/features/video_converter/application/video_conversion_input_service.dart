import 'package:file_picker/file_picker.dart';

class VideoConversionInputService {
  Future<String?> pickVideoPath() async {
    final result = await FilePicker.pickFiles(type: FileType.video);
    final selectedPath = result?.files.singleOrNull?.path;
    if (selectedPath == null || selectedPath.isEmpty) return null;
    return selectedPath;
  }

  Future<String?> pickOutputDirectory() async {
    final selectedPath = await FilePicker.getDirectoryPath();
    if (selectedPath == null || selectedPath.isEmpty) return null;
    return selectedPath;
  }
}
