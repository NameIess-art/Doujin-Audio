import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('windows_media_test_');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'missing bundled tool fails explicitly without searching PATH',
    () async {
      await expectLater(
        WindowsMediaTools(
          executableDirectory: directory.path,
        ).start('ffprobe', []),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('Windows duration preserves decimal precision', () async {
    final tools = _Tools((_, _) async => _Process(output: '12.345\n'));
    expect(
      await tools.readDuration('C:\\音频 文件\\track.mp3'),
      const Duration(milliseconds: 12345),
    );
    expect(tools.arguments!.last, 'C:\\音频 文件\\track.mp3');
  });

  test('invalid media propagates ffprobe failure', () async {
    final tools = _Tools(
      (_, _) async => _Process(code: 1, error: 'Invalid data'),
    );
    await expectLater(
      tools.readDuration('broken.mp3'),
      throwsA(isA<ProcessException>()),
    );
  });
}

class _Tools extends WindowsMediaTools {
  _Tools(this.launch);
  final Future<Process> Function(String, List<String>) launch;
  List<String>? arguments;
  @override
  Future<Process> start(String tool, List<String> arguments) {
    this.arguments = arguments;
    return launch(tool, arguments);
  }
}

class _Process implements Process {
  _Process({this.code = 0, String output = '', String error = ''})
    : stdout = Stream.value(utf8.encode(output)),
      stderr = Stream.value(utf8.encode(error));
  final int code;
  @override
  final Stream<List<int>> stdout;
  @override
  final Stream<List<int>> stderr;
  @override
  Future<int> get exitCode async => code;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
