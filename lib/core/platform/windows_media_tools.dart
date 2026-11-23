import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// The installer ships both tools beside the application, never on PATH.
class WindowsMediaTools {
  WindowsMediaTools({String? executableDirectory})
    : _directory =
          executableDirectory ?? path.dirname(Platform.resolvedExecutable);

  static final instance = WindowsMediaTools();
  static const Set<String> _fastHeaderDurationExtensions = <String>{
    '.mp3',
    '.wav',
    '.flac',
    '.ogg',
    '.oga',
    '.opus',
    '.m4a',
    '.mp4',
    '.m4b',
    '.mov',
  };

  final String _directory;
  final Map<String, String> _verifiedToolPaths = <String, String>{};

  Future<Process> start(String tool, List<String> arguments) async {
    if (tool != 'ffmpeg' && tool != 'ffprobe') {
      throw ArgumentError.value(tool, 'tool');
    }
    var executable = _verifiedToolPaths[tool];
    if (executable == null) {
      final candidate = path.join(_directory, 'tools', '$tool.exe');
      if (!await File(candidate).exists()) {
        throw FileSystemException('Bundled media tool is missing', candidate);
      }
      _verifiedToolPaths[tool] = executable = candidate;
    }
    // Normal mode redirects all handles and Dart starts Windows children without
    // a console. No shell parsing: spaces and metacharacters stay in arguments.
    try {
      return await Process.start(executable, arguments);
    } on ProcessException {
      _verifiedToolPaths.remove(tool);
      rethrow;
    }
  }

  Future<({int exitCode, String output, String error})> _run(
    String tool,
    List<String> arguments,
  ) async {
    final process = await start(tool, arguments);
    final output = process.stdout.transform(utf8.decoder).join();
    final error = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 30),
      );
      return (exitCode: exitCode, output: await output, error: await error);
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      await Future.wait([output, error]);
      rethrow;
    }
  }

  Future<Duration?> readDuration(
    String mediaPath, {
    bool skipHeaderParse = false,
  }) async {
    final extension = path.extension(mediaPath).toLowerCase();
    if (!skipHeaderParse && _fastHeaderDurationExtensions.contains(extension)) {
      final parsed = await _readHeaderDurationInBackground(
        mediaPath,
        extension,
      );
      if (parsed != null && parsed > Duration.zero) return parsed;
    }
    final result = await _run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=noprint_wrappers=1:nokey=1',
      '-i',
      mediaPath,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'ffprobe',
        [mediaPath],
        result.error,
        result.exitCode,
      );
    }
    final seconds = double.tryParse(result.output.trim());
    if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
    return Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round(),
    );
  }

  /// Parses header durations for a batch of media paths in a single background
  /// isolate. Paths that cannot be parsed from headers are omitted or mapped to
  /// `null` so callers can fall back to `ffprobe`.
  Future<Map<String, Duration?>> readHeaderDurationsBatch(
    List<String> mediaPaths,
  ) async {
    final eligible = <(String, String)>[];
    for (final mediaPath in mediaPaths) {
      final extension = path.extension(mediaPath).toLowerCase();
      if (_fastHeaderDurationExtensions.contains(extension)) {
        eligible.add((mediaPath, extension));
      }
    }
    if (eligible.isEmpty) return const <String, Duration?>{};
    if (IOOverrides.current != null) {
      return _readHeaderDurationsBatch(eligible);
    }
    return Isolate.run(() => _readHeaderDurationsBatch(eligible));
  }

  static Future<Duration?> _readHeaderDurationInBackground(
    String mediaPath,
    String extension,
  ) {
    if (IOOverrides.current != null) {
      return _readHeaderDuration(mediaPath, extension);
    }
    return Isolate.run(() => _readHeaderDuration(mediaPath, extension));
  }

  Future<String?> extractImage(
    String mediaPath, {
    required bool videoFrame,
    bool propagateFailure = false,
  }) async {
    final stat = await File(mediaPath).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    final key = sha256.convert(
      utf8.encode(
        '$mediaPath:${stat.modified.microsecondsSinceEpoch}:${stat.size}:$videoFrame',
      ),
    );
    final directory = Directory(
      path.join(
        (await getTemporaryDirectory()).path,
        videoFrame ? 'video_frames' : 'embedded_covers',
      ),
    );
    await directory.create(recursive: true);
    final output = File(path.join(directory.path, '$key.jpg'));
    if (await output.exists()) return output.path;
    // Separate scratch directories also make concurrent requests for a cover safe.
    final work = await directory.createTemp('extract_');
    final temporary = File(path.join(work.path, 'image.jpg'));
    try {
      final result = await _run('ffmpeg', [
        '-nostdin',
        '-v',
        'error',
        '-i',
        mediaPath,
        '-map',
        videoFrame ? '0:V:0' : '0:v:0',
        '-frames:v',
        '1',
        '-vf',
        'scale=640:640:force_original_aspect_ratio=decrease',
        '-q:v',
        '3',
        temporary.path,
      ]);
      // A missing stream is an authoritative absence; I/O and decoder failures
      // must remain retryable instead of entering a caller's negative cache.
      if (result.exitCode != 0) {
        if (propagateFailure && !result.error.contains('matches no streams')) {
          throw ProcessException(
            'ffmpeg',
            [mediaPath],
            result.error,
            result.exitCode,
          );
        }
        return null;
      }
      if (!await temporary.exists()) return null;
      if (await output.exists()) return output.path;
      try {
        await temporary.rename(output.path);
      } on FileSystemException {
        if (await output.exists()) return output.path;
        rethrow;
      }
      return output.path;
    } finally {
      await work.delete(recursive: true);
    }
  }
}

