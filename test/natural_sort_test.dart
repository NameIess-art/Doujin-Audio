import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/natural_sort.dart';

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

  test('compareNatural sorts Chinese chapter numerals naturally (user case)', () {
    final values = <String>[
      '第一篇 催眠音声',
      '第三篇 催眠音声',
      '第二篇 催眠音声',
      '第五篇 催眠音声',
      '第六篇 催眠音声',
      '第四篇 催眠音声',
    ]..sort(compareNatural);

    expect(values, <String>[
      '第一篇 催眠音声',
      '第二篇 催眠音声',
      '第三篇 催眠音声',
      '第四篇 催眠音声',
      '第五篇 催眠音声',
      '第六篇 催眠音声',
    ]);
  });

  test('compareNatural sorts Chinese numerals beyond ten naturally', () {
    final values = <String>[
      '第二十篇',
      '第十篇',
      '第一篇',
      '第十一篇',
      '第十二篇',
      '第二篇',
      '第九篇',
      '第一百篇',
      '第二十一篇',
    ]..sort(compareNatural);

    expect(values, <String>[
      '第一篇',
      '第二篇',
      '第九篇',
      '第十篇',
      '第十一篇',
      '第十二篇',
      '第二十篇',
      '第二十一篇',
      '第一百篇',
    ]);
  });

  test('compareNatural sorts mixed Arabic and Chinese numerals naturally', () {
    final values = <String>[
      '第10篇',
      '第2篇',
      '第一篇',
      '第四篇',
      '第3篇',
    ]..sort(compareNatural);

    expect(values, <String>[
      '第一篇',
      '第2篇',
      '第3篇',
      '第四篇',
      '第10篇',
    ]);
  });

  test('compareNatural sorts Japanese kanji numerals naturally', () {
    final values = <String>[
      '第拾話',
      '第壱話',
      '第参話',
      '第弐話',
      '第拾壱話',
    ]..sort(compareNatural);

    expect(values, <String>[
      '第壱話',
      '第弐話',
      '第参話',
      '第拾話',
      '第拾壱話',
    ]);
  });

  test('compareNatural sorts Chinese enumerated lists naturally', () {
    final values = <String>[
      '十、总结',
      '一、前言',
      '三、高潮',
      '二、发展',
      '十一、附录',
    ]..sort(compareNatural);

    expect(values, <String>[
      '一、前言',
      '二、发展',
      '三、高潮',
      '十、总结',
      '十一、附录',
    ]);
  });
}
