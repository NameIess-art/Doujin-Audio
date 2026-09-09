import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/asmr/application/asmr_account_sync_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_persistence_repository.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';

typedef TestAsmrServices = ({
  AsmrPreferencesStore preferencesStore,
  AsmrRemoteCatalogService remoteCatalogService,
  AsmrAccountSyncService accountSyncService,
});

TestAsmrServices createTestAsmrServices({
  AsmrPreferencesStore? preferencesStore,
  AsmrPersistenceRepository? persistenceRepository,
  AsmrApiService? apiService,
  AsmrAuthService? authService,
}) {
  final repository =
      persistenceRepository ??
      SqliteAsmrRepository(database: AppDatabase.instance);
  final preferences =
      preferencesStore ?? AsmrPreferencesStore(repository: repository);
  final api = apiService ?? AsmrApiService();
  // The fixture owns service resources; some tests exercise explicit closing.
  addTearDown(() {
    if (!api.isClosed) api.close();
  });
  return (
    preferencesStore: preferences,
    remoteCatalogService: AsmrRemoteCatalogService(
      apiService: api,
      persistenceRepository: repository,
    ),
    accountSyncService: AsmrAccountSyncService(
      authService: authService ?? AsmrAuthService(apiService: api),
      apiService: api,
      preferencesStore: preferences,
    ),
  );
}

AsmrLibraryController createTestAsmrController({
  required AsmrPreferencesStore preferencesStore,
  required AsmrPersistenceRepository persistenceRepository,
  AsmrApiService? apiService,
  AsmrAuthService? authService,
}) {
  final services = createTestAsmrServices(
    preferencesStore: preferencesStore,
    persistenceRepository: persistenceRepository,
    apiService: apiService,
    authService: authService,
  );
  final controller = AsmrLibraryController(
    preferencesStore: services.preferencesStore,
    remoteCatalogService: services.remoteCatalogService,
    accountSyncService: services.accountSyncService,
  );
  addTearDown(controller.dispose);
  return controller;
}