Future<Map<String, Duration?>> _readHeaderDurationsBatch(
  List<(String, String)> items,
) async {
  final results = <String, Duration?>{};
  for (final (mediaPath, extension) in items) {
    final parsed = await _readHeaderDuration(mediaPath, extension);
    if (parsed != null && parsed > Duration.zero) {
      results[mediaPath] = parsed;
    }
  }
  return results;
}

Future<Duration?> _readHeaderDuration(
  String mediaPath,
  String extension,
) async {
  RandomAccessFile? raf;
  try {
    final file = File(mediaPath);
    if (!await file.exists()) return null;
    raf = await file.open();
    final fileLength = await raf.length();
    if (fileLength < 32) return null;
    return switch (extension) {
      '.mp3' => await _parseMp3Duration(raf, fileLength),
      '.wav' => await _parseWavDuration(raf, fileLength),
      '.flac' => await _parseFlacDuration(raf, fileLength),
      '.ogg' || '.oga' || '.opus' => await _parseOggDuration(raf, fileLength),
      '.m4a' ||
      '.mp4' ||
      '.m4b' ||
      '.mov' => await _parseMp4Duration(raf, fileLength),
      _ => null,
    };
  } catch (_) {
    return null;
  } finally {
    try {
      await raf?.close();
    } catch (_) {
      // Ignore close errors on fast-path probe.
    }
  }
}

const List<int> _mp3Mpeg1SampleRates = <int>[44100, 48000, 32000];
const List<int> _mp3Mpeg2SampleRates = <int>[22050, 24000, 16000];
const List<int> _mp3Mpeg25SampleRates = <int>[11025, 12000, 8000];
const List<int> _mp3Mpeg1Layer3Bitrates = <int>[
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
];
const List<int> _mp3Mpeg2Layer3Bitrates = <int>[
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
];

