import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';

void main() {
  group('Playlist batch selection rules', () {
    bool isPlayEnabled({
      required int count,
      required bool multiThreadEnabled,
    }) {
      return count > 0 && (multiThreadEnabled || count <= 1);
    }

    bool isPauseEnabled(int count) => count > 0;
    bool isRemoveEnabled(int count) => count > 0;

    test('Play button is disabled when selected count is 0', () {
      expect(
        isPlayEnabled(count: 0, multiThreadEnabled: false),
        isFalse,
      );
      expect(
        isPlayEnabled(count: 0, multiThreadEnabled: true),
        isFalse,
      );
      expect(isPauseEnabled(0), isFalse);
      expect(isRemoveEnabled(0), isFalse);
    });

    test('Play button is enabled for single selection regardless of multi-thread setting', () {
      expect(
        isPlayEnabled(count: 1, multiThreadEnabled: false),
        isTrue,
      );
      expect(
        isPlayEnabled(count: 1, multiThreadEnabled: true),
        isTrue,
      );
      expect(isPauseEnabled(1), isTrue);
      expect(isRemoveEnabled(1), isTrue);
    });

    test('Play button is grayed out/disabled for multiple selection when multi-thread playback is OFF', () {
      expect(
        isPlayEnabled(count: 2, multiThreadEnabled: false),
        isFalse,
      );
      expect(
        isPlayEnabled(count: 5, multiThreadEnabled: false),
        isFalse,
      );
      expect(isPauseEnabled(2), isTrue);
      expect(isRemoveEnabled(2), isTrue);
    });

    test('Play button is enabled for multiple selection when multi-thread playback is ON', () {
      expect(
        isPlayEnabled(count: 2, multiThreadEnabled: true),
        isTrue,
      );
      expect(
        isPlayEnabled(count: 5, multiThreadEnabled: true),
        isTrue,
      );
      expect(isPauseEnabled(2), isTrue);
      expect(isRemoveEnabled(2), isTrue);
    });
  });

  group('Playlist batch selection header rendering and transitions', () {
    testWidgets('selection header renders AppRollingNumber and leading close button', (
      tester,
    ) async {
      final selectedCount = ValueNotifier<int>(1);
      addTearDown(selectedCount.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: selectedCount,
                builder: (context, count, _) {
                  return TopPageHeader(
                    key: const ValueKey('playlist_batch_selection_header'),
                    leading: IconButton(
                      key: const ValueKey('exit_selection_button'),
                      onPressed: () {},
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Cancel',
                    ),
                    title: count.toString(),
                    titleWidget: AppRollingNumber(number: count),
                    trailing: const SizedBox(
                      height: 44,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: ValueKey('batch_play_button'),
                            onPressed: null,
                            icon: Icon(Icons.play_arrow_rounded),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('playlist_batch_selection_header')), findsOneWidget);
      expect(find.byKey(const ValueKey('exit_selection_button')), findsOneWidget);
      expect(find.byKey(const ValueKey('batch_play_button')), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.byType(AppRollingNumber), findsOneWidget);

      selectedCount.value = 2;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsNothing);
    });
  });
}
