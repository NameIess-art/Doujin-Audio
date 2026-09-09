import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_update_service.dart';
import '../application/settings_repository.dart';
import '../application/settings_state.dart';

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  throw UnimplementedError(
    'appUpdateServiceProvider must be overridden in ProviderScope.',
  );
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw UnimplementedError(
    'settingsRepositoryProvider must be overridden in ProviderScope.',
  );
});

final settingsStateProvider = StreamProvider<SettingsState>((ref) {
  return ref.watch(settingsRepositoryProvider).slice.stream;
});
