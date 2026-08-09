import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/list_sorting_utils.dart';
import 'package:doujin_audio/features/library/presentation/library_sorting.dart';
import 'package:doujin_audio/features/player/presentation/playlist_sorting.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';

void main() {
  group('library sorting values', () {
    final first = LibrarySortValue(
      name: 'Alpha 2',
      libraryKey: '/library/a',
      voiceActor: 'Actor A',
      duration: const Duration(minutes: 2),
      releaseDate: DateTime(2024),
      addedAt: DateTime(2024, 2),
    );
    final second = LibrarySortValue(
      name: 'Beta 10',
      libraryKey: '/library/b',
      voiceActor: 'Actor B',
      duration: const Duration(minutes: 4),
      releaseDate: DateTime(2025),
      addedAt: DateTime(2024, 3),
    );

    test('supports every criterion and reverses only value direction', () {
      for (final criterion in LibrarySortCriterion.values) {
        expect(
          compareLibrarySortValues(first, second, criterion, true),
          lessThan(0),
        );
        expect(
          compareLibrarySortValues(first, second, criterion, false),
          greaterThan(0),
        );
      }
    });

    test('unknown values sort after known values', () {
      const unknown = LibrarySortValue(
        name: 'Unknown',
        libraryKey: null,
        voiceActor: null,
        duration: null,
        releaseDate: null,
        addedAt: null,
      );
      expect(compareOptionalSortStrings(null, 'Actor'), greaterThan(0));
      expect(
        compareLibrarySortValues(
          unknown,
          first,
          LibrarySortCriterion.voiceActor,
          true,
        ),
        greaterThan(0),
      );
      expect(
        compareLibrarySortValues(
          unknown,
          first,
          LibrarySortCriterion.duration,
          false,
        ),
        lessThan(0),
      );
    });
  });

  group('playlist sorting values', () {
    final first = PlaylistSortValue(
      name: 'Queue 1',
      libraryKey: '/library/a',
      voiceActor: 'Actor A',
      releaseDate: DateTime(2024),
      addedAt: DateTime(2024, 2),
    );
    final second = PlaylistSortValue(
      name: 'Queue 2',
      libraryKey: '/library/b',
      voiceActor: 'Actor B',
      releaseDate: DateTime(2025),
      addedAt: DateTime(2024, 3),
    );

    test('supports every criterion and descending order', () {
      for (final criterion in PlaylistSortCriterion.values) {
        expect(
          comparePlaylistSortValues(first, second, criterion, true),
          lessThan(0),
        );
        expect(
          comparePlaylistSortValues(first, second, criterion, false),
          greaterThan(0),
        );
      }
    });
  });

  test('library grouping order follows sort direction', () {
    expect(
      compareGroupedSortStrings('/library/a', '/library/b', true),
      lessThan(0),
    );
    expect(
      compareGroupedSortStrings('/library/a', '/library/b', false),
      greaterThan(0),
    );
  });
}
