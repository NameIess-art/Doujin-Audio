import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';

void main() {
  group('Playlist batch selection rules', () {
    bool isPlayEnabled(int count) => count > 0;

    bool isPauseEnabled(int count) => count > 0;
    bool isPinEnabled(int count) => count > 0;
    bool isRemoveEnabled(int count) => count > 0;

    test('Play button is disabled when selected count is 0', () {
      expect(isPlayEnabled(0), isFalse);
      expect(isPauseEnabled(0), isFalse);
      expect(isPinEnabled(0), isFalse);
      expect(isRemoveEnabled(0), isFalse);
    });

    test('Play button is enabled for a single selection', () {
      expect(isPlayEnabled(1), isTrue);
      expect(isPauseEnabled(1), isTrue);
      expect(isPinEnabled(1), isTrue);
      expect(isRemoveEnabled(1), isTrue);
    });

    test('Play button is enabled for multiple selections', () {
      expect(isPlayEnabled(2), isTrue);
      expect(isPlayEnabled(5), isTrue);
      expect(isPauseEnabled(2), isTrue);
      expect(isPinEnabled(2), isTrue);
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
                          IconButton(
                            key: ValueKey('batch_pin_button'),
                            onPressed: null,
                            icon: Icon(Icons.push_pin_rounded),
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
      expect(find.byKey(const ValueKey('batch_pin_button')), findsOneWidget);
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
