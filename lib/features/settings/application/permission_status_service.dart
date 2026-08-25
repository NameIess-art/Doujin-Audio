import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/app_platform.dart';
import '../../../core/platform/notifications_platform_service.dart';
import '../../../core/platform/power_platform_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../player/application/subtitle_overlay_controller.dart';
import 'app_update_service.dart';

enum PermissionCapability {
  notifications,
  backgroundRun,
  exactAlarms,
  manageFiles,
  overlay,
  updateInstalls,
}

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
    Future<bool> Function()? overlayOpen,
    SubtitleOverlayController? subtitleOverlayController,
    Future<bool> Function()? updateInstallCheck,
    Future<bool> Function()? updateInstallOpen,
    Future<bool> Function()? notificationPermissionCheck,
    Future<bool> Function()? notificationPermissionRequest,
    Future<bool> Function()? notificationAppSettingsOpen,
    AppUpdateService? appUpdateService,
    bool? isAndroidOverride,
  }) : _powerService = powerService ?? PowerPlatformService(),
       _notificationsService =
           notificationsService ?? NotificationsPlatformService(),
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
       _notificationPermissionCheck =
           notificationPermissionCheck ??
           (() async => (await Permission.notification.status).isGranted),
       _notificationPermissionRequest =
           notificationPermissionRequest ??
           (() async => (await Permission.notification.request()).isGranted),
       _notificationAppSettingsOpen =
           notificationAppSettingsOpen ?? openAppSettings,
       _isAndroidOverride = isAndroidOverride;

  final PowerPlatformService _powerService;
  final NotificationsPlatformService _notificationsService;
  final Future<bool> Function() _overlayCheck;
  final Future<bool> Function() _overlayOpen;
  final Future<bool> Function() _updateInstallCheck;
  final Future<bool> Function() _updateInstallOpen;
  final Future<bool> Function() _notificationPermissionCheck;
  final Future<bool> Function() _notificationPermissionRequest;
  final Future<bool> Function() _notificationAppSettingsOpen;
  final bool? _isAndroidOverride;

  bool get _isAndroid => _isAndroidOverride ?? AppPlatform.isAndroid;

  Future<bool> isGranted(
    PermissionCapability capability, {
    bool errorDefault = false,
  }) {
    if (!_isAndroid) return Future<bool>.value(true);
    return switch (capability) {
      PermissionCapability.notifications => _check(
        'notifications',
        _notificationsService.areNotificationsEnabled,
      ),
      PermissionCapability.backgroundRun => _check(
        'background_run',
        () => _powerService.isIgnoringBatteryOptimizations(
          errorDefault: errorDefault,
        ),
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
      PermissionCapability.notifications => _open(
        'notifications',
        _openNotificationSettings,
      ),
      PermissionCapability.backgroundRun => _open(
        'background_run',
        _powerService.openBackgroundRunSettings,
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

  Future<bool> request(PermissionCapability capability) async {
    if (!_isAndroid) return true;
    if (capability != PermissionCapability.notifications) {
      return isGranted(capability);
    }
    if (await _check('notification_permission', _notificationPermissionCheck)) {
      return true;
    }
    return _check(
      'notification_permission_request',
      _notificationPermissionRequest,
    );
  }

  Future<bool> _openNotificationSettings() async {
    if (await _notificationsService.openNotificationSettings()) return true;
    return _notificationAppSettingsOpen();
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
        notificationsEnabled: true,
        backgroundRunAllowed: true,
        exactAlarmsAllowed: true,
        manageFilesAllowed: true,
        overlayAllowed: true,
        updateInstallsAllowed: true,
      );
    }

    final results = await Future.wait<bool>([
      isGranted(PermissionCapability.notifications),
      isGranted(PermissionCapability.backgroundRun),
      isGranted(PermissionCapability.exactAlarms),
      isGranted(PermissionCapability.manageFiles),
      isGranted(PermissionCapability.overlay),
      isGranted(PermissionCapability.updateInstalls),
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
