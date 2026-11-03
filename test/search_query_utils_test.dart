import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/search_query_utils.dart';

void main() {
  test(
    'element search round-trips phrases, groups and literal punctuation',
    () {
      final query = parseSearchElements(
        r'耳语、Soft Rain（海浪）(Forest) Work\(live\) A\/B',
      );
      expect(query?.all, ['耳语', 'Soft Rain', 'Work(live) A/B']);
      expect(query?.any, ['海浪', 'Forest']);
      expect(
        formatSearchElements(query!),
        r'耳语, Soft Rain, Work\(live\) A\/B （海浪）（Forest）',
      );
      expect(
        searchElementBranches('Rain（Ocean）（Forest）').map(searchElementKeyword),
        ['Rain Ocean', 'Rain Forest'],
      );
      expect(searchElementBranches('(Ocean)').map(searchElementKeyword), [
        'Ocean',
      ]);
      expect(parseSearchElements(legacySearchElements('Work(live)'))?.all, [
        'Work(live)',
      ]);
      for (final invalid in [
        'Work(',
        'Work（)',
        '()',
        '(  )',
        '((Work))',
        'Work)',
      ]) {
        expect(parseSearchElements(invalid), isNull);
      }
    },
  );

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

  test('toggling a suggestion moves it between groups or removes it', () {
    final draft = parseSearchElements('Soft Rain（Ocean）')!;
    expect(
      toggleSearchElement(draft, 'Ocean', matchAll: true),
      'Soft Rain, Ocean',
    );
    expect(
      toggleSearchElement(draft, 'Soft Rain', matchAll: false),
      '（Ocean）（Soft Rain）',
    );
    expect(toggleSearchElement(draft, 'Ocean', matchAll: false), 'Soft Rain');
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
