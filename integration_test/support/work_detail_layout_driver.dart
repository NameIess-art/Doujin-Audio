import 'package:integration_test/integration_test_driver.dart';

// Android: build the existing .perf profile variant, install with adb install -r
// (stop on failure), then attach flutter drive --use-existing-app to its VM URI.
// This avoids Flutter's automatic uninstall fallback for an installed package.
Future<void> main() => integrationDriver();
