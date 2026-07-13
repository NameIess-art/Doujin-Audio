import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/library/application/library_entry_editor_service.dart';
import 'package:path/path.dart' as path;

void main() {
  test('enumerates supported media recursively in natural order', () async {
    final root = await Directory.systemTemp.createTemp('library_editor_');
    addTearDown(() => root.delete(recursive: true));
    final child = await Directory(path.join(root.path, 'disc')).create();
    await File(path.join(child.path, '10.mp3')).writeAsBytes(const <int>[1]);
    await File(path.join(child.path, '2.flac')).writeAsBytes(const <int>[1]);
    await File(path.join(child.path, 'cover.jpg')).writeAsBytes(const <int>[1]);

    final snapshot = await LibraryEntryEditorService(
      isAndroid: () => false,
    ).loadDiskSnapshot(root.path);

    expect(snapshot.authoritative, isTrue);
    expect(snapshot.audioFilePaths.map(path.basename), const <String>[
      '2.flac',
      '10.mp3',
    ]);
  });

  test('missing local root produces an authoritative empty snapshot', () async {
    final snapshot = await LibraryEntryEditorService(
      isAndroid: () => false,
    ).loadDiskSnapshot(path.join(Directory.systemTemp.path, 'missing-library'));

    expect(snapshot.authoritative, isTrue);
    expect(snapshot.audioFilePaths, isEmpty);
  });

  test('content uri outside Android is not authoritative', () async {
    final snapshot = await LibraryEntryEditorService(
      isAndroid: () => false,
    ).loadDiskSnapshot('content://library/tree');

    expect(snapshot.authoritative, isFalse);
  });
}