({
  int versionId,
  int sampleRate,
  int bitrateKbps,
  int samplesPerFrame,
  int frameLength,
  int channelMode,
})?
_tryParseMp3Layer3Frame(Uint8List data, int pos) {
  if (pos + 4 > data.length) return null;
  final b0 = data[pos];
  final b1 = data[pos + 1];
  if (b0 != 0xFF || (b1 & 0xE0) != 0xE0) return null;
  final versionId = (b1 >> 3) & 0x03;
  final layerId = (b1 >> 1) & 0x03;
  // Restrict to MPEG 1 / 2 / 2.5 Layer III; other layers defer to ffprobe.
  if (versionId == 1 || layerId != 1) return null;
  final b2 = data[pos + 2];
  final bitrateIndex = (b2 >> 4) & 0x0F;
  final sampleRateIndex = (b2 >> 2) & 0x03;
  if (bitrateIndex == 0 || bitrateIndex == 15 || sampleRateIndex == 3) {
    return null;
  }
  final padding = (b2 >> 1) & 0x01;
  final channelMode = (data[pos + 3] >> 6) & 0x03;
  final isMpeg1 = versionId == 3;
  final sampleRate = switch (versionId) {
    3 => _mp3Mpeg1SampleRates[sampleRateIndex],
    2 => _mp3Mpeg2SampleRates[sampleRateIndex],
    _ => _mp3Mpeg25SampleRates[sampleRateIndex],
  };
  final bitrateKbps = isMpeg1
      ? _mp3Mpeg1Layer3Bitrates[bitrateIndex]
      : _mp3Mpeg2Layer3Bitrates[bitrateIndex];
  final samplesPerFrame = isMpeg1 ? 1152 : 576;
  final frameLength =
      ((isMpeg1 ? 144000 : 72000) * bitrateKbps) ~/ sampleRate + padding;
  if (frameLength < 24) return null;
  return (
    versionId: versionId,
    sampleRate: sampleRate,
    bitrateKbps: bitrateKbps,
    samplesPerFrame: samplesPerFrame,
    frameLength: frameLength,
    channelMode: channelMode,
  );
}

