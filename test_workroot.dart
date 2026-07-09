import 'package:path/path.dart' as path;

String? _libraryWorkScopeFolderPath(String libraryRoot, String groupKey) {
  final relativePath = _relativeWithin(groupKey, libraryRoot);
  if (relativePath == null || relativePath.isEmpty) return null;

  final firstSegment = relativePath
      .split(RegExp(r'[\\/]+'))
      .firstWhere((segment) => segment.isNotEmpty, orElse: () => '');
  if (firstSegment.isEmpty) return null;

  return path.Context(style: path.Style.windows).join(libraryRoot, firstSegment);
}

String? _relativeWithin(String child, String parent) {
  final ctx = path.Context(style: path.Style.windows);
  if (child == parent) return '';
  if (!ctx.isWithin(parent, child)) return null;
  return ctx.relative(child, from: parent).replaceAll('\\', '/');
}

void main() {
  print(_libraryWorkScopeFolderPath('E:\\AudioLibrary', 'E:\\AudioLibrary\\Work1\\CD1'));
}
