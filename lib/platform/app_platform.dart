import 'dart:io';

abstract final class AppPlatform {
  static bool get isAndroid => Platform.isAndroid;
  static bool get isDesktopLinux => Platform.isLinux;
  static bool get isWindows => Platform.isWindows;

  static bool get usesDesktopDatabase => Platform.isWindows || Platform.isLinux;

  static bool get usesDesktopPlaybackBridge =>
      Platform.isWindows && Platform.environment['FLUTTER_TEST'] != 'true';

  static bool get showsDesktopScrollbars => Platform.isWindows;
}

bool isWindowsDriveFileUri(Uri uri) {
  return AppPlatform.isWindows &&
      uri.pathSegments.isNotEmpty &&
      RegExp(r'^[A-Za-z]:$').hasMatch(uri.pathSegments.first);
}
