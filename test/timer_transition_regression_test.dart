import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compact timer switches pages without a transition widget', () {
    final source = File(
      'lib/features/player/presentation/timer_tab_body.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('AnimatedSwitcher')));
    expect(source, isNot(contains('SlideTransition')));
  });
}