Future<Duration?> _parseMp3Duration(
  RandomAccessFile raf,
  int fileLength,
) async {
  var offset = 0;
  for (var tags = 0; tags < 4 && offset + 10 <= fileLength; tags++) {
    await raf.setPosition(offset);
    final header = await raf.read(10);
    if (header.length < 10 ||
        header[0] != 0x49 ||
        header[1] != 0x44 ||
        header[2] != 0x33 ||
        header[3] == 0xFF ||
        header[4] == 0xFF ||
        (header[6] & 0x80) != 0 ||
        (header[7] & 0x80) != 0 ||
        (header[8] & 0x80) != 0 ||
        (header[9] & 0x80) != 0) {
      break;
    }
    final tagSize =
        ((header[6] & 0x7F) << 21) |
        ((header[7] & 0x7F) << 14) |
        ((header[8] & 0x7F) << 7) |
        (header[9] & 0x7F);
    final footer = (header[5] & 0x10) != 0 ? 10 : 0;
    final nextOffset = offset + 10 + tagSize + footer;
    if (nextOffset <= offset || nextOffset >= fileLength) return null;
    offset = nextOffset;
  }

  var audioEnd = fileLength;
  if (audioEnd - offset >= 128) {
    await raf.setPosition(audioEnd - 128);
    final tag = await raf.read(3);
    if (tag.length == 3 &&
        tag[0] == 0x54 &&
        tag[1] == 0x41 &&
        tag[2] == 0x47) {
      // Trailing ID3v1 tag ('TAG').
      audioEnd -= 128;
    }
  }
  if (audioEnd - offset >= 32) {
    await raf.setPosition(audioEnd - 32);
    final ape = await raf.read(32);
    if (ape.length == 32 &&
        ape[0] == 0x41 &&
        ape[1] == 0x50 &&
        ape[2] == 0x45 &&
        ape[3] == 0x54 &&
        ape[4] == 0x41 &&
        ape[5] == 0x47 &&
        ape[6] == 0x45 &&
        ape[7] == 0x58) {
      // Trailing APEv2 tag ('APETAGEX').
      final apeBd = ByteData.sublistView(ape);
      final apeSize = apeBd.getUint32(12, Endian.little);
      final apeFlags = apeBd.getUint32(20, Endian.little);
      final apeTotal = apeSize + ((apeFlags & 0x80000000) != 0 ? 32 : 0);
      if (apeTotal > 0 && audioEnd - apeTotal > offset) {
        audioEnd -= apeTotal;
      }
    }
  }

  final available = audioEnd - offset;
  if (available < 32) return null;
  final scanLen = available < 65536 ? available : 65536;
  await raf.setPosition(offset);
  final buf = await raf.read(scanLen);
  if (buf.length < 32) return null;
  final bd = ByteData.sublistView(buf);

  for (var i = 0; i <= buf.length - 4; i++) {
    final first = _tryParseMp3Layer3Frame(buf, i);
    if (first == null) continue;

    // 1. Check Xing / Info VBR/CBR header inside the first frame.
    final isMono = first.channelMode == 3;
    final sideInfoSize = first.versionId == 3
        ? (isMono ? 17 : 32)
        : (isMono ? 9 : 17);
    final xingOffset = i + 4 + sideInfoSize;
    if (xingOffset + 12 <= buf.length &&
        xingOffset + 12 <= i + first.frameLength) {
      final isXing =
          buf[xingOffset] == 0x58 &&
          buf[xingOffset + 1] == 0x69 &&
          buf[xingOffset + 2] == 0x6E &&
          buf[xingOffset + 3] == 0x67;
      final isInfo =
          buf[xingOffset] == 0x49 &&
          buf[xingOffset + 1] == 0x6E &&
          buf[xingOffset + 2] == 0x66 &&
          buf[xingOffset + 3] == 0x6F;
      if (isXing || isInfo) {
        final flags = bd.getUint32(xingOffset + 4);
        if ((flags & 0x01) != 0) {
          final totalFrames = bd.getUint32(xingOffset + 8);
          if (totalFrames > 0) {
            final micros =
                (totalFrames *
                        first.samplesPerFrame /
                        first.sampleRate *
                        Duration.microsecondsPerSecond)
                    .round();
            return micros > 0 ? Duration(microseconds: micros) : null;
          }
        }
        // Xing/Info header without frame count: defer to ffprobe.
        return null;
      }
    }

    // 2. Check VBRI header inside the first frame (fixed offset 36).
    final vbriOffset = i + 36;
    if (vbriOffset + 18 <= buf.length &&
        vbriOffset + 18 <= i + first.frameLength &&
        buf[vbriOffset] == 0x56 &&
        buf[vbriOffset + 1] == 0x42 &&
        buf[vbriOffset + 2] == 0x52 &&
        buf[vbriOffset + 3] == 0x49) {
      final totalFrames = bd.getUint32(vbriOffset + 14);
      if (totalFrames > 0) {
        final micros =
            (totalFrames *
                    first.samplesPerFrame /
                    first.sampleRate *
                    Duration.microsecondsPerSecond)
                .round();
        return micros > 0 ? Duration(microseconds: micros) : null;
      }
      return null;
    }

    // 3. Validate consecutive frames to confirm sync and detect CBR vs VBR.
    var pos = i + first.frameLength;
    var verifiedFrames = 1;
    var isCbr = true;
    while (verifiedFrames < 16 && pos + 4 <= buf.length) {
      final next = _tryParseMp3Layer3Frame(buf, pos);
      if (next == null ||
          next.versionId != first.versionId ||
          next.sampleRate != first.sampleRate) {
        break;
      }
      if (next.bitrateKbps != first.bitrateKbps) {
        isCbr = false;
      }
      verifiedFrames++;
      pos += next.frameLength;
    }
    if (verifiedFrames < 3) {
      // Not enough consecutive frames to trust sync; keep scanning.
      continue;
    }
    if (!isCbr) {
      // VBR without Xing/VBRI header: defer to ffprobe for exact duration.
      return null;
    }

    final audioBytes = audioEnd - (offset + i);
    if (audioBytes <= 0) return null;

    // Sample midpoint for large files to guard against VBR streams that begin
    // with several constant-bitrate frames.
    if (audioBytes > scanLen + 4096) {
      final midPos = offset + i + (audioBytes >> 1);
      await raf.setPosition(midPos);
      final mid = await raf.read(4096);
      for (var j = 0; j <= mid.length - 4; j++) {
        final f1 = _tryParseMp3Layer3Frame(mid, j);
        if (f1 == null ||
            f1.versionId != first.versionId ||
            f1.sampleRate != first.sampleRate) {
          continue;
        }
        final f2Pos = j + f1.frameLength;
        if (f2Pos + 4 > mid.length) continue;
        final f2 = _tryParseMp3Layer3Frame(mid, f2Pos);
        if (f2 == null ||
            f2.versionId != first.versionId ||
            f2.sampleRate != first.sampleRate) {
          continue;
        }
        if (f1.bitrateKbps != first.bitrateKbps ||
            f2.bitrateKbps != first.bitrateKbps) {
          return null;
        }
        break;
      }
    }

    final micros =
        (audioBytes *
                8.0 /
                (first.bitrateKbps * 1000.0) *
                Duration.microsecondsPerSecond)
            .round();
    return micros > 0 ? Duration(microseconds: micros) : null;
  }
  return null;
}

