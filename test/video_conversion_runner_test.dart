import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/video_conversion_plan.dart';
import 'package:nameless_audio/services/video_conversion_runner.dart';

void main() {
  const plan = VideoConversionPlan(
    inputPath: 'input.mp4',
    outputPath: 'output.mp3',
    format: 'mp3',
    bitrate: '192k',
    commandArgs: <String>[
      '-i',
      'input.mp4',
      '-vn',
      '-b:a',
      '192k',
      'output.mp3',
    ],
  );

  test(
    'cancel waits for process exit and rejects an immediate retry',
    () async {
      final processes = <_FakeProcess>[_FakeProcess(1), _FakeProcess(2)];
      var startCount = 0;
      final runner = VideoConversionRunner(
        isWindows: () => true,
        isWindowsFfmpegAvailable: () => true,
        windowsProcessStarter: (_, _) async => processes[startCount++],
      );

      final firstConversion = runner.convert(
        plan: plan,
        durationMs: 1000,
        onProgress: (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      final cancel = runner.cancel();
      expect(processes.first.killCalled, isTrue);

      final retryWhileCanceling = await runner.convert(
        plan: plan,
        durationMs: 1000,
        onProgress: (_) {},
      );
      expect(retryWhileCanceling.status, VideoConversionStatus.failed);
      expect(retryWhileCanceling.errorMessage, 'conversion_already_running');
      expect(startCount, 1);

      processes.first.complete(-1);
      await cancel;
      expect((await firstConversion).status, VideoConversionStatus.canceled);
      expect(processes.first.stdoutCanceled, isTrue);
      expect(processes.first.stderrCanceled, isTrue);

      final secondConversion = runner.convert(
        plan: plan,
        durationMs: 1000,
        onProgress: (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(startCount, 2);
      processes[1].complete(0);
      expect((await secondConversion).status, VideoConversionStatus.success);

      await Future.wait(processes.map((process) => process.dispose()));
    },
  );

  test('process start failure releases the runner for a later retry', () async {
    final replacement = _FakeProcess(2);
    var startCount = 0;
    final runner = VideoConversionRunner(
      isWindows: () => true,
      isWindowsFfmpegAvailable: () => true,
      windowsProcessStarter: (_, _) async {
        startCount++;
        if (startCount == 1) {
          throw const ProcessException('ffmpeg', <String>[], 'start failed');
        }
        return replacement;
      },
    );

    final failed = await runner.convert(
      plan: plan,
      durationMs: 1000,
      onProgress: (_) {},
    );
    expect(failed.status, VideoConversionStatus.failed);
    expect(failed.errorMessage, contains('start failed'));

    final retried = runner.convert(
      plan: plan,
      durationMs: 1000,
      onProgress: (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    replacement.complete(0);
    expect((await retried).status, VideoConversionStatus.success);

    await replacement.dispose();
  });
}

class _FakeProcess implements Process {
  _FakeProcess(this.pid)
    : _stdoutController = StreamController<List<int>>.broadcast(),
      _stderrController = StreamController<List<int>>.broadcast(),
      _stdinController = StreamController<List<int>>.broadcast() {
    _stdoutController.onCancel = () {
      stdoutCanceled = true;
    };
    _stderrController.onCancel = () {
      stderrCanceled = true;
    };
    _stdin = IOSink(_stdinController.sink);
  }

  final Completer<int> _exitCode = Completer<int>();
  final StreamController<List<int>> _stdoutController;
  final StreamController<List<int>> _stderrController;
  final StreamController<List<int>> _stdinController;
  late final IOSink _stdin;

  @override
  final int pid;

  bool killCalled = false;
  bool stdoutCanceled = false;
  bool stderrCanceled = false;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  IOSink get stdin => _stdin;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalled = true;
    return true;
  }

  void complete(int exitCode) {
    if (!_exitCode.isCompleted) {
      _exitCode.complete(exitCode);
    }
  }

  Future<void> dispose() async {
    await _stdin.close();
    await _stdoutController.close();
    await _stderrController.close();
    await _stdinController.close();
  }
}
