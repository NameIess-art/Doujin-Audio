import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/search_query_utils.dart';

void main() {
  test('canonical queries retain AND boundaries and deduplicate phrases', () {
    expect(
      canonicalSearchQuery(' SOFT   Rain / 海浪，soft rain '),
      'SOFT Rain, 海浪',
    );
    expect(normalizedSearchTerms(canonicalSearchQuery('rain,ocean')), [
      'rain',
      'ocean',
    ]);
    expect(canonicalSearchQuery(' , /， '), isEmpty);
  });

  test('suggestions toggle whole conditions including composite history', () {
    expect(toggleSearchQueryTerms('soft rain', 'Ocean'), 'soft rain, Ocean');
    expect(toggleSearchQueryTerms('soft rain, Ocean', 'SOFT RAIN'), 'Ocean');
    expect(
      toggleSearchQueryTerms('rain, forest', 'Rain, ocean'),
      'rain, forest, ocean',
    );
    expect(
      toggleSearchQueryTerms('rain, forest, ocean', 'Rain, ocean'),
      'forest',
    );
    expect(searchQueryContainsTerms('rain, forest', 'Rain'), isTrue);
    expect(searchQueryContainsTerms('rain, forest', 'Rain, ocean'), isFalse);
    expect(searchQueryContainsTerms('rain, forest', ''), isFalse);
    expect(toggleSearchQueryTerms('rainbow, rain', 'rain'), 'rainbow');
  });

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