Future<Duration?> _parseWavDuration(
  RandomAccessFile raf,
  int fileLength,
) async {
  if (fileLength < 44) return null;
  final header = await raf.read(12);
  if (header.length < 12 ||
      header[0] != 0x52 ||
      header[1] != 0x49 ||
      header[2] != 0x46 ||
      header[3] != 0x46 || // RIFF
      header[8] != 0x57 ||
      header[9] != 0x41 ||
      header[10] != 0x56 ||
      header[11] != 0x45) {
    // WAVE
    return null;
  }
  int? byteRate;
  int? dataSize;
  var offset = 12;
  for (var chunks = 0; chunks < 64 && offset + 8 <= fileLength; chunks++) {
    await raf.setPosition(offset);
    final chunkHeader = await raf.read(8);
    if (chunkHeader.length < 8) return null;
    final bd = ByteData.sublistView(chunkHeader);
    final chunkSize = bd.getUint32(4, Endian.little);
    final isFmt =
        chunkHeader[0] == 0x66 &&
        chunkHeader[1] == 0x6D &&
        chunkHeader[2] == 0x74 &&
        chunkHeader[3] == 0x20;
    final isData =
        chunkHeader[0] == 0x64 &&
        chunkHeader[1] == 0x61 &&
        chunkHeader[2] == 0x74 &&
        chunkHeader[3] == 0x61;
    if (isFmt) {
      if (chunkSize < 16 || offset + 8 + 16 > fileLength) return null;
      final readLen = chunkSize < 40 ? chunkSize : 40;
      final fmt = await raf.read(readLen);
      if (fmt.length < 16) return null;
      final fmtBd = ByteData.sublistView(fmt);
      final formatTag = fmtBd.getUint16(0, Endian.little);
      final validPcm =
          formatTag == 1 ||
          formatTag == 3 ||
          (formatTag == 0xFFFE &&
              fmt.length >= 26 &&
              (fmtBd.getUint16(24, Endian.little) == 1 ||
                  fmtBd.getUint16(24, Endian.little) == 3));
      if (!validPcm) return null;
      final rate = fmtBd.getUint32(8, Endian.little);
      if (rate <= 0) return null;
      byteRate = rate;
    } else if (isData) {
      if (chunkSize <= 0 || chunkSize == 0xFFFFFFFF) return null;
      if (offset + 8 + chunkSize > fileLength + 1024) return null;
      dataSize = chunkSize;
    }
    if (byteRate != null && dataSize != null) {
      final micros = (dataSize / byteRate * Duration.microsecondsPerSecond)
          .round();
      return micros > 0 ? Duration(microseconds: micros) : null;
    }
    final nextOffset = offset + 8 + chunkSize + (chunkSize & 1);
    if (nextOffset <= offset) return null;
    offset = nextOffset;
  }
  return null;
}

