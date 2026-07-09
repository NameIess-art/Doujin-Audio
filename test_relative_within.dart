import 'package:path/path.dart' as path;
void main() {
  final ctx = path.Context(style: path.Style.windows);
  final child = "E:\\AudioLibrary\\Work1\\CD1";
  final parent = "E:\\AudioLibrary";
  final rel = ctx.relative(child, from: parent).replaceAll('\\', '/');
  print('rel: $rel');
  final firstSegment = rel.split(RegExp(r'[\\/]+')).firstWhere((segment) => segment.isNotEmpty, orElse: () => '');
  print('firstSegment: $firstSegment');
  final joined = ctx.join(parent, firstSegment);
  print('joined: $joined');
}
