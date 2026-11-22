import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('windows_media_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

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

  test('missing artwork stream is distinct from an unreadable input', () async {
    final input = File('${directory.path}/voice.wav');
    await input.writeAsBytes([1, 2, 3]);
    var diagnostic = "Stream map '0:v:0' matches no streams.";
    final tools = _Tools((_, _) async => _Process(code: 1, error: diagnostic));
    expect(
      await tools.extractImage(
        input.path,
        videoFrame: false,
        propagateFailure: true,
      ),
      isNull,
    );
    diagnostic = 'Error opening input: Permission denied';
    await expectLater(
      tools.extractImage(input.path, videoFrame: false, propagateFailure: true),
      throwsA(isA<ProcessException>()),
    );
    expect(await tools.extractImage(input.path, videoFrame: false), isNull);
  });

  test(
    'header fast path reads WAV, FLAC, OGG Opus, and M4A without ffprobe',
    () async {
      var ffprobeCalls = 0;
      final tools = _Tools((_, _) async {
        ffprobeCalls++;
        return _Process(output: '999.0\n');
      });

      // 1. PCM WAV: 44100 Hz, 16-bit stereo -> byteRate = 176400, 2.5s -> 441000 bytes
      final wav = File('${directory.path}/sample.wav');
      final wavHeader = ByteData(44);
      final wavBytes = wavHeader.buffer.asUint8List();
      wavBytes.setRange(0, 4, ascii.encode('RIFF'));
      wavHeader.setUint32(4, 36 + 441000, Endian.little);
      wavBytes.setRange(8, 12, ascii.encode('WAVE'));
      wavBytes.setRange(12, 16, ascii.encode('fmt '));
      wavHeader.setUint32(16, 16, Endian.little);
      wavHeader.setUint16(20, 1, Endian.little);
      wavHeader.setUint16(22, 2, Endian.little);
      wavHeader.setUint32(24, 44100, Endian.little);
      wavHeader.setUint32(28, 176400, Endian.little);
      wavHeader.setUint16(32, 4, Endian.little);
      wavHeader.setUint16(34, 16, Endian.little);
      wavBytes.setRange(36, 40, ascii.encode('data'));
      wavHeader.setUint32(40, 441000, Endian.little);
      await wav.writeAsBytes([...wavBytes, ...Uint8List(441000)]);
      expect(
        await tools.readDuration(wav.path),
        const Duration(milliseconds: 2500),
      );

      // 2. FLAC: 48000 Hz, 144000 samples -> 3.0s
      final flac = File('${directory.path}/sample.flac');
      final flacBytes = Uint8List(42);
      flacBytes.setRange(0, 4, ascii.encode('fLaC'));
      flacBytes[4] = 0x80;
      flacBytes[7] = 34;
      const flacRate = 48000;
      const flacSamples = 144000;
      flacBytes[18] = (flacRate >> 12) & 0xFF;
      flacBytes[19] = (flacRate >> 4) & 0xFF;
      flacBytes[20] = ((flacRate & 0x0F) << 4) | 0x02;
      flacBytes[21] = (flacSamples >> 32) & 0x0F;
      flacBytes[22] = (flacSamples >> 24) & 0xFF;
      flacBytes[23] = (flacSamples >> 16) & 0xFF;
      flacBytes[24] = (flacSamples >> 8) & 0xFF;
      flacBytes[25] = flacSamples & 0xFF;
      await flac.writeAsBytes(flacBytes);
      expect(await tools.readDuration(flac.path), const Duration(seconds: 3));

      // 3. OGG Opus: 48000 Hz, preSkip=312, granule=192312 -> 4.0s
      final opus = File('${directory.path}/sample.opus');
      final bosPayload = Uint8List(19);
      bosPayload.setRange(0, 8, ascii.encode('OpusHead'));
      ByteData.sublistView(bosPayload).setUint16(10, 312, Endian.little);
      Uint8List buildOggPage(
        int headerType,
        int granule,
        int serial,
        Uint8List payload,
      ) {
        final page = Uint8List(28 + payload.length);
        page.setRange(0, 4, ascii.encode('OggS'));
        page[4] = 0;
        page[5] = headerType;
        final bd = ByteData.sublistView(page);
        bd.setInt64(6, granule, Endian.little);
        bd.setUint32(14, serial, Endian.little);
        page[26] = 1;
        page[27] = payload.length;
        page.setRange(28, 28 + payload.length, payload);
        return page;
      }

      await opus.writeAsBytes([
        ...buildOggPage(0x02, 0, 42, bosPayload),
        ...buildOggPage(0x04, 192312, 42, Uint8List(4)),
      ]);
      expect(await tools.readDuration(opus.path), const Duration(seconds: 4));

      // 4. M4A (ISO BMFF): ftyp + moov/mvhd v0 (timescale=1000, duration=5250 -> 5.25s)
      final m4a = File('${directory.path}/sample.m4a');
      final ftyp = Uint8List(16);
      ByteData.sublistView(ftyp).setUint32(0, 16);
      ftyp.setRange(4, 8, ascii.encode('ftyp'));
      ftyp.setRange(8, 12, ascii.encode('M4A '));
      final mvhd = Uint8List(32);
      final mvhdBd = ByteData.sublistView(mvhd);
      mvhdBd.setUint32(0, 32);
      mvhd.setRange(4, 8, ascii.encode('mvhd'));
      mvhd[8] = 0;
      mvhdBd.setUint32(8 + 12, 1000);
      mvhdBd.setUint32(8 + 16, 5250);
      final moov = Uint8List(8 + mvhd.length);
      ByteData.sublistView(moov).setUint32(0, moov.length);
      moov.setRange(4, 8, ascii.encode('moov'));
      moov.setRange(8, moov.length, mvhd);
      await m4a.writeAsBytes([...ftyp, ...moov]);
      expect(
        await tools.readDuration(m4a.path),
        const Duration(milliseconds: 5250),
      );

      expect(ffprobeCalls, 0);

      // 5. Corrupt WAV falls back to ffprobe.
      final corruptWav = File('${directory.path}/corrupt.wav');
      await corruptWav.writeAsBytes(Uint8List(64));
      expect(
        await tools.readDuration(corruptWav.path),
        const Duration(seconds: 999),
      );
      expect(ffprobeCalls, 1);
    },
  );

  test(
    'concurrent extractImage returns shared output when rename hits FileSystemException',
    () async {
      final input = File('${directory.path}/movie.mp4');
      await input.writeAsBytes([1, 2, 3, 4]);
      final tools = _Tools((_, arguments) async {
        final temporary = File(arguments.last);
        await temporary.writeAsBytes([0xFF, 0xD8, 0xFF, 0xD9]);
        return _Process();
      });

      final firstOutput = await tools.extractImage(
        input.path,
        videoFrame: true,
      );
      expect(firstOutput, isNotNull);
      await File(firstOutput!).delete();

      final racedTools = _Tools((_, arguments) async {
        final temporary = File(arguments.last);
        await temporary.writeAsBytes([0xFF, 0xD8, 0xFF, 0xD9]);
        return _Process();
      });

      final outerZone = Zone.current;
      final result = await IOOverrides.runZoned(
        () => racedTools.extractImage(input.path, videoFrame: true),
        createFile: (filePath) {
          final realFile = outerZone.run(() => File(filePath));
          if (filePath.endsWith('image.jpg')) {
            return _RacingRenameFile(
              realFile,
              outerZone.run(() => File(firstOutput)),
            );
          }
          return realFile;
        },
      );

      expect(result, firstOutput);
      expect(await File(firstOutput).exists(), isTrue);
      final frameDir = Directory('${directory.path}/video_frames');
      final scratchDirs = frameDir
          .listSync()
          .whereType<Directory>()
          .where((dir) => dir.path.contains('extract_'));
      expect(scratchDirs, isEmpty);
    },
  );
}

class _RacingRenameFile implements File {
  _RacingRenameFile(this._inner, this._concurrentOutput);

  final File _inner;
  final File _concurrentOutput;

  @override
  Future<File> rename(String newPath) async {
    await _concurrentOutput.writeAsBytes([0xFF, 0xD8, 0xFF, 0xD9]);
    throw FileSystemException('Sharing violation', newPath);
  }

  @override
  String get path => _inner.path;

  @override
  Future<bool> exists() => _inner.exists();

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => _inner.writeAsBytes(bytes, mode: mode, flush: flush);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
