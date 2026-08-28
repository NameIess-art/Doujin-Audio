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
  return safeName;
}

String _joinVoiceActors(Iterable<String> voiceActors) {
  final values = <String>[];
  for (final voiceActor in voiceActors) {
    final value = voiceActor.trim();
    if (value.isNotEmpty && !values.contains(value)) values.add(value);
  }
  return values.join('、');
}
