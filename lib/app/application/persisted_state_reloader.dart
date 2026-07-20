abstract interface class PersistedStateReloader {
  Future<void> reloadPersistedState();
}

abstract interface class PersistedStateReplacementPreparer {
  Future<void> prepareForPersistedStateReplacement();
}
