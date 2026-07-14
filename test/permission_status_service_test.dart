import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/platform/notifications_platform_service.dart';
import 'package:nameless_audio/features/settings/application/permission_status_service.dart';
import 'package:nameless_audio/core/platform/power_platform_service.dart';

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
}

class _FakeNotificationsService extends NotificationsPlatformService {
  _FakeNotificationsService({required this.check});

  final Future<bool> Function() check;

  @override
  Future<bool> areNotificationsEnabled() => check();
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
