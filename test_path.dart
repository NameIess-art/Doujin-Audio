import 'package:path/path.dart' as path;

void main() {
  final ctx = path.Context(style: path.Style.windows);
  final parent = 'E:/Music/Album';
  final child = 'E:/Music/Album/Song.mp3';
  
  print('isWithin: ${ctx.isWithin(parent, child)}');
  
  final parent2 = 'E:\\Music\\Album';
  final child2 = 'E:/Music/Album/Song.mp3';
  print('isWithin2: ${ctx.isWithin(parent2, child2)}');
}
