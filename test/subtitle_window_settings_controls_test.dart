import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/core/widgets/unified_dropdown.dart';
import 'package:doujin_audio/features/settings/presentation/subtitle_rgb_controls.dart';
import 'package:doujin_audio/features/settings/presentation/subtitle_window_settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'SubtitleRgbControls commits keyboard-focused edits and normalizes out-of-range text',
    (tester) async {
      Color? currentColor;
      final changes = <Color>[];
      late StateSetter updateColor;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                updateColor = setState;
                return Column(
                  children: [
                    SubtitleRgbControls(
                      label: 'Font Color',
                      resetTooltip: 'Reset',
                      currentColor: currentColor,
                      defaultColor: const Color(0xFFFFFFFF),
                      cs: Theme.of(context).colorScheme,
                      labelStyle: Theme.of(context).textTheme.bodyMedium,
                      onChanged: (color) {
                        changes.add(color);
                        updateColor(() => currentColor = color);
                      },
                      onChangeStart: () {},
                      onChangeEnd: () {},
                      onReset: () => updateColor(() => currentColor = null),
                    ),
                    const TextField(key: ValueKey('other_field')),
                  ],
                );
              },
            ),
          ),
        ),
      );

      final rField = find
          .descendant(
            of: find.byType(SubtitleRgbControls),
            matching: find.byType(TextField),
          )
          .first;
      final rTextField = tester.widget<TextField>(rField);

      // Programmatic/keyboard focus without pointer tap.
      rTextField.focusNode!.requestFocus();
      await tester.pump();
      expect(rTextField.focusNode!.hasFocus, isTrue);

      // Submitting an out-of-range value that clamps to the current value (255)
      // must normalize the text back to '255'.
      tester.testTextInput.enterText('999');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rTextField.controller!.text, '255');
      expect(changes, isEmpty);

      // Editing via keyboard focus and blurring commits the new value.
      tester.testTextInput.enterText('120');
      await tester.pump();
      FocusScope.of(tester.element(find.byKey(const ValueKey('other_field'))))
          .unfocus();
      await tester.pump();
      expect(rTextField.controller!.text, '120');
      expect(changes, [const Color(0xFF78FFFF)]);
    },
  );

  testWidgets(
    'SubtitleWindowSettingsSheet sanitizes invalid persisted font and updates on async reload',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'subtitle_font_family': 'InvalidFontNotInList',
      });
      final language = AppLanguageProvider();
      addTearDown(language.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SubtitleWindowSettingsSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final fieldFinder = find.byType(UnifiedDropdownButtonFormField<String>);
      expect(
        tester
            .widget<UnifiedDropdownButtonFormField<String>>(fieldFinder)
            .initialValue,
        '',
      );
      expect(
        find.descendant(
          of: fieldFinder,
          matching: find.text(language.tr('system_default')),
        ),
        findsOneWidget,
      );

      // Simulate an async preference load/update changing the font family.
      final container = ProviderScope.containerOf(
        tester.element(fieldFinder),
        listen: false,
      );
      container.read(subtitleSettingsProvider.notifier).setFontFamily('serif');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<UnifiedDropdownButtonFormField<String>>(fieldFinder)
            .initialValue,
        'serif',
      );
      expect(
        find.descendant(
          of: fieldFinder,
          matching: find.text(language.tr('subtitle_font_serif')),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'SubtitleWindowSettingsSheet filters Windows CJK fonts on Android, shows units and resets all',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'subtitle_font_family': 'serif',
        'subtitle_font_size': '24',
        'subtitle_border_depth': '0.8',
      });
      final language = AppLanguageProvider();
      addTearDown(language.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SubtitleWindowSettingsSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('24 px'), findsOneWidget);
      expect(find.text('80%'), findsWidgets);

      final dropdown = tester.widget<UnifiedDropdownButtonFormField<String>>(
        find.byType(UnifiedDropdownButtonFormField<String>),
      );
      final values = dropdown.items.map((item) => item.value).toList();
      expect(values, isNot(contains('SimSun')));
      expect(values, isNot(contains('KaiTi')));
      expect(values, isNot(contains('SimHei')));

      await tester.tap(find.byKey(const ValueKey('subtitle_reset_all_button')));
      await tester.pumpAndSettle();
      expect(find.text('16 px'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
