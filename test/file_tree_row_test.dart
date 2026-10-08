import 'package:doujin_audio/core/widgets/file_tree_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'folder and file rows have equal heights and gaps ($textScale) on $platform',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(360, 900);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var index = 0; index < 4; index++)
                        FileTreeRow(
                          title: index < 2
                              ? 'Short name'
                              : 'A very long name that fills both available lines',
                          subtitle: index.isEven ? '2000 audio files' : null,
                          titleMaxLines: 2,
                          reserveSubtitleSpace: true,
                          minHeight: 64,
                          isFolder: index.isEven,
                          depth: index,
                          leading: Icon(
                            index.isEven
                                ? Icons.folder_rounded
                                : Icons.audio_file_rounded,
                            size: 19,
                          ),
                          trailing: TextButton(
                            onPressed: () {},
                            child: Text(index.isEven ? 'Exclude' : 'Restore'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
          final rows = find.byType(FileTreeRow);
          final height = tester.getSize(rows.first).height;
          expect(height, textScale == 1 ? 64 : greaterThan(64));
          for (var index = 0; index < 4; index++) {
            expect(tester.getSize(rows.at(index)).height, height);
            if (index > 0) {
              expect(
                tester.getRect(rows.at(index)).top,
                tester.getRect(rows.at(index - 1)).bottom,
              );
            }
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
    testWidgets(
      'deep file rows preserve title and action space on $platform',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        var rowTaps = 0;
        var actionTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: FileTreeRow(
                  title: 'A long file name with two lines of readable text',
                  titleMaxLines: 2,
                  minHeight: 64,
                  depth: 40,
                  leading: const Icon(Icons.audio_file_rounded, size: 16),
                  onTap: () => rowTaps++,
                  trailing: TextButton(
                    onPressed: () => actionTaps++,
                    child: const Text('Restore'),
                  ),
                ),
              ),
            ),
          ),
        );
        final title = find.text(
          'A long file name with two lines of readable text',
        );
        final action = find.text('Restore');
        expect(tester.getSize(title).width, greaterThan(40));
        expect(
          tester.getRect(title).right,
          lessThanOrEqualTo(tester.getRect(find.byType(TextButton)).left),
        );
        expect(
          tester.getSize(find.byType(FileTreeRow)).height,
          greaterThanOrEqualTo(64),
        );
        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.byType(FileTreeRow),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(material.borderRadius, FileTreeRow.borderRadius);
        expect(material.clipBehavior, Clip.antiAlias);
        await tester.tap(action);
        expect(actionTaps, 1);
        expect(rowTaps, 0);
        await tester.tap(title);
        expect(rowTaps, 1);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
