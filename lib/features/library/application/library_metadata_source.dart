import '../../../core/app_language.dart';
import '../../../core/media/dlsite_metadata.dart';

/// Remote metadata consumed by the library without owning its source.
abstract interface class LibraryMetadataSource {
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    required AppLanguage language,
  });

  Future<List<DlsiteMetadata>> searchByTitleCandidates(
    Iterable<String> titles, {
    required AppLanguage language,
  });
}
