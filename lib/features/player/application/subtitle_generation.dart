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

class SubtitleAlignmentTooLarge implements Exception {
  const SubtitleAlignmentTooLarge();
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

final RegExp _japaneseKanaPattern = RegExp(r'[\u3040-\u30ff]');
final RegExp _hanCharacterPattern = RegExp(r'[\u3400-\u9fff]');
final RegExp _latinLetterPattern = RegExp(r'[A-Za-z]');
final RegExp _scriptLineBreakPattern = RegExp(r'\r?\n');
final RegExp _scriptCommentPrefixPattern = RegExp(r'^(?:#|//|※|▼|▽|■|◆)');
final RegExp _scriptListMarkerPattern = RegExp(
  r'^(?:[-*・]\s+|\d{1,3}[.．、)]\s*)',
);
final RegExp _scriptSpeakerPrefixPattern = RegExp(r'^[^：:]{1,16}[：:]\s*');
final RegExp _scriptBracketedNotePattern = RegExp(
  r'[\[【（(〈<][^\]】）)〉>]{1,80}[\]】）)〉>]',
);
final RegExp _scriptLeadingBracketPattern = RegExp(r'^[\[【（(〈<＊*]');
final RegExp _scriptJapaneseOrHanPattern = RegExp(
  r'[\u3040-\u30ff\u3400-\u9fff]',
);

SubtitleLanguage classifySubtitleLanguage(List<SubtitleCue> cues) {
  final sample = cues
      .take(40)
      .map((cue) => cue.originalText ?? cue.text)
      .join();
  final japanese = _japaneseKanaPattern.allMatches(sample).length;
  final han = _hanCharacterPattern.allMatches(sample).length;
  final latin = _latinLetterPattern.allMatches(sample).length;
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
  for (final line in raw.split(_scriptLineBreakPattern)) {
    var text = line.trim();
    if (text.isEmpty || _scriptCommentPrefixPattern.hasMatch(text)) {
      continue;
    }
    if (lines.isEmpty && text.startsWith('【') && text.length > 50) {
      continue;
    }
    text = text.replaceFirst(_scriptListMarkerPattern, '');
    text = text.replaceFirst(_scriptSpeakerPrefixPattern, '').trim();
    text = text.replaceAll(_scriptBracketedNotePattern, '').trim();
    if (text.isEmpty || _scriptLeadingBracketPattern.hasMatch(text)) continue;
    if (!_scriptJapaneseOrHanPattern.hasMatch(text)) continue;
    lines.add(text);
  }
  return lines;
}
