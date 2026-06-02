import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/providers/audio_provider.dart';

AudioDetail _detail({
  String rjCode = 'RJ123456',
  String workTitle = 'Work title',
  String circleName = 'Circle',
  List<String> voiceActors = const <String>['Voice actor'],
  List<String> tags = const <String>['ASMR'],
  String path = '/library/Work title',
}) {
  return AudioDetail(
    target: AudioDetailTarget.libraryRootFolder(path),
    rjCode: rjCode,
    workTitle: workTitle,
    circleName: circleName,
    voiceActors: voiceActors,
    tags: tags,
  );
}

void main() {
  test('metadata is missing when any supported work field is empty', () {
    expect(_detail().hasMissingMetadata, isFalse);
    expect(_detail(rjCode: '').hasMissingMetadata, isTrue);
    expect(_detail(workTitle: '').hasMissingMetadata, isTrue);
    expect(_detail(circleName: '').hasMissingMetadata, isTrue);
    expect(_detail(voiceActors: const <String>[]).hasMissingMetadata, isTrue);
    expect(_detail(tags: const <String>[]).hasMissingMetadata, isTrue);
  });

  test('DLsite query prefers an RJ code over title candidates', () {
    final query = DlsiteMetadataQuery.fromDetail(
      _detail(rjCode: 'folder_rj987654_title'),
    );

    expect(query.rjCode, 'RJ987654');
    expect(query.searchTitles, isEmpty);
  });

  test('DLsite query falls back to unique target and work titles', () {
    final query = DlsiteMetadataQuery.fromDetail(
      _detail(rjCode: '', path: '/library/Folder name'),
    );

    expect(query.rjCode, isNull);
    expect(query.searchTitles, const <String>['Folder name', 'Work title']);
  });
}
