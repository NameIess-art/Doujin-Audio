void main() {
  final path = 'E:\\\\\u97f3\u4e50\\\\song.mp3';
  print('1: ' + Uri.file(path).toString());
  print('2: ' + Uri.parse('file:///' + path.replaceAll('\\\\', '/')).toString());
}
