import 'package:flutter_test/flutter_test.dart';
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
      overlayCheck: () async => false,
      updateInstallCheck: () async => false,
    );

    final snapshot = await service.load();

    expect(snapshot.backgroundRunAllowed, isTrue);
    expect(snapshot.exactAlarmsAllowed, isTrue);
    expect(snapshot.manageFilesAllowed, isTrue);
    expect(snapshot.overlayAllowed, isFalse);
    expect(snapshot.updateInstallsAllowed, isFalse);
  });

  test('failed Android capability check is reported as unavailable', () async {
    final service = PermissionStatusService(
      isAndroidOverride: true,
      powerService: _FakePowerService(),
      overlayCheck: () async => true,
      updateInstallCheck: () => Future<bool>.error(StateError('unavailable')),
    );

    final snapshot = await service.load();

    expect(snapshot.updateInstallsAllowed, isFalse);
    expect(snapshot.overlayAllowed, isTrue);
  });

  test(
    'capability checks and settings actions use the focused contract',
    () async {
      var overlayOpenCount = 0;
      final service = PermissionStatusService(
        isAndroidOverride: true,
        powerService: _FakePowerService(),
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