Future<Duration?> _parseFlacDuration(
  RandomAccessFile raf,
  int fileLength,
) async {
  if (fileLength < 42) return null;
  var offset = 0;
  final prefix = await raf.read(10);
  if (prefix.length < 10) return null;
  if (prefix[0] == 0x49 && prefix[1] == 0x44 && prefix[2] == 0x33) {
    // Skip leading ID3v2 tag.
    final tagSize =
        ((prefix[6] & 0x7F) << 21) |
        ((prefix[7] & 0x7F) << 14) |
        ((prefix[8] & 0x7F) << 7) |
        (prefix[9] & 0x7F);
    final footer = (prefix[5] & 0x10) != 0 ? 10 : 0;
    offset = 10 + tagSize + footer;
    if (offset + 42 > fileLength) return null;
  }
  await raf.setPosition(offset);
  final header = await raf.read(42);
  if (header.length < 42 ||
      header[0] != 0x66 ||
      header[1] != 0x4C ||
      header[2] != 0x61 ||
      header[3] != 0x43) {
    // fLaC
    return null;
  }
  final blockType = header[4] & 0x7F;
  final blockLength = (header[5] << 16) | (header[6] << 8) | header[7];
  if (blockType != 0 || blockLength < 34) return null;
  final sampleRate = (header[18] << 12) | (header[19] << 4) | (header[20] >> 4);
  final totalSamples =
      ((header[21] & 0x0F) << 32) |
      (header[22] << 24) |
      (header[23] << 16) |
      (header[24] << 8) |
      header[25];
  if (sampleRate <= 0 || totalSamples <= 0) return null;
  final micros = (totalSamples / sampleRate * Duration.microsecondsPerSecond)
      .round();
  return micros > 0 ? Duration(microseconds: micros) : null;
}

Future<Duration?> _parseOggDuration(
  RandomAccessFile raf,
  int fileLength,
) async {
  if (fileLength < 58) return null;
  final headLen = fileLength < 512 ? fileLength : 512;
  final head = await raf.read(headLen);
  if (head.length < 46 ||
      head[0] != 0x4F ||
      head[1] != 0x67 ||
      head[2] != 0x67 ||
      head[3] != 0x53 || // OggS
      head[4] != 0) {
    return null;
  }
  final headBd = ByteData.sublistView(head);
  final serial = headBd.getUint32(14, Endian.little);
  final numSegments = head[26];
  final payloadOffset = 27 + numSegments;
  if (payloadOffset + 19 > head.length) return null;

  int sampleRate;
  var preSkip = 0;
  final isVorbis =
      head[payloadOffset] == 0x01 &&
      head[payloadOffset + 1] == 0x76 && // v
      head[payloadOffset + 2] == 0x6F && // o
      head[payloadOffset + 3] == 0x72 && // r
      head[payloadOffset + 4] == 0x62 && // b
      head[payloadOffset + 5] == 0x69 && // i
      head[payloadOffset + 6] == 0x73; // s
  final isOpus =
      head[payloadOffset] == 0x4F && // O
      head[payloadOffset + 1] == 0x70 && // p
      head[payloadOffset + 2] == 0x75 && // u
      head[payloadOffset + 3] == 0x73 && // s
      head[payloadOffset + 4] == 0x48 && // H
      head[payloadOffset + 5] == 0x65 && // e
      head[payloadOffset + 6] == 0x61 && // a
      head[payloadOffset + 7] == 0x64; // d
  if (isVorbis) {
    sampleRate = headBd.getUint32(payloadOffset + 12, Endian.little);
  } else if (isOpus) {
    sampleRate = 48000;
    preSkip = headBd.getUint16(payloadOffset + 10, Endian.little);
  } else {
    return null;
  }
  if (sampleRate <= 0) return null;

  final tailLen = fileLength < 65536 ? fileLength : 65536;
  await raf.setPosition(fileLength - tailLen);
  final tail = await raf.read(tailLen);
  if (tail.length < 27) return null;
  final tailBd = ByteData.sublistView(tail);
  for (var i = tail.length - 27; i >= 0; i--) {
    if (tail[i] != 0x4F ||
        tail[i + 1] != 0x67 ||
        tail[i + 2] != 0x67 ||
        tail[i + 3] != 0x53 ||
        tail[i + 4] != 0) {
      continue;
    }
    final headerType = tail[i + 5];
    final pageSerial = tailBd.getUint32(i + 14, Endian.little);
    if (pageSerial != serial) {
      // Chained or multiplexed OGG stream: defer to ffprobe.
      if ((headerType & 0x04) != 0) return null;
      continue;
    }
    if ((headerType & 0x04) == 0) continue;
    final granule = tailBd.getInt64(i + 6, Endian.little);
    if (granule <= preSkip) return null;
    final micros =
        ((granule - preSkip) / sampleRate * Duration.microsecondsPerSecond)
            .round();
    return micros > 0 ? Duration(microseconds: micros) : null;
  }
  return null;
}

