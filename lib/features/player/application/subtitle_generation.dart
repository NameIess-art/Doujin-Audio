import 'dart:ffi';
import 'dart:io';

import '../../../core/media/subtitle_parser.dart';

enum SubtitleLanguage { japanese, other, unknown }

enum SubtitleDraftKind { script, translation }

class SubtitleDraft {
  const SubtitleDraft({
    required this.cues,
    required this.kind,
    required this.sourceLanguage,
    this.targetLanguage,
  });

  final List<SubtitleCue> cues;
  final SubtitleDraftKind kind;
  final String sourceLanguage;
  final String? targetLanguage;
}

class SubtitleTaskProgress {
  const SubtitleTaskProgress(this.stage, this.fraction, this.message);

  final String stage;
  final double fraction;
  final String message;
}

class SubtitleTaskCancelled implements Exception {
  const SubtitleTaskCancelled();
}

String? subtitleGenerationUnavailableReasonFor({
  required bool isAndroid,
  required bool isWindows,
  required int pointerBytes,
}) {
  if (isAndroid && pointerBytes == 4) {
    return 'subtitle_unsupported_32bit';
  }
  if (!isAndroid && !isWindows) {
    return 'subtitle_unsupported_platform';
  }
  return null;
}

String? get subtitleGenerationUnavailableReason =>
    subtitleGenerationUnavailableReasonFor(
      isAndroid: Platform.isAndroid,
      isWindows: Platform.isWindows,
      pointerBytes: sizeOf<IntPtr>(),
    );

SubtitleLanguage classifySubtitleLanguage(List<SubtitleCue> cues) {
  final sample = cues.take(40).map((cue) => cue.text).join();
  final japanese = RegExp(r'[\u3040-\u30ff]').allMatches(sample).length;
  final han = RegExp(r'[\u3400-\u9fff]').allMatches(sample).length;
  final latin = RegExp(r'[A-Za-z]').allMatches(sample).length;
  final meaningful = japanese + han + latin;
  if (meaningful < 12) return SubtitleLanguage.unknown;
  if (japanese >= 6 && japanese / meaningful >= 0.08) {
    return SubtitleLanguage.japanese;
  }
  if (japanese == 0 && (han >= 20 || latin >= 30)) {
    return SubtitleLanguage.other;
  }
  return SubtitleLanguage.unknown;
}

List<String> scriptDialogueLines(String raw) {
  final lines = <String>[];
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    var text = line.trim();
    if (text.isEmpty || RegExp(r'^(?:#|//|※|▼|▽|■|◆)').hasMatch(text)) {
      continue;
    }
    if (lines.isEmpty && text.startsWith('【') && text.length > 50) {
      continue;
    }
    text = text.replaceFirst(RegExp(r'^(?:[-*・]\s+|\d{1,3}[.．、)]\s*)'), '');
    text = text.replaceFirst(RegExp(r'^[^：:]{1,16}[：:]\s*'), '').trim();
    text = text
        .replaceAll(RegExp(r'[\[【（(〈<][^\]】）)〉>]{1,80}[\]】）)〉>]'), '')
        .trim();
    if (text.isEmpty || RegExp(r'^[\[【（(〈<＊*]').hasMatch(text)) continue;
    if (!RegExp(r'[\u3040-\u30ff\u3400-\u9fff]').hasMatch(text)) continue;
    lines.add(text);
  }
  return lines;
}
