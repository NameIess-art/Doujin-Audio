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
       _overlayCheckOverride = overlayCheck,
       _overlayOpenOverride = overlayOpen,
       _subtitleOverlayController = subtitleOverlayController,
       _updateInstallCheckOverride = updateInstallCheck,
       _updateInstallOpenOverride = updateInstallOpen,
       _appUpdateService = appUpdateService,
       _isAndroidOverride = isAndroidOverride;

  final PowerPlatformService _powerService;
  final Future<bool> Function()? _overlayCheckOverride;
  final Future<bool> Function()? _overlayOpenOverride;
  final Future<bool> Function()? _updateInstallCheckOverride;
  final Future<bool> Function()? _updateInstallOpenOverride;
  SubtitleOverlayController? _subtitleOverlayController;
  bool _ownsSubtitleOverlayController = false;
  AppUpdateService? _appUpdateService;
  bool _ownsAppUpdateService = false;
  final bool? _isAndroidOverride;

  bool get _isAndroid => _isAndroidOverride ?? AppPlatform.isAndroid;

  SubtitleOverlayController _requireSubtitleOverlayController() {
    final existing = _subtitleOverlayController;
    if (existing != null) return existing;
    final created = SubtitleOverlayController();
    _subtitleOverlayController = created;
    _ownsSubtitleOverlayController = true;
    return created;
  }

  AppUpdateService _requireAppUpdateService() {
    final existing = _appUpdateService;
    if (existing != null) return existing;
    final created = AppUpdateService();
    _appUpdateService = created;
    _ownsAppUpdateService = true;
    return created;
  }

  Future<bool> _checkOverlay() {
    final override = _overlayCheckOverride;
    if (override != null) return override();
    return _requireSubtitleOverlayController().canDrawOverlays();
  }

  Future<bool> _openOverlay() {
    final override = _overlayOpenOverride;
    if (override != null) return override();
    return _requireSubtitleOverlayController().openOverlaySettings();
  }

  Future<bool> _checkUpdateInstall() {
    final override = _updateInstallCheckOverride;
    if (override != null) return override();
    return _requireAppUpdateService().canInstallUnknownApps();
  }

  Future<bool> _openUpdateInstall() {
    final override = _updateInstallOpenOverride;
    if (override != null) return override();
    return _requireAppUpdateService().openInstallPermissionSettings();
  }

  Future<void> dispose() async {
    if (_ownsSubtitleOverlayController) {
      final controller = _subtitleOverlayController;
      _subtitleOverlayController = null;
      _ownsSubtitleOverlayController = false;
      if (controller != null) {
        await controller.dispose();
      }
    }
    if (_ownsAppUpdateService) {
      final service = _appUpdateService;
      _appUpdateService = null;
      _ownsAppUpdateService = false;
      service?.dispose();
    }
  }

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
      PermissionCapability.overlay => _check('overlay', _checkOverlay),
      PermissionCapability.updateInstalls => _check(
        'update_installs',
        _checkUpdateInstall,
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
      PermissionCapability.overlay => _open('overlay', _openOverlay),
      PermissionCapability.updateInstalls => _open(
        'update_installs',
        _openUpdateInstall,
      ),
    };
  }

  Future<BackgroundRunDiagnostics?> loadBackgroundRunDiagnostics() {
    if (!_isAndroid) return Future<BackgroundRunDiagnostics?>.value();
    return _powerService.getBackgroundRunDiagnostics();
  }

  Future<bool> openBatteryOptimizationSettings() {
    if (!_isAndroid) return Future<bool>.value(false);
    return _open(
      'battery_optimization',
      _powerService.openBatteryOptimizationSettings,
    );
  }

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