Future<Duration?> _parseMp4Duration(
  RandomAccessFile raf,
  int fileLength,
) async {
  var hasFtyp = false;
  Duration? mvhdDuration;
  var offset = 0;
  for (var boxes = 0; boxes < 128 && offset + 8 <= fileLength; boxes++) {
    await raf.setPosition(offset);
    final boxHeader = await raf.read(16);
    if (boxHeader.length < 8) return null;
    final bd = ByteData.sublistView(boxHeader);
    var boxSize = bd.getUint32(0);
    var headerSize = 8;
    if (boxSize == 1) {
      if (boxHeader.length < 16) return null;
      boxSize = bd.getInt64(8);
      headerSize = 16;
    } else if (boxSize == 0) {
      boxSize = fileLength - offset;
    }
    if (boxSize < headerSize || offset + boxSize > fileLength) return null;

    final b4 = boxHeader[4];
    final b5 = boxHeader[5];
    final b6 = boxHeader[6];
    final b7 = boxHeader[7];
    if (b4 == 0x66 && b5 == 0x74 && b6 == 0x79 && b7 == 0x70) {
      // ftyp
      hasFtyp = true;
    } else if (b4 == 0x6D && b5 == 0x6F && b6 == 0x6F && b7 == 0x76) {
      // moov
      final moovEnd = offset + boxSize;
      var childOffset = offset + headerSize;
      for (
        var children = 0;
        children < 128 && childOffset + 8 <= moovEnd;
        children++
      ) {
        await raf.setPosition(childOffset);
        final childHeader = await raf.read(16);
        if (childHeader.length < 8) return null;
        final childBd = ByteData.sublistView(childHeader);
        var childSize = childBd.getUint32(0);
        var childHeaderSize = 8;
        if (childSize == 1) {
          if (childHeader.length < 16) return null;
          childSize = childBd.getInt64(8);
          childHeaderSize = 16;
        } else if (childSize == 0) {
          childSize = moovEnd - childOffset;
        }
        if (childSize < childHeaderSize || childOffset + childSize > moovEnd) {
          return null;
        }
        final c4 = childHeader[4];
        final c5 = childHeader[5];
        final c6 = childHeader[6];
        final c7 = childHeader[7];
        if (c4 == 0x6D && c5 == 0x76 && c6 == 0x65 && c7 == 0x78) {
          // mvex (fragmented MP4): defer to ffprobe for total duration.
          return null;
        }
        if (c4 == 0x6D && c5 == 0x76 && c6 == 0x68 && c7 == 0x64) {
          // mvhd
          final payloadLen = childSize - childHeaderSize;
          if (payloadLen >= 20) {
            await raf.setPosition(childOffset + childHeaderSize);
            final data = await raf.read(payloadLen < 32 ? payloadLen : 32);
            if (data.length >= 20) {
              final mvhdBd = ByteData.sublistView(data);
              final version = data[0];
              if (version == 0) {
                final timescale = mvhdBd.getUint32(12);
                final duration = mvhdBd.getUint32(16);
                if (timescale > 0 && duration > 0 && duration != 0xFFFFFFFF) {
                  final micros =
                      (duration / timescale * Duration.microsecondsPerSecond)
                          .round();
                  if (micros > 0) mvhdDuration = Duration(microseconds: micros);
                }
              } else if (version == 1 && data.length >= 32) {
                final timescale = mvhdBd.getUint32(20);
                final duration = mvhdBd.getInt64(24);
                if (timescale > 0 && duration > 0) {
                  final micros =
                      (duration / timescale * Duration.microsecondsPerSecond)
                          .round();
                  if (micros > 0) mvhdDuration = Duration(microseconds: micros);
                }
              }
            }
          }
        }
        childOffset += childSize;
      }
    }
    if (hasFtyp && mvhdDuration != null) return mvhdDuration;
    offset += boxSize;
  }
  return hasFtyp ? mvhdDuration : null;
}
