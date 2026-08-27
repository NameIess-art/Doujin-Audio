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

  test('Android exposes only the fixed main launcher activity', () {
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
    expect(
      RegExp(r'android\.intent\.category\.LAUNCHER').allMatches(manifest),
      hasLength(1),
    );
    expect(manifest, isNot(contains('android:name=".common.MainActivity')));
    expect(manifest, isNot(contains('<activity-alias')));
  });
}
