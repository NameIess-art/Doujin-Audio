import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/media/playback_media_reference.dart';
import 'package:doujin_audio/core/platform/windows_media_tools.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_internal_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_media_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  final toolsDirectory = path.absolute('dist', 'windows', 'app');
  final tools = WindowsMediaTools(executableDirectory: toolsDirectory);
  final unavailable =
      !Platform.isWindows ||
      !File(path.join(toolsDirectory, 'tools', 'ffmpeg.exe')).existsSync();

  test(
    'bundled FFmpeg saves independently decodable HLS chapters in Unicode paths',
    () async {
      final root = await Directory.systemTemp.createTemp('HLS 音频_');
      final playlist = path.join(root.path, 'stream.m3u8');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        final generation = await tools.start('ffmpeg', [
          '-nostdin',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:sample_rate=48000',
          '-t',
          '6',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-hls_time',
          '1',
          '-hls_list_size',
          '0',
          '-f',
          'hls',
          playlist,
        ]);
        final errors = generation.stderr.drain<void>();
        final output = generation.stdout.drain<void>();
        expect(await generation.exitCode, 0);
        await Future.wait([errors, output]);
        server.listen((request) async {
          final file = File(
            path.join(root.path, path.basename(request.uri.path)),
          );
          if (!await file.exists()) {
            request.response.statusCode = 404;
          } else {
            request.response.add(await file.readAsBytes());
          }
          await request.response.close();
        });
        final transfer = AsmrHlsAudioTransfer(
          startProcess: (args) => tools.start('ffmpeg', args),
        );
        for (final range in [(1200, 2700), (3100, 4100)]) {
          final output = File(
            path.join(root.path, '输出 音频 ${range.$1}.m4a.part'),
          );
          await transfer.save(
            reference: PlaybackMediaReference(
              streamUrl: 'http://127.0.0.1:${server.port}/stream.m3u8',
              startMs: range.$1,
              endMs: range.$2,
            ),
            output: output,
            isCancelled: () => false,
          );
          final duration = await tools.readDuration(output.path);
          expect(duration, isNotNull);
          expect(
            duration!.inMilliseconds,
            closeTo(range.$2 - range.$1, 100),
            reason: 'Each saved file must contain only the selected chapter.',
          );
          final decode = await tools.start('ffmpeg', [
            '-nostdin',
            '-v',
            'error',
            '-i',
            output.path,
            '-f',
            'null',
            '-',
          ]);
          final decodeErrors = decode.stderr.drain<void>();
          final decodeOutput = decode.stdout.drain<void>();
          expect(await decode.exitCode, 0);
          await Future.wait([decodeErrors, decodeOutput]);
        }
      } finally {
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: unavailable
        ? 'Requires the bundled Windows FFmpeg distribution.'
        : false,
  );

  test(
    'cancellation terminates real FFmpeg while an HLS segment is stalled',
    () async {
      final root = await Directory.systemTemp.createTemp('hls_interrupt_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      var cancelled = false;
      server.listen((request) async {
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10,\nstalled.ts\n#EXT-X-ENDLIST\n',
          );
          await request.response.close();
        } else {
          request.response.headers.contentType = ContentType('video', 'mp2t');
          await request.response.flush();
          if (!started.isCompleted) started.complete();
        }
      });
      try {
        final transfer = AsmrHlsAudioTransfer(
          startProcess: (args) => tools.start('ffmpeg', args),
        );
        final output = File(path.join(root.path, 'chapter.m4a.part'));
        final saving = transfer.save(
          reference: PlaybackMediaReference(
            streamUrl: 'http://127.0.0.1:${server.port}/stream.m3u8',
            endMs: 1000,
          ),
          output: output,
          isCancelled: () => cancelled,
        );
        final failed = expectLater(saving, throwsA(isA<DownloadCancelled>()));
        await started.future.timeout(const Duration(seconds: 5));
        cancelled = true;
        await failed.timeout(const Duration(seconds: 3));
        expect(await output.exists(), isFalse);
      } finally {
        cancelled = true;
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: unavailable
        ? 'Requires the bundled Windows FFmpeg distribution.'
        : false,
  );
}
