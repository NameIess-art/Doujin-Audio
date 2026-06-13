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
}
