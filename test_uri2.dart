import 'dart:io';

void main() {
  const path = 'E:\\\\\u97f3\u4e50\\\\song.mp3';
  stdout.writeln('1: ${Uri.file(path)}');
  stdout.writeln("2: ${Uri.parse('file:///${path.replaceAll('\\\\', '/')}')}");
}
