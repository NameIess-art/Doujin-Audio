import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/dlsite_metadata.dart';

void main() {
  test('parses DLsite product json into editable metadata', () {
    final metadata = DlsiteMetadata.fromProductJson({
      'workno': 'RJ01014447',
      'work_name': 'Work title',
      'maker_name': 'Circle',
      'image_main': {'url': '//img.dlsite.jp/path/cover.jpg'},
      'creaters': {
        'voice_by': [
          {'name': 'Voice A'},
          {'name': 'Voice A'},
          {'name': 'Voice B'},
        ],
      },
      'genres': [
        {'name': 'ASMR'},
        {'name': 'Ear cleaning'},
      ],
    });

    expect(metadata.rjCode, 'RJ01014447');
    expect(metadata.workTitle, 'Work title');
    expect(metadata.circleName, 'Circle');
    expect(metadata.voiceActors, const <String>['Voice A', 'Voice B']);
    expect(metadata.tags, const <String>['ASMR', 'Ear cleaning']);
    expect(metadata.coverUrl, 'https://img.dlsite.jp/path/cover.jpg');
  });
}
