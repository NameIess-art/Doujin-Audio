abstract interface class PersistedStateReloader {
  Future<void> reloadPersistedState();
}

abstract interface class PersistedStateExportPreparer {
  Future<void> prepareForPersistedStateExport();
}

abstract interface class PersistedStateReplacementPreparer {
  Future<void> prepareForPersistedStateReplacement();
}
