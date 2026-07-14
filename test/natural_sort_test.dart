import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/natural_sort.dart';

void main() {
  test('compareNatural sorts numeric suffixes naturally', () {
    final values = <String>['10', '1', '2', '01', '11']..sort(compareNatural);

    expect(values, <String>['1', '01', '2', '10', '11']);
  });

  test('compareNatural sorts mixed filenames naturally', () {
    final values = <String>[
      'Track 10',
      'Track 2',
      'Track 1',
      'Track 01',
      'Track 11',
    ]..sort(compareNatural);

    expect(values, <String>[
      'Track 1',
      'Track 01',
      'Track 2',
      'Track 10',
      'Track 11',
    ]);
  });

  test('compareNatural sorts Japanese titles with full-width digits', () {
    final values = <String>['トラック１０', 'トラック１１', 'トラック２', 'トラック１']
      ..sort(compareNatural);

    expect(values, <String>['トラック１', 'トラック２', 'トラック１０', 'トラック１１']);
  });
}
