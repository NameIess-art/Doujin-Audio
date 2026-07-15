import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_display.dart';

final class DlsiteMetadataQuery {
  const DlsiteMetadataQuery({
    this.rjCode,
    this.searchTitles = const <String>[],
  });

  factory DlsiteMetadataQuery.fromDetail(AudioDetail detail) {
    final rjCode = AudioDetail.findRjCodeInText(detail.rjCode);
    if (rjCode != null) {
      return DlsiteMetadataQuery(rjCode: rjCode);
    }
    final seen = <String>{};
    final searchTitles =
        <String>[
              detail.target.isLibraryRootFolder
                  ? PathDisplay.folderName(detail.target.targetPath)
                  : PathDisplay.fileName(
                      detail.target.targetPath,
                      withoutExtension: true,
                    ),
              detail.workTitle,
            ]
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty && seen.add(value))
            .toList(growable: false);
    return DlsiteMetadataQuery(searchTitles: searchTitles);
  }

  final String? rjCode;
  final List<String> searchTitles;

  bool get hasQuery => rjCode != null || searchTitles.isNotEmpty;
}
