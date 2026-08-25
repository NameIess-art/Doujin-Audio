import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/platform/notifications_platform_service.dart';
import 'package:doujin_audio/features/settings/application/permission_status_service.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';

void main() {
  test(
    'non-Android snapshot reports platform capabilities as available',
    () async {
      final service = PermissionStatusService(isAndroidOverride: false);

      final snapshot = await service.load();

      expect(snapshot.toJson().values, everyElement(isTrue));
    },
  );

  test('Android snapshot combines existing platform status services', () async {
    final service = PermissionStatusService(
      isAndroidOverride: true,
      powerService: PowerPlatformService(isAndroidOverride: false),
      notificationsService: NotificationsPlatformService(
        isAndroidOverride: false,
      ),
      overlayCheck: () async => false,
      updateInstallCheck: () async => false,
    );

    final snapshot = await service.load();

    expect(snapshot.notificationsEnabled, isTrue);
    expect(snapshot.backgroundRunAllowed, isTrue);
    expect(snapshot.exactAlarmsAllowed, isTrue);
    expect(snapshot.manageFilesAllowed, isTrue);
    expect(snapshot.overlayAllowed, isFalse);
    expect(snapshot.updateInstallsAllowed, isFalse);
  });

  test('failed Android capability check is reported as unavailable', () async {
    final service = PermissionStatusService(
      isAndroidOverride: true,
      notificationsService: _FakeNotificationsService(
        check: () => Future<bool>.error(StateError('unavailable')),
      ),
      powerService: _FakePowerService(),
      overlayCheck: () async => true,
      updateInstallCheck: () async => true,
    );

    final snapshot = await service.load();

    expect(snapshot.notificationsEnabled, isFalse);
    expect(snapshot.overlayAllowed, isTrue);
  });

  test(
    'capability checks and settings actions use the focused contract',
    () async {
      var overlayOpenCount = 0;
      final service = PermissionStatusService(
        isAndroidOverride: true,
        powerService: _FakePowerService(),
        notificationsService: _FakeNotificationsService(
          check: () async => true,
        ),
        overlayCheck: () async => false,
        overlayOpen: () async {
          overlayOpenCount++;
          return true;
        },
        updateInstallCheck: () async => true,
        updateInstallOpen: () async => true,
      );

      expect(await service.isGranted(PermissionCapability.overlay), isFalse);
      expect(await service.openSettings(PermissionCapability.overlay), isTrue);
      expect(overlayOpenCount, 1);
    },
  );

  test(
    'notification permission request and settings fallback stay in service',
    () async {
      var requestCount = 0;
      var fallbackCount = 0;
      final service = PermissionStatusService(
        isAndroidOverride: true,
        powerService: _FakePowerService(),
        notificationsService: _FakeNotificationsService(
          check: () async => false,
          open: () async => false,
        ),
        notificationPermissionCheck: () async => false,
        notificationPermissionRequest: () async {
          requestCount++;
          return true;
        },
        notificationAppSettingsOpen: () async {
          fallbackCount++;
          return true;
        },
        overlayCheck: () async => true,
        updateInstallCheck: () async => true,
      );

      expect(await service.request(PermissionCapability.notifications), isTrue);
      expect(requestCount, 1);
      expect(
        await service.openSettings(PermissionCapability.notifications),
        isTrue,
      );
      expect(fallbackCount, 1);
    },
  );
}

class _FakeNotificationsService extends NotificationsPlatformService {
  _FakeNotificationsService({required this.check, this.open});

  final Future<bool> Function() check;
  final Future<bool> Function()? open;

  @override
  Future<bool> areNotificationsEnabled() => check();

  @override
  Future<bool> openNotificationSettings() => open?.call() ?? Future.value(true);
}

class _FakePowerService extends PowerPlatformService {
  @override
  Future<bool> isIgnoringBatteryOptimizations({
    bool errorDefault = false,
  }) async => true;

  @override
  Future<bool> canScheduleExactAlarms() async => true;

  @override
  Future<bool> canManageAllFilesAccess() async => true;
}
