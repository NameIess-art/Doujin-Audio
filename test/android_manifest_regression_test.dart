import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android production manifest stays SAF-only', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    for (final permission in <String>[
      'android.permission.MANAGE_EXTERNAL_STORAGE',
      'android.permission.READ_MEDIA_AUDIO',
      'android.permission.READ_MEDIA_VIDEO',
      'android.permission.READ_EXTERNAL_STORAGE',
    ]) {
      expect(manifest, isNot(contains(permission)), reason: permission);
    }

    final productionDart = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    expect(productionDart, isNot(contains('Permission.manageExternalStorage')));
  });

  test('Android keeps the Flutter surface stable during IME animation', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:windowSoftInputMode="adjustNothing"'));
    expect(
      manifest,
      isNot(contains('android:windowSoftInputMode="adjustResize"')),
    );
  });

  test('Flutter tooling can launch alongside themed launcher activities', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:name=".MainActivity"'));
    expect(manifest, contains('android.intent.action.MAIN'));
    expect(manifest, contains('android.intent.category.LAUNCHER'));
    expect(
      manifest,
      contains('android:scheme="\${applicationId}.integration-test"'),
    );
    expect(manifest, contains('android:name=".common.MainActivityWarmSystem"'));
    expect(manifest, isNot(contains('<activity-alias')));
  });
}
