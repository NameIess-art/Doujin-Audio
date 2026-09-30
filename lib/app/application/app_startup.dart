import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../../core/cache/app_cache_service.dart';
import '../../core/logging/app_log_service.dart';
import '../../features/data_support/application/data_backup_service.dart';
import '../../features/player/application/native_playback_repository.dart';

Future<void> initializePlatformRuntime() async {
  if (Platform.isWindows) {
    MediaKit.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await getApplicationSupportDirectory();
    await databaseFactory.setDatabasesPath(
      path.join(directory.path, 'databases'),
    );
  }
}

Future<StartupRestoreOutcome?> initializeAudioPlayerStartup({
  required Future<void> uiInitialization,
}) async {
  await AppLogService.measureAsync(
    'app_bootstrap_pre_run_app',
    () => Future.wait([
      uiInitialization,
      if (!Platform.isWindows)
        AudioSession.instance.then(
          (session) =>
              session.configure(const AudioSessionConfiguration.music()),
        ),
    ]),
  );
  final restoreOutcome = await DataBackupService().applyAtStartup();
  if (restoreOutcome?.succeeded == true) {
    final nativePlayback = NativePlaybackRepository();
    try {
      await nativePlayback.clearAll();
    } finally {
      await nativePlayback.dispose();
    }
    await AppCacheService.clearAllCaches();
    AppLogService.info('backup_restore_applied');
  } else if (restoreOutcome != null) {
    AppLogService.warning(
      'backup_restore_failed code=${restoreOutcome.errorCode}',
    );
  }
  return restoreOutcome;
}
