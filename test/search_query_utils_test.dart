import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/search_query_utils.dart';

void main() {
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
