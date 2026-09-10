import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:doujin_audio/features/video_converter/application/video_conversion_plan.dart';
import 'package:doujin_audio/features/video_converter/application/video_conversion_runner.dart';
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

  test(
    'Windows conversion keeps paths as arguments and drains progress before commit',
    () async {
      final plan = await createVideoConversionPlan(
        inputPath: '${directory.path}/音频 & clip.mp4',
        outputDirectoryPath: directory.path,
        format: 'flac',
        bitrate: '192k',
      );
      final tools = _Tools((_, arguments) async {
        await File(arguments.last).writeAsString('audio');
        return _Process(
          output:
              'out_time_us=500000\nprogress=continue\nout_time_us=1000000\nprogress=end\n',
        );
      });
      final progress = <double>[];
      final result = await VideoConversionRunner(
        windowsMediaTools: tools,
        isWindows: () => true,
      ).convert(plan: plan, durationMs: 1000, onProgress: progress.add);
      expect(result.status, VideoConversionStatus.success);
      expect(tools.arguments, contains(plan.inputPath));
      expect(progress, [0.5, 1.0]);
      expect(await File(plan.outputPath).readAsString(), 'audio');
      expect(await File(plan.temporaryOutputPath).exists(), isFalse);
    },
  );

  test(
    'Windows cancellation during process startup kills and removes partial output',
    () async {
      final plan = await createVideoConversionPlan(
        inputPath: '${directory.path}/clip.mp4',
        outputDirectoryPath: directory.path,
        format: 'mp3',
        bitrate: '192k',
      );
      final started = Completer<void>();
      final release = Completer<void>();
      final process = _Process();
      final tools = _Tools((_, arguments) async {
        await File(arguments.last).writeAsString('partial');
        started.complete();
        await release.future;
        return process;
      });
      final runner = VideoConversionRunner(
        windowsMediaTools: tools,
        isWindows: () => true,
      );
      final operation = runner.convert(
        plan: plan,
        durationMs: 1000,
        onProgress: (_) {},
      );
      await started.future;
      final cancel = runner.cancel();
      release.complete();
      await cancel;
      expect((await operation).status, VideoConversionStatus.canceled);
      expect(process.killed, isTrue);
      expect(await File(plan.temporaryOutputPath).exists(), isFalse);
      expect(await File(plan.outputPath).exists(), isFalse);
    },
  );
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
  bool killed = false;
  @override
  final Stream<List<int>> stdout;
  @override
  final Stream<List<int>> stderr;
  @override
  Future<int> get exitCode async => code;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => killed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
