import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('Flutter tooling can launch the app without duplicating its icon', () {
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
    expect(manifest, contains('<activity-alias'));
  });
}
