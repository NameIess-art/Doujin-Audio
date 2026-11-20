import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/app_platform.dart';
import '../../../core/platform/power_platform_service.dart';
import '../../player/application/subtitle_overlay_controller.dart';
import 'app_update_service.dart';

enum PermissionCapability {
  backgroundRun,
  notifications,
  exactAlarms,
  manageFiles,
  overlay,
  updateInstalls,
}

class PermissionStatusSnapshot {
  const PermissionStatusSnapshot({
    required this.backgroundRunAllowed,
    this.notificationsAllowed = true,
    required this.manageFilesAllowed,
    required this.overlayAllowed,
    required this.updateInstallsAllowed,
  });

  final bool backgroundRunAllowed;
  final bool notificationsAllowed;
  final bool manageFilesAllowed;
  final bool overlayAllowed;
  final bool updateInstallsAllowed;

  Map<String, bool> toJson() => <String, bool>{
    'backgroundRunAllowed': backgroundRunAllowed,
    'notificationsAllowed': notificationsAllowed,
    'manageFilesAllowed': manageFilesAllowed,
    'overlayAllowed': overlayAllowed,
    'updateInstallsAllowed': updateInstallsAllowed,
  };
}

class PermissionStatusService {
  PermissionStatusService({
    PowerPlatformService? powerService,
    Future<bool> Function()? overlayCheck,
    Future<bool> Function()? overlayOpen,
    SubtitleOverlayController? subtitleOverlayController,
    Future<bool> Function()? updateInstallCheck,
    Future<bool> Function()? updateInstallOpen,
    AppUpdateService? appUpdateService,
    bool? isAndroidOverride,
  }) : _powerService = powerService ?? PowerPlatformService(),
       _overlayCheck =
           overlayCheck ??
           (subtitleOverlayController ?? SubtitleOverlayController())
               .canDrawOverlays,
       _overlayOpen =
           overlayOpen ??
           (subtitleOverlayController ?? SubtitleOverlayController())
               .openOverlaySettings,
       _updateInstallCheck =
           updateInstallCheck ??
           (appUpdateService ?? AppUpdateService()).canInstallUnknownApps,
       _updateInstallOpen =
           updateInstallOpen ??
           (appUpdateService ?? AppUpdateService())
               .openInstallPermissionSettings,
       _isAndroidOverride = isAndroidOverride;

  final PowerPlatformService _powerService;
  final Future<bool> Function() _overlayCheck;
  final Future<bool> Function() _overlayOpen;
  final Future<bool> Function() _updateInstallCheck;
  final Future<bool> Function() _updateInstallOpen;
  final bool? _isAndroidOverride;

  bool get _isAndroid => _isAndroidOverride ?? AppPlatform.isAndroid;

  Future<bool> isGranted(
    PermissionCapability capability, {
    bool errorDefault = false,
  }) {
    if (!_isAndroid) return Future<bool>.value(true);
    return switch (capability) {
      PermissionCapability.backgroundRun => _check(
        'background_run',
        () => _powerService.isIgnoringBatteryOptimizations(
          errorDefault: errorDefault,
        ),
      ),
      PermissionCapability.notifications => _check(
        'notifications',
        _powerService.canPostNotifications,
      ),
      PermissionCapability.exactAlarms => _check(
        'exact_alarms',
        _powerService.canScheduleExactAlarms,
      ),
      PermissionCapability.manageFiles => _check(
        'manage_files',
        _powerService.canManageAllFilesAccess,
      ),
      PermissionCapability.overlay => _check('overlay', _overlayCheck),
      PermissionCapability.updateInstalls => _check(
        'update_installs',
        _updateInstallCheck,
      ),
    };
  }

  Future<bool> openSettings(PermissionCapability capability) {
    if (!_isAndroid) return Future<bool>.value(false);
    return switch (capability) {
      PermissionCapability.backgroundRun => _open(
        'background_run',
        _powerService.openBackgroundRunSettings,
      ),
      PermissionCapability.notifications => _open(
        'notifications',
        _powerService.openNotificationSettings,
      ),
      PermissionCapability.exactAlarms => _open(
        'exact_alarms',
        _powerService.openExactAlarmSettings,
      ),
      PermissionCapability.manageFiles => _open(
        'manage_files',
        _powerService.openManageAllFilesAccessSettings,
      ),
      PermissionCapability.overlay => _open('overlay', _overlayOpen),
      PermissionCapability.updateInstalls => _open(
        'update_installs',
        _updateInstallOpen,
      ),
    };
  }

  Future<BackgroundRunDiagnostics?> loadBackgroundRunDiagnostics() =>
      _powerService.getBackgroundRunDiagnostics();

  Future<bool> openBatteryOptimizationSettings() => _open(
    'battery_optimization',
    _powerService.openBatteryOptimizationSettings,
  );

  Future<PermissionStatusSnapshot> load() async {
    if (!_isAndroid) {
      return const PermissionStatusSnapshot(
        backgroundRunAllowed: true,
        manageFilesAllowed: true,
        overlayAllowed: true,
        updateInstallsAllowed: true,
      );
    }

    final (
      backgroundRun,
      notifications,
      manageFiles,
      overlay,
      updateInstalls,
    ) = await (
      isGranted(PermissionCapability.backgroundRun),
      isGranted(PermissionCapability.notifications),
      isGranted(PermissionCapability.manageFiles),
      isGranted(PermissionCapability.overlay),
      isGranted(PermissionCapability.updateInstalls),
    ).wait;
    return PermissionStatusSnapshot(
      backgroundRunAllowed: backgroundRun,
      notificationsAllowed: notifications,
      manageFilesAllowed: manageFiles,
      overlayAllowed: overlay,
      updateInstallsAllowed: updateInstalls,
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

  Future<bool> _open(String capability, Future<bool> Function() action) async {
    try {
      return await action();
    } catch (error, stackTrace) {
      AppLogService.warning(
        'permission_settings_open_failed capability=$capability',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
