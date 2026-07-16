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

  test('tree entries group folders before files and sort each naturally', () {
    final entries =
        <({bool isFolder, String name, String path})>[
          (isFolder: false, name: '10.mp3', path: '/10.mp3'),
          (isFolder: true, name: '10', path: '/10'),
          (isFolder: false, name: '2.mp3', path: '/2.mp3'),
          (isFolder: true, name: '2', path: '/2'),
          (isFolder: false, name: '01.mp3', path: '/01.mp3'),
          (isFolder: true, name: '01', path: '/01'),
        ]..sort(
          (left, right) => compareNaturalTreeEntries(
            leftIsFolder: left.isFolder,
            leftName: left.name,
            leftPath: left.path,
            rightIsFolder: right.isFolder,
            rightName: right.name,
            rightPath: right.path,
          ),
        );

    expect(entries.map((entry) => entry.name), <String>[
      '01',
      '2',
      '10',
      '01.mp3',
      '2.mp3',
      '10.mp3',
    ]);
  });

  test('compareNatural sorts Japanese titles with full-width digits', () {
    final values = <String>['トラック１０', 'トラック１１', 'トラック２', 'トラック１']
      ..sort(compareNatural);

    expect(values, <String>['トラック１', 'トラック２', 'トラック１０', 'トラック１１']);
  });
}
