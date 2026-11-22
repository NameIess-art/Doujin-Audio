import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../../../core/media/path_display.dart';
import 'asmr_models.dart';

enum AsmrDownloadConflictPolicy { skip, overwrite }

enum AsmrDownloadFolderNameField { rjCode, voiceActors, circleName, workTitle }

const int kMinAsmrDownloadRetryCount = 3;
const int kMaxAsmrDownloadRetryCount = 10;
const int kDefaultAsmrDownloadRetryCount = 5;
const int kMinAsmrDownloadThreadCount = 1;
const int kMaxAsmrDownloadThreadCount = 5;
const int kDefaultAsmrDownloadThreadCount = 3;
const int kMaxAsmrDownloadWorkFolderNameLength = 120;
const int kMaxAsmrDownloadSegmentUtf8Bytes = 220;
const int _kAsmrDownloadTruncationHashLength = 8;
const int _kMaxPreservedExtensionLength = 24;

int normalizeAsmrDownloadRetryCount(int value) =>
    value.clamp(kMinAsmrDownloadRetryCount, kMaxAsmrDownloadRetryCount);

int normalizeAsmrDownloadThreadCount(int value) =>
    value.clamp(kMinAsmrDownloadThreadCount, kMaxAsmrDownloadThreadCount);

const List<AsmrDownloadFolderNameField> kDefaultAsmrDownloadFolderNameFields =
    <AsmrDownloadFolderNameField>[AsmrDownloadFolderNameField.workTitle];

List<AsmrDownloadFolderNameField> normalizeAsmrDownloadFolderNameFields(
  Iterable<AsmrDownloadFolderNameField> fields,
) {
  final normalized = <AsmrDownloadFolderNameField>[];
  for (final field in fields) {
    if (!normalized.contains(field)) normalized.add(field);
  }
  return normalized.isEmpty
      ? kDefaultAsmrDownloadFolderNameFields
      : List<AsmrDownloadFolderNameField>.unmodifiable(normalized);
}

List<AsmrDownloadFolderNameField> decodeAsmrDownloadFolderNameFields(
  Object? value,
) {
  if (value is! List) return kDefaultAsmrDownloadFolderNameFields;
  final decoded = <AsmrDownloadFolderNameField>[];
  for (final name in value.whereType<String>()) {
    for (final field in AsmrDownloadFolderNameField.values) {
      if (field.name == name) {
        decoded.add(field);
        break;
      }
    }
  }
  return normalizeAsmrDownloadFolderNameFields(decoded);
}

String buildAsmrDownloadWorkFolderName(
  AsmrWork work,
  Iterable<AsmrDownloadFolderNameField> fields,
) {
  final parts = <String>[];
  for (final field in normalizeAsmrDownloadFolderNameFields(fields)) {
    final value = switch (field) {
      AsmrDownloadFolderNameField.rjCode => work.rjCode.trim(),
      AsmrDownloadFolderNameField.voiceActors => _joinVoiceActors(
        work.voiceActors,
      ),
      AsmrDownloadFolderNameField.circleName => work.circleName.trim(),
      AsmrDownloadFolderNameField.workTitle => work.title.trim(),
    };
    if (value.isNotEmpty) parts.add(value);
  }
  final rawName = parts.isEmpty ? work.title.trim() : parts.join(' - ');
  final safeName = PathDisplay.safeFileName(
    rawName,
    replacement: '_',
    collapseWhitespace: false,
    fallback: 'ASMR_ONE',
  );
  return truncateAsmrDownloadPathSegment(
    safeName,
    maxCodeUnits: kMaxAsmrDownloadWorkFolderNameLength,
    preserveExtension: false,
    hashInput: rawName,
  );
}

String truncateAsmrDownloadPathSegment(
  String segment, {
  required int maxCodeUnits,
  int? maxUtf8Bytes,
  bool preserveExtension = true,
  String? hashInput,
}) {
  final fitsCodeUnits = segment.length <= maxCodeUnits;
  final fitsUtf8 =
      maxUtf8Bytes == null || utf8.encode(segment).length <= maxUtf8Bytes;
  if (fitsCodeUnits && fitsUtf8) return segment;

  final rawExtension = preserveExtension ? path.posix.extension(segment) : '';
  final extension =
      rawExtension.isNotEmpty &&
          rawExtension != segment &&
          rawExtension.length <= _kMaxPreservedExtensionLength &&
          RegExp(r'^\.[A-Za-z0-9]+$').hasMatch(rawExtension)
      ? rawExtension
      : '';
  final stem = extension.isEmpty
      ? segment
      : segment.substring(0, segment.length - extension.length);
  final hash = sha256
      .convert(utf8.encode(hashInput ?? segment))
      .toString()
      .substring(0, _kAsmrDownloadTruncationHashLength);

  final suffix = '_$hash$extension';
  final suffixUtf8Bytes = utf8.encode(suffix).length;
  final stemCodeUnitBudget = maxCodeUnits - suffix.length;
  final stemUtf8Budget = maxUtf8Bytes == null
      ? null
      : maxUtf8Bytes - suffixUtf8Bytes;

  if (stemCodeUnitBudget > 0 &&
      (stemUtf8Budget == null || stemUtf8Budget > 0)) {
    final prefix = _trimSegmentPrefix(
      stem,
      maxCodeUnits: stemCodeUnitBudget,
      maxUtf8Bytes: stemUtf8Budget,
    );
    if (prefix.isNotEmpty) {
      return '$prefix$suffix';
    }
  }

  final compact = '$hash$extension';
  if (compact.length <= maxCodeUnits &&
      (maxUtf8Bytes == null || utf8.encode(compact).length <= maxUtf8Bytes)) {
    return compact;
  }
  return _trimSegmentPrefix(
    hash,
    maxCodeUnits: maxCodeUnits,
    maxUtf8Bytes: maxUtf8Bytes,
  );
}

String _trimSegmentPrefix(
  String value, {
  required int maxCodeUnits,
  int? maxUtf8Bytes,
}) {
  if (maxCodeUnits <= 0 || (maxUtf8Bytes != null && maxUtf8Bytes <= 0)) {
    return '';
  }
  var end = value.length < maxCodeUnits ? value.length : maxCodeUnits;
  if (end > 0 && end < value.length && _isHighSurrogate(value.codeUnitAt(end - 1))) {
    end -= 1;
  }
  var prefix = value.substring(0, end);
  if (maxUtf8Bytes != null && utf8.encode(prefix).length > maxUtf8Bytes) {
    final buffer = StringBuffer();
    var bytes = 0;
    for (final rune in prefix.runes) {
      final runeBytes = rune <= 0x7F
          ? 1
          : rune <= 0x7FF
          ? 2
          : rune <= 0xFFFF
          ? 3
          : 4;
      if (bytes + runeBytes > maxUtf8Bytes) break;
      buffer.writeCharCode(rune);
      bytes += runeBytes;
    }
    prefix = buffer.toString();
  }
  return prefix.replaceAll(RegExp(r'[. _-]+$'), '');
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

String _joinVoiceActors(Iterable<String> voiceActors) {
  final values = <String>[];
  for (final voiceActor in voiceActors) {
    final value = voiceActor.trim();
    if (value.isNotEmpty && !values.contains(value)) values.add(value);
  }
  return values.join('、');
}
