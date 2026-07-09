import 'package:path/path.dart' as path;
void main() {
  final ctx = path.Context(style: path.Style.windows);
  final parent = "E:\\AudioLibrary\\Work1";
  final child = "E:\\AudioLibrary\\Work10\\Track.mp3";
  print(ctx.isWithin(parent, child));
}
