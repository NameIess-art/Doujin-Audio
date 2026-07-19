import 'dart:io';

abstract final class AppPlatform {
  static bool get isAndroid => Platform.isAndroid;
}
