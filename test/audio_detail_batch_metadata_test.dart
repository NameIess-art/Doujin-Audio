import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/providers/audio_provider.dart';

AudioDetail _detail({
  String rjCode = 'RJ123456',
  String workTitle = 'Work title',
  String circleName = 'Circle',
  List<String> voiceActors = const <String>['Voice actor'],
  List<String> tags = const <String>['ASMR'],
  bool includeReleaseDate = true,
  int? salesCount = 1234,
  double? rating = 4.5,
  String path = '/library/Work title',
}) {
  return AudioDetail(
    target: AudioDetailTarget.libraryRootFolder(path),
    rjCode: rjCode,
    workTitle: workTitle,
    circleName: circleName,
    voiceActors: voiceActors,
    tags: tags,
    releaseDate: includeReleaseDate ? DateTime(2024, 5, 6) : null,
    salesCount: salesCount,
    rating: rating,
  );
}

void main() {
  test('metadata is missing when any supported work field is empty', () {
    expect(_detail().hasMissingMetadata, isFalse);
    expect(_detail(rjCode: '').hasMissingMetadata, isTrue);
    expect(_detail(workTitle: '').hasMissingMetadata, isFalse);
    expect(_detail(circleName: '').hasMissingMetadata, isTrue);
    expect(_detail(voiceActors: const <String>[]).hasMissingMetadata, isTrue);
    expect(_detail(tags: const <String>[]).hasMissingMetadata, isTrue);
    expect(_detail().copyWith(releaseDate: null).hasMissingMetadata, isTrue);
    expect(_detail().copyWith(salesCount: null).hasMissingMetadata, isTrue);
    expect(_detail().copyWith(rating: null).hasMissingMetadata, isTrue);
  });

  test('metadata is absent only when every required work field is empty', () {
    expect(
      _detail(
        rjCode: '',
        workTitle: 'Optional title',
        circleName: '',
        voiceActors: const <String>[],
        tags: const <String>[],
        includeReleaseDate: false,
        salesCount: null,
        rating: null,
      ).hasNoMetadata,
      isTrue,
    );
    expect(_detail(rjCode: '').hasNoMetadata, isFalse);
  });

  test('card info fields default to current metadata and cap at six items', () {
    expect(CardInfoField.defaults, const <CardInfoField>[
      CardInfoField.rjCode,
      CardInfoField.voiceActors,
      CardInfoField.circleName,
      CardInfoField.tags,
    ]);

    final normalized = CardInfoField.normalize(CardInfoField.values);
    expect(normalized, hasLength(CardInfoField.maxSelected));
    expect(normalized, const <CardInfoField>[
      CardInfoField.rjCode,
      CardInfoField.voiceActors,
      CardInfoField.circleName,
      CardInfoField.tags,
      CardInfoField.releaseDate,
      CardInfoField.salesCount,
    ]);
  });

  test('card info tag rows fill the remaining six-line card budget', () {
    expect(CardInfoField.tagLineCountForSelection(1), 6);
    expect(CardInfoField.tagLineCountForSelection(3), 4);
    expect(CardInfoField.tagLineCountForSelection(4), 3);
    expect(CardInfoField.tagLineCountForSelection(5), 2);
    expect(CardInfoField.tagLineCountForSelection(6), 1);
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
