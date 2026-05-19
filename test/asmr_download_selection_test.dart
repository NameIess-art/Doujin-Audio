import 'package:flutter_test/flutter_test.dart';

import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/services/asmr_download_selection.dart';

void main() {
  AsmrTrackFile folder(
    String title,
    String relativePath, {
    List<AsmrTrackFile> children = const <AsmrTrackFile>[],
  }) {
    return AsmrTrackFile(
      hash: relativePath,
      title: title,
      type: 'folder',
      streamUrl: null,
      downloadUrl: null,
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 0,
      children: children,
      workId: 1,
      workTitle: 'Work',
      sourceId: 'RJ000000',
      relativePath: relativePath,
    );
  }

  AsmrTrackFile file(
    String title,
    String relativePath, {
    int size = 1024,
  }) {
    return AsmrTrackFile(
      hash: relativePath,
      title: title,
      type: 'audio',
      streamUrl: 'https://example.com/$relativePath',
      downloadUrl: 'https://example.com/$relativePath',
      lowQualityUrl: null,
      duration: const Duration(minutes: 1),
      size: size,
      children: const <AsmrTrackFile>[],
      workId: 1,
      workTitle: 'Work',
      sourceId: 'RJ000000',
      relativePath: relativePath,
    );
  }

  test('selecting a folder cascades to descendants and prunes selected roots', () {
    final tree = <AsmrTrackFile>[
      folder(
        'Disc 1',
        'Disc 1',
        children: [
          file('Track 1', 'Disc 1/Track 1.mp3'),
          file('Track 2', 'Disc 1/Track 2.mp3'),
          folder('Bonus', 'Disc 1/Bonus'),
        ],
      ),
    ];
    final model = AsmrDownloadSelectionModel(tree);

    model.togglePath('Disc 1', true);
    expect(model.stateForPath('Disc 1'), true);
    expect(model.stateForPath('Disc 1/Track 1.mp3'), true);
    expect(model.stateForPath('Disc 1/Bonus'), true);
    expect(model.selectedLeafCount(), 2);
    expect(
      model.selectedDownloadRoots().map((node) => node.relativePath),
      equals(<String>['Disc 1']),
    );

    model.togglePath('Disc 1/Track 1.mp3', false);
    expect(model.stateForPath('Disc 1'), null);
    expect(model.stateForPath('Disc 1/Track 1.mp3'), false);
    expect(model.stateForPath('Disc 1/Track 2.mp3'), true);
    expect(
      model.selectedDownloadRoots().map((node) => node.relativePath),
      equals(<String>[
        'Disc 1/Track 2.mp3',
        'Disc 1/Bonus',
      ]),
    );
  });

  test('selecting a leaf selects its direct parent and keeps higher ancestors indeterminate', () {
    final tree = <AsmrTrackFile>[
      folder(
        'Root',
        'Root',
        children: [
          folder(
            'Disc 1',
            'Root/Disc 1',
            children: [
              file('Track 1', 'Root/Disc 1/Track 1.mp3'),
            ],
          ),
          folder(
            'Disc 2',
            'Root/Disc 2',
            children: [
              file('Track 2', 'Root/Disc 2/Track 2.mp3'),
            ],
          ),
        ],
      ),
    ];
    final model = AsmrDownloadSelectionModel(tree);

    model.togglePath('Root/Disc 1/Track 1.mp3', true);
    expect(model.stateForPath('Root'), null);
    expect(model.stateForPath('Root/Disc 1'), true);
    expect(model.stateForPath('Root/Disc 1/Track 1.mp3'), true);
    expect(
      model.selectedDownloadRoots().map((node) => node.relativePath),
      equals(<String>['Root/Disc 1']),
    );
  });
}
