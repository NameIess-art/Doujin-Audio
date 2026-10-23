import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import '../../../core/media/playback_media_reference.dart';
import '../../../core/platform/windows_media_tools.dart';
import 'asmr_download_internal_models.dart';

/// Only a confirmed missing original permits choosing the HLS representation.
class AsmrOriginalUnavailable implements Exception {
  const AsmrOriginalUnavailable();
}

Future<String> resolveAsmrOriginalUrl(HttpClient client, String url) async {
  final uri = Uri.parse(url);
  if (uri.host != 'buzzheavier.com' && uri.host != 'www.buzzheavier.com') {
    return url;
  }
  final endpoint = uri.path.endsWith('/download')
      ? uri
      : uri.replace(
          path: '${uri.path.replaceAll(RegExp(r"/+$"), "")}/download',
        );
  final request = await client
      .getUrl(endpoint)
      .timeout(const Duration(seconds: 15));
  request.headers.set('User-Agent', 'Doujin Audio downloader');
  request.headers.set('HX-Request', 'true');
  request.headers.set('Referer', url);
  final response = await request.close().timeout(const Duration(seconds: 15));
  try {
    if (response.statusCode == 404 || response.statusCode == 410) {
      throw const AsmrOriginalUnavailable();
    }
    if (response.statusCode != 200) {
      throw HttpException(
        'Original link resolution failed: HTTP ${response.statusCode}',
        uri: endpoint,
      );
    }
    final redirect = response.headers.value('HX-Redirect');
    final target = redirect == null ? null : endpoint.resolve(redirect);
    if (target == null || !const ['http', 'https'].contains(target.scheme)) {
      throw const FormatException('Original link did not contain HX-Redirect.');
    }
    return target.toString();
  } finally {
    await response.listen(null).cancel();
  }
}

Future<void> validateAsmrAudioFile(File file) async {
  final handle = await file.open();
  try {
    final bytes = await handle.read(32);
    final text = ascii
        .decode(bytes, allowInvalid: true)
        .trimLeft()
        .toLowerCase();
    final audio =
        bytes.length >= 4 &&
        (text.startsWith('id3') ||
            text.startsWith('riff') ||
            text.startsWith('flac') ||
            text.startsWith('oggs') ||
            (bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0) ||
            (bytes.length >= 8 &&
                ascii.decode(bytes.sublist(4, 8), allowInvalid: true) ==
                    'ftyp') ||
            (bytes[0] == 0x1a &&
                bytes[1] == 0x45 &&
                bytes[2] == 0xdf &&
                bytes[3] == 0xa3));
    if (!audio) {
      throw const FormatException(
        'Downloaded content is not a supported audio file.',
      );
    }
  } finally {
    await handle.close();
  }
}

/// Uses the existing platform FFmpeg distributions and is shared by downloads
/// and playback caching. Interruption owns and stops only this invocation.
class AsmrHlsAudioTransfer {
  AsmrHlsAudioTransfer({Future<Process> Function(List<String>)? startProcess})
    : _startProcess = startProcess;

  final Future<Process> Function(List<String>)? _startProcess;
  Future<void> save({
    required PlaybackMediaReference reference,
    required File output,
    required bool Function() isCancelled,
    void Function(double fraction)? onProgress,
  }) async {
    if (!reference.isHls) throw ArgumentError('HLS stream required.');
    if (isCancelled()) throw const DownloadCancelled();
    await output.parent.create(recursive: true);
    try {
      await _run(_arguments(reference, output.path), isCancelled, (timeMs) {
        final duration = reference.durationMs;
        if (duration != null && duration > 0) {
          onProgress?.call((timeMs / duration).clamp(0, 1));
        }
      });
      if (isCancelled()) throw const DownloadCancelled();
      await validateAsmrAudioFile(output);
      // Decode the first audio frame before committing a remotely generated file.
      await _run(
        [
          '-nostdin',
          '-v',
          'error',
          '-i',
          output.path,
          '-map',
          '0:a:0',
          '-frames:a',
          '1',
          '-f',
          'null',
          '-',
        ],
        isCancelled,
        (_) {},
      );
      onProgress?.call(1);
    } catch (_) {
      if (await output.exists()) await output.delete();
      rethrow;
    }
  }

  static List<String> _arguments(
    PlaybackMediaReference reference,
    String output,
  ) => [
    '-nostdin',
    '-y',
    '-v',
    'error',
    '-rw_timeout',
    '30000000',
    '-user_agent',
    'Doujin Audio downloader',
    if (reference.httpHeaders.isNotEmpty) ...[
      '-headers',
      reference.httpHeaders.entries
          .map((e) => '${e.key}: ${e.value}\r\n')
          .join(),
    ],
    if (reference.startMs > 0) ...[
      '-ss',
      (reference.startMs / 1000).toStringAsFixed(3),
    ],
    '-i',
    reference.streamUrl,
    if (reference.durationMs != null) ...[
      '-t',
      (reference.durationMs! / 1000).toStringAsFixed(3),
    ],
    '-map',
    '0:a:0',
    '-vn',
    '-c:a',
    'copy',
    '-movflags',
    '+faststart',
    '-progress',
    'pipe:1',
    '-f',
    'ipod',
    output,
  ];

  Future<void> _run(
    List<String> arguments,
    bool Function() cancelled,
    void Function(int) progress,
  ) async {
    if (cancelled()) throw const DownloadCancelled();
    if (Platform.isWindows || _startProcess != null) {
      final process =
          await (_startProcess?.call(arguments) ??
              WindowsMediaTools.instance.start('ffmpeg', arguments));
      final errors = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            if (line.startsWith('out_time_us=')) {
              final value = int.tryParse(line.substring(12));
              if (value != null) progress(value ~/ 1000);
            }
          });
      final timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        if (cancelled()) process.kill();
      });
      try {
        final code = await process.exitCode;
        await output;
        final error = await errors;
        if (cancelled()) throw const DownloadCancelled();
        if (code != 0) throw ProcessException('ffmpeg', arguments, error, code);
      } finally {
        timer.cancel();
      }
    } else if (Platform.isAndroid) {
      final completion = Completer<int>();
      final session = await FFmpegKit.executeWithArgumentsAsync(
        arguments,
        (result) async {
          final code = await result.getReturnCode();
          if (!completion.isCompleted) {
            completion.complete(ReturnCode.isSuccess(code) ? 0 : 1);
          }
        },
        null,
        (statistics) => progress(statistics.getTime().round()),
      );
      final timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        if (cancelled()) unawaited(FFmpegKit.cancel(session.getSessionId()));
      });
      try {
        final code = await completion.future;
        if (cancelled()) throw const DownloadCancelled();
        if (code != 0) {
          throw const FileSystemException('HLS audio processing failed.');
        }
      } finally {
        timer.cancel();
      }
    } else {
      throw UnsupportedError('HLS audio saving requires Android or Windows.');
    }
  }
}
