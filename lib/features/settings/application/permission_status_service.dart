import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/app_platform.dart';
import '../../../core/platform/notifications_platform_service.dart';
import '../../../core/platform/power_platform_service.dart';
import '../../player/application/subtitle_overlay_controller.dart';
import 'app_update_service.dart';

class PermissionStatusSnapshot {
  const PermissionStatusSnapshot({
    required this.notificationsEnabled,
    required this.backgroundRunAllowed,
    required this.exactAlarmsAllowed,
    required this.manageFilesAllowed,
    required this.overlayAllowed,
    required this.updateInstallsAllowed,
  });

  final bool notificationsEnabled;
  final bool backgroundRunAllowed;
  final bool exactAlarmsAllowed;
  final bool manageFilesAllowed;
  final bool overlayAllowed;
  final bool updateInstallsAllowed;

  Map<String, bool> toJson() => <String, bool>{
    'notificationsEnabled': notificationsEnabled,
    'backgroundRunAllowed': backgroundRunAllowed,
    'exactAlarmsAllowed': exactAlarmsAllowed,
    'manageFilesAllowed': manageFilesAllowed,
    'overlayAllowed': overlayAllowed,
    'updateInstallsAllowed': updateInstallsAllowed,
  };
}

class PermissionStatusService {
  PermissionStatusService({
    PowerPlatformService? powerService,
    NotificationsPlatformService? notificationsService,
    Future<bool> Function()? overlayCheck,
    SubtitleOverlayController? subtitleOverlayController,
    Future<bool> Function()? updateInstallCheck,
    AppUpdateService? appUpdateService,
    bool? isAndroidOverride,
  }) : _powerService = powerService ?? PowerPlatformService(),
       _notificationsService =
           notificationsService ?? NotificationsPlatformService(),
       _overlayCheck =
           overlayCheck ??
           (subtitleOverlayController ?? SubtitleOverlayController())
               .canDrawOverlays,
       _updateInstallCheck =
           updateInstallCheck ??
           (appUpdateService ?? AppUpdateService()).canInstallUnknownApps,
       _isAndroidOverride = isAndroidOverride;

  final PowerPlatformService _powerService;
  final NotificationsPlatformService _notificationsService;
  final Future<bool> Function() _overlayCheck;
  final Future<bool> Function() _updateInstallCheck;
  final bool? _isAndroidOverride;

  bool get _isAndroid => _isAndroidOverride ?? AppPlatform.isAndroid;

  Future<PermissionStatusSnapshot> load() async {
    if (!_isAndroid) {
      return const PermissionStatusSnapshot(
        notificationsEnabled: true,
        backgroundRunAllowed: true,
        exactAlarmsAllowed: true,
        manageFilesAllowed: true,
        overlayAllowed: true,
        updateInstallsAllowed: true,
      );
    }

    final results = await Future.wait<bool>([
      _check('notifications', _notificationsService.areNotificationsEnabled),
      _check('background_run', _powerService.isIgnoringBatteryOptimizations),
      _check('exact_alarms', _powerService.canScheduleExactAlarms),
      _check('manage_files', _powerService.canManageAllFilesAccess),
      _check('overlay', _overlayCheck),
      _check('update_installs', _updateInstallCheck),
    ]);
    return PermissionStatusSnapshot(
      notificationsEnabled: results[0],
      backgroundRunAllowed: results[1],
      exactAlarmsAllowed: results[2],
      manageFilesAllowed: results[3],
      overlayAllowed: results[4],
      updateInstallsAllowed: results[5],
    );
  }

  Future<bool> _check(String capability, Future<bool> Function() action) async {
    try {
      return await action();
    } catch (error, stackTrace) {
      AppLogService.warning(
        'permission_status_check_failed capability=$capability',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
