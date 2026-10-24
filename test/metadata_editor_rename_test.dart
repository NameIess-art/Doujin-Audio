import 'dart:io';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;
  setUpAll(() async {
    database = await AppRuntimeTestFixture.installSharedDatabase();
  });
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));
  for (final directory in [false, true]) {
    for (final rename in [false, true]) {
      testWidgets(
        'metadata editor preserves suffix contract directory=$directory rename=$rename',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(800, 1600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          late Directory root;
          await tester.runAsync(() async {
            root = await Directory.systemTemp.createTemp('metadata_rename_');
          });
          addTearDown(() => root.delete(recursive: true));
          final originalName = directory ? 'Disc.01' : 'Track.part.01.mp3';
          final originalPath = path.join(root.path, originalName);
          await tester.runAsync(() async {
            if (directory) {
              await Directory(originalPath).create();
            } else {
              await File(originalPath).writeAsBytes([1]);
            }
          });
          final fixture = AppRuntimeWidgetTestFixture();
          addTearDown(fixture.dispose);
          DlsiteMetadataReviewResult? result;
          final target = directory
              ? AudioDetailTarget.libraryRootFolder(originalPath)
              : AudioDetailTarget.singleAudioFile(originalPath);
          await tester.pumpWidget(
            fixture.build(
              DlsiteMetadataReviewPage(
                editing: true,
                detail: AudioDetail.empty(
                  target,
                ).copyWith(duration: const Duration(seconds: 1)),
                onCompleted: (value) => result = value,
              ),
            ),
          );
          await pumpAndSettleWithAsync(tester);
          final nameField = find.descendant(
            of: find.byKey(
              const ValueKey('metadata_edit_audio_detail_folder_name'),
            ),
            matching: find.byType(TextField),
          );
          expect(
            tester.widget<TextField>(nameField).controller!.text,
            directory ? originalName : 'Track.part.01',
          );
          if (rename) await tester.enterText(nameField, 'New.part.02');
          await tester.tap(find.byKey(const ValueKey('dlsite_review_confirm')));
          for (var i = 0; i < 50 && result == null; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(result?.isApplied, isTrue);
          final expectedName = rename
              ? 'New.part.02${directory ? '' : '.mp3'}'
              : originalName;
          expect(
            path.basename(result!.detail!.target.targetPath),
            expectedName,
          );
          await tester.runAsync(() async {
            expect(
              await FileSystemEntity.type(path.join(root.path, expectedName)),
              directory
                  ? FileSystemEntityType.directory
                  : FileSystemEntityType.file,
            );
          });
          await tester.pumpWidget(const SizedBox.shrink());
          await pumpAndSettleWithAsync(tester);
          expect(tester.takeException(), isNull);
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.windows,
        }),
      );
    }
  }
}
