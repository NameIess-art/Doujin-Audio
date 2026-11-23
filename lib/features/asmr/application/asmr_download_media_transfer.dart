import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';

import '../../../core/media/playback_media_reference.dart';
import '../../../core/network/app_network.dart';
import '../../../core/platform/windows_media_tools.dart';
import 'asmr_download_internal_models.dart';
import 'asmr_request_cancellation.dart';

const japaneseAsmrDownloadUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

final RegExp _hxGetAttributePattern = RegExp(
  r'''\bhx-get\s*=\s*["']([^"']+)["']''',
  caseSensitive: false,
);
final RegExp _trailingSlashesPattern = RegExp(r'/+$');

/// The original cannot be transferred; this does not imply it is missing.
class AsmrOriginalUnavailable implements Exception {
  const AsmrOriginalUnavailable();
}

Future<String> resolveAsmrOriginalUrl(HttpClient client, String url) async {
  final uri = Uri.parse(url);
  bool isBuzzheavier(Uri value) =>
      value.host == 'buzzheavier.com' ||
      value.host.endsWith('.buzzheavier.com');
  if (!isBuzzheavier(uri)) return url;

  Future<HttpClientResponse> open(
    Uri target, {
    bool endpoint = false,
    String? referer,
  }) async {
    final request = await client
        .getUrl(target)
        .timeout(const Duration(seconds: 15));
    request.headers.set('User-Agent', japaneseAsmrDownloadUserAgent);
    if (endpoint) request.headers.set('HX-Request', 'true');
    request.headers.set('Referer', referer ?? url);
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode == HttpStatus.forbidden ||
        response.statusCode == HttpStatus.notFound ||
        response.statusCode == HttpStatus.gone) {
      await response.listen(null).cancel();
      throw const AsmrOriginalUnavailable();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.listen(null).cancel();
      throw HttpException(
        'Original link resolution failed: HTTP ${response.statusCode}',
        uri: target,
      );
    }
    return response;
  }

  var endpoint = uri;
  var pageUrl = uri;
  if (!uri.path.endsWith('/download')) {
    final page = await open(uri);
    for (final redirect in page.redirects) {
      pageUrl = pageUrl.resolveUri(redirect.location);
    }
    final type = page.headers.contentType?.mimeType ?? '';
    if (type.startsWith('audio/') ||
        type == 'application/octet-stream' ||
        type == 'application/mp4') {
      await page.listen(null).cancel();
      return pageUrl.toString();
    }
    final body = await page
        .timeout(const Duration(seconds: 15))
        .transform(utf8.decoder)
        .join();
    if (!isBuzzheavier(pageUrl)) {
      throw const FormatException('Original link did not return audio.');
    }
    final attribute = _hxGetAttributePattern
        .firstMatch(body)
        ?.group(1)
        ?.replaceAll('&amp;', '&');
    final parsed = attribute == null ? null : pageUrl.resolve(attribute);
    endpoint =
        parsed != null &&
            isBuzzheavier(parsed) &&
            const ['http', 'https'].contains(parsed.scheme)
        ? parsed
        : pageUrl.replace(
            path: '${pageUrl.path.replaceAll(_trailingSlashesPattern, "")}/download',
          );
  }
  final response = await open(
    endpoint,
    endpoint: true,
    referer: pageUrl.toString(),
  );
  try {
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

Future<bool> hasValidRemuxedM4aStructure(File file) async {
  final fileLength = await file.length();
  if (fileLength < 32) return false;
  final handle = await file.open();
  try {
    var offset = 0;
    var hasFtyp = false;
    var hasPositiveDuration = false;
    var hasAudioTrack = false;
    var hasNonEmptyMdat = false;
    var boxCount = 0;
    final header = Uint8List(16);
    final headerView = ByteData.sublistView(header);

    while (offset + 8 <= fileLength && boxCount < 64) {
      boxCount++;
      await handle.setPosition(offset);
      final read = await handle.readInto(header, 0, 8);
      if (read < 8) return false;
      var boxSize = headerView.getUint32(0);
      final boxType = ascii.decode(header.sublist(4, 8), allowInvalid: true);
      var headerSize = 8;
      if (boxSize == 1) {
        if (offset + 16 > fileLength) return false;
        final extRead = await handle.readInto(header, 8, 16);
        if (extRead < 8) return false;
        boxSize = headerView.getUint64(8);
        headerSize = 16;
      } else if (boxSize == 0) {
        boxSize = fileLength - offset;
      }
      if (boxSize < headerSize || offset + boxSize > fileLength) {
        return false;
      }

      if (boxType == 'ftyp') {
        if (offset == 0 && boxSize >= 16) hasFtyp = true;
      } else if (boxType == 'mdat') {
        if (boxSize > headerSize) hasNonEmptyMdat = true;
      } else if (boxType == 'moov') {
        final payloadSize = boxSize - headerSize;
        if (payloadSize >= 24 && payloadSize <= 2 * 1024 * 1024) {
          await handle.setPosition(offset + headerSize);
          final moovBytes = await handle.read(payloadSize);
          if (moovBytes.length == payloadSize) {
            final parsed = _inspectMoovBox(moovBytes);
            hasPositiveDuration = parsed.hasPositiveDuration;
            hasAudioTrack = parsed.hasAudioTrack;
          }
        }
      }
      offset += boxSize;
    }
    return hasFtyp &&
        hasPositiveDuration &&
        hasAudioTrack &&
        hasNonEmptyMdat &&
        offset == fileLength;
  } catch (_) {
    return false;
  } finally {
    await handle.close();
  }
}

({bool hasPositiveDuration, bool hasAudioTrack}) _inspectMoovBox(
  Uint8List bytes,
) {
  final view = ByteData.sublistView(bytes);
  var hasPositiveDuration = false;
  var hasAudioTrack = false;

  void walkBoxes(
    int start,
    int end,
    void Function(String type, int payloadStart, int payloadEnd) visit,
  ) {
    var cursor = start;
    while (cursor + 8 <= end) {
      var boxSize = view.getUint32(cursor);
      final type = ascii.decode(
        bytes.sublist(cursor + 4, cursor + 8),
        allowInvalid: true,
      );
      var headerSize = 8;
      if (boxSize == 1) {
        if (cursor + 16 > end) return;
        boxSize = view.getUint64(cursor + 8);
        headerSize = 16;
      } else if (boxSize == 0) {
        boxSize = end - cursor;
      }
      if (boxSize < headerSize || cursor + boxSize > end) return;
      visit(type, cursor + headerSize, cursor + boxSize);
      cursor += boxSize;
    }
  }

  walkBoxes(0, bytes.length, (type, payloadStart, payloadEnd) {
    final payloadLength = payloadEnd - payloadStart;
    if (type == 'mvhd' && payloadLength >= 20) {
      final version = bytes[payloadStart];
      if (version == 0) {
        final timescale = view.getUint32(payloadStart + 12);
        final duration = view.getUint32(payloadStart + 16);
        if (timescale > 0 && duration > 0) hasPositiveDuration = true;
      } else if (version == 1 && payloadLength >= 32) {
        final timescale = view.getUint32(payloadStart + 20);
        final duration = view.getUint64(payloadStart + 24);
        if (timescale > 0 && duration > 0) hasPositiveDuration = true;
      }
    } else if (type == 'trak' && !hasAudioTrack) {
      walkBoxes(payloadStart, payloadEnd, (trakChild, mdiaStart, mdiaEnd) {
        if (trakChild != 'mdia' || hasAudioTrack) return;
        walkBoxes(mdiaStart, mdiaEnd, (mdiaChild, hdlrStart, hdlrEnd) {
          if (mdiaChild != 'hdlr' || hdlrEnd - hdlrStart < 12) return;
          if (bytes[hdlrStart + 8] == 0x73 &&
              bytes[hdlrStart + 9] == 0x6f &&
              bytes[hdlrStart + 10] == 0x75 &&
              bytes[hdlrStart + 11] == 0x6e) {
            hasAudioTrack = true;
          }
        });
      });
    }
  });

  return (
    hasPositiveDuration: hasPositiveDuration,
    hasAudioTrack: hasAudioTrack,
  );
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
    AsmrRequestCancellationToken? cancellationToken,
    bool Function()? isCancelled,
    void Function(double fraction)? onProgress,
    void Function(int bytes)? onBytes,
  }) async {
    bool checkCancelled() =>
        (cancellationToken?.isCancelled ?? false) || (isCancelled?.call() ?? false);
    if (!reference.isHls) throw ArgumentError('HLS stream required.');
    if (checkCancelled()) throw const DownloadCancelled();
    await output.parent.create(recursive: true);
    await AppNetwork.instance.ensureStarted();
    try {
      await _run(
        _arguments(reference, output.path),
        cancellationToken: cancellationToken,
        cancelled: checkCancelled,
        progress: (timeMs, bytes) {
          if (bytes >= 0) onBytes?.call(bytes);
          final duration = reference.durationMs;
          if (duration != null && duration > 0) {
            onProgress?.call((timeMs / duration).clamp(0, 1));
          }
        },
      );
      if (checkCancelled()) throw const DownloadCancelled();
      await validateAsmrAudioFile(output);
      // Skip spawning a second FFmpeg decode process when the remuxed M4A
      // passes structural container validation; fall back to a 1-frame decode
      // check only when header validation is inconclusive.
      if (!await hasValidRemuxedM4aStructure(output)) {
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
          cancellationToken: cancellationToken,
          cancelled: checkCancelled,
          progress: (_, _) {},
        );
      }
      onBytes?.call(await output.length());
      onProgress?.call(1);
    } catch (_) {
      try {
        if (await output.exists()) await output.delete();
      } catch (_) {
        // Best-effort cleanup; preserve DownloadCancelled or the original failure.
      }
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
    '-http_proxy',
    AppNetwork.instance.proxyUrl,
    '-user_agent',
    japaneseAsmrDownloadUserAgent,
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
    List<String> arguments, {
    required AsmrRequestCancellationToken? cancellationToken,
    required bool Function() cancelled,
    required void Function(int timeMs, int bytes) progress,
  }) async {
    if (cancelled()) throw const DownloadCancelled();
    if (Platform.isWindows || _startProcess != null) {
      final process =
          await (_startProcess?.call(arguments) ??
              WindowsMediaTools.instance.start('ffmpeg', arguments));
      final errors = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      var timeMs = 0;
      var bytes = -1;
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            if (line.startsWith('out_time_us=')) {
              final value = int.tryParse(line.substring(12));
              if (value != null) timeMs = value ~/ 1000;
            } else if (line.startsWith('total_size=')) {
              bytes = int.tryParse(line.substring(11)) ?? -1;
            } else if (line.startsWith('progress=')) {
              progress(timeMs, bytes);
            }
          });
      if (cancelled()) {
        process.kill();
      }
      final removeListener = cancellationToken?.addListener(process.kill);
      try {
        final code = await process.exitCode;
        await output;
        final error = await errors;
        if (cancelled()) throw const DownloadCancelled();
        if (code != 0) throw ProcessException('ffmpeg', arguments, error, code);
      } finally {
        removeListener?.call();
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
        (statistics) =>
            progress(statistics.getTime().round(), statistics.getSize()),
      );
      if (cancelled()) {
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      }
      final removeListener = cancellationToken?.addListener(
        () => unawaited(FFmpegKit.cancel(session.getSessionId())),
      );
      try {
        final code = await completion.future;
        if (cancelled()) throw const DownloadCancelled();
        if (code != 0) {
          throw FileSystemException(
            'HLS audio processing failed.\n'
            '${await session.getAllLogsAsString() ?? ""}',
          );
        }
      } finally {
        removeListener?.call();
      }
    } else {
      throw UnsupportedError('HLS audio saving requires Android or Windows.');
    }
  }
}
