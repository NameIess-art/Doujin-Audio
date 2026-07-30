import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/audio_detail.dart';
import 'package:nameless_audio/core/widgets/search_highlight.dart';
import 'package:nameless_audio/features/library/domain/audio_library_category.dart';

void main() {
  group('SearchHighlightScope.withTerms', () {
    testWidgets('provides custom terms list to descendant SearchHighlightedText', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchHighlightScope.withTerms(
              terms: const ['alpha', 'beta'],
              child: const SearchHighlightedText(
                text: 'alpha test beta',
                style: TextStyle(),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(RichText), findsOneWidget);
      final richText = tester.widget<RichText>(find.byType(RichText));
      final textSpan = richText.text as TextSpan;
      expect(textSpan.children, isNotNull);
      expect(textSpan.children!.length, greaterThan(1));
    });
  });

  group('Category entry search filtering logic', () {
    final entry1 = _createEntry(
      title: 'Work Alpha',
      path: '/path/1',
      tags: ['ASMR', 'Relaxation'],
      voiceActors: ['VoiceA'],
      circleName: 'CircleOne',
    );
    final entry2 = _createEntry(
      title: 'Work Beta',
      path: '/path/2',
      tags: ['Sleep', 'ASMR'],
      voiceActors: ['VoiceB'],
      circleName: 'CircleTwo',
    );

    test('Single-value and multi-value term matching on entries', () {
      final terms1 = entry1.normalizedTermsForCategory(
        AudioLibraryCategoryType.tags,
      );
      expect(terms1.contains('asmr'), isTrue);
      expect(terms1.contains('relaxation'), isTrue);

      final terms2 = entry2.normalizedTermsForCategory(
        AudioLibraryCategoryType.tags,
      );
      expect(terms2.contains('asmr'), isTrue);
      expect(terms2.contains('sleep'), isTrue);
    });

    test('Simultaneous AND condition matching between text query and element search', () {
      final entries = [entry1, entry2];

      List<AudioLibraryCategoryEntry> filter({
        required List<String> queryTerms,
        required List<String> normalizedSelectedTerms,
        required List<String> termKeywords,
      }) {
        final hasTextQuery = queryTerms.isNotEmpty;
        final hasElementQuery =
            normalizedSelectedTerms.isNotEmpty || termKeywords.isNotEmpty;

        return entries.where((entry) {
          final entryTerms = entry.normalizedTermsForCategory(
            AudioLibraryCategoryType.tags,
          );
          final matchesSelected = normalizedSelectedTerms.every(
            entryTerms.contains,
          );
          final matchesTermKeywords = termKeywords.every(
            (keyword) => entryTerms.any((term) => term.contains(keyword)),
          );
          final matchesElement =
              hasElementQuery && matchesSelected && matchesTermKeywords;
          final matchesText =
              hasTextQuery && queryTerms.every(entry.searchableText.contains);

          if (hasTextQuery && hasElementQuery) {
            return matchesText && matchesElement;
          } else if (hasTextQuery) {
            return matchesText;
          } else if (hasElementQuery) {
            return matchesElement;
          }
          return true;
        }).toList();
      }

      // Only text search ('alpha') matches entry1
      final textOnly = filter(
        queryTerms: ['alpha'],
        normalizedSelectedTerms: [],
        termKeywords: [],
      );
      expect(textOnly.map((e) => e.title), ['Work Alpha']);

      // Only element search ('asmr') matches both entry1 and entry2
      final elementOnly = filter(
        queryTerms: [],
        normalizedSelectedTerms: ['asmr'],
        termKeywords: [],
      );
      expect(elementOnly.map((e) => e.title), ['Work Alpha', 'Work Beta']);

      // Both active: text search 'alpha' AND element search 'asmr' -> matches ONLY entry1!
      final bothActiveMatch = filter(
        queryTerms: ['alpha'],
        normalizedSelectedTerms: ['asmr'],
        termKeywords: [],
      );
      expect(bothActiveMatch.map((e) => e.title), ['Work Alpha']);

      // Both active: text search 'beta' AND element search 'relaxation' -> matches NONE because entry2 has 'beta' but no 'relaxation', entry1 has 'relaxation' but no 'beta'
      final bothActiveNoMatch = filter(
        queryTerms: ['beta'],
        normalizedSelectedTerms: ['relaxation'],
        termKeywords: [],
      );
      expect(bothActiveNoMatch, isEmpty);
    });
  });
}

AudioLibraryCategoryEntry _createEntry({
  required String title,
  required String path,
  required List<String> tags,
  required List<String> voiceActors,
  required String circleName,
}) {
  final target = AudioDetailTarget.singleAudioFile(path);
  return AudioLibraryCategoryEntry(
    target: target,
    title: title,
    path: path,
    isFolder: false,
    detail: AudioDetail(
      target: target,
      rjCode: '',
      workTitle: title,
      circleName: circleName,
      voiceActors: voiceActors,
      tags: tags,
    ),
    tracks: const [],
  );
}
