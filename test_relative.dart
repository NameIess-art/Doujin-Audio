import 'package:path/path.dart' as path;
void main() {
  final ctx = path.Context(style: path.Style.windows);
  final rel = ctx.relative("E:\\AudioLibrary\\Work1", from: "E:\\AudioLibrary");
  print(rel);
}
