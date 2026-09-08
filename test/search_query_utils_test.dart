import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/search_query_utils.dart';

void main() {
  test('prepared search terms preserve phrase and whitespace semantics', () {
    final terms = normalizedSearchTerms('  SOFT   Rain / 海浪，Circle  ');
    expect(terms, ['soft rain', '海浪', 'circle']);
    const haystacks = ['Soft\tRain', '海浪 by CIRCLE'];
    expect(matchesSearchTerms(haystacks, '', normalizedTerms: terms), isTrue);
    expect(
      matchesSearchTerms(haystacks, '  SOFT   Rain / 海浪，Circle  '),
      isTrue,
    );
    expect(normalizedSearchTerms(' , /， '), isEmpty);
  });

  test('normalizeSearchQuery joins comma and slash separated terms', () {
    expect(
      normalizeSearchQuery('rain\uFF0Cocean/forest,  noise'),
      'rain ocean forest noise',
    );
  });

  test('extractSearchTerms keeps plain spaces as a single phrase', () {
    expect(extractSearchTerms('soft rain'), <String>['soft rain']);
  });

  test('matchesSearchTerms requires every term to match somewhere', () {
    expect(
      matchesSearchTerms(const <String>[
        'Soft Rain Collection',
        'Ocean Waves by Circle',
      ], 'rain,ocean'),
      isTrue,
    );
    expect(
      matchesSearchTerms(const <String>[
        'Soft Rain Collection',
        'Ocean Waves by Circle',
      ], 'rain/forest'),
      isFalse,
    );
  });
}
