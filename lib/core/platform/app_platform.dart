import 'dart:io';

abstract final class AppPlatform {
  static bool get isAndroid => Platform.isAndroid;
  static bool get isWindows => Platform.isWindows;
}
