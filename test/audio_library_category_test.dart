import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/audio_library_category.dart';

void main() {
  test('splitTerms handles Chinese and English commas with dedupe', () {
    expect(
      AudioLibraryCategorySnapshot.splitTerms(['癒し，ASMR', 'ASMR,バイノーラル', '  ']),
      ['癒し', 'ASMR', 'バイノーラル'],
    );
  });

  test('sortTermsByFrequency sorts by count then name', () {
    expect(
      AudioLibraryCategorySnapshot.sortTermsByFrequency({
        'Beta': 1,
        'alpha': 2,
        'Gamma': 2,
      }),
      ['alpha', 'Gamma', 'Beta'],
    );
  });
}
