# Library Scanning Flow

```text
LibraryTab
  -> LibraryScanCoordinator
  -> LibraryScannerService
  -> FileCachePlatformGateway / file-system isolate
  -> AudioProviderLibraryCatalog
  -> AudioProvider facade
  -> LibraryService + database repository
```

`LibraryScanCoordinator` exposes `refresh`, `importFolder`, `importLibrary`,
`importFiles`, and `cancel`, and publishes idle/running/success/cancelled/failure
operation state. UI feedback remains a presentation concern.

`LibraryScannerService` does not depend on the concrete `AudioProvider` type.
It uses `LibraryCatalogReader` for immutable snapshots and
`LibraryCatalogWriter` for scan generations, staged batches, and persistence
commands. `AudioProviderLibraryCatalog` is only an adapter; it does not store a
second writable library.

Every scan receives a generation. Chunk results are applied only while that
generation remains active. Cancellation invalidates the generation, native
listeners stop delivering accepted chunks, and incomplete imports roll back
tracks and library entries added by that operation. Successful refreshes defer
destructive cleanup until staged chunks have completed, so an old or cancelled
task cannot delete state produced by a newer scan.

Manual Android checks should cover local and SAF folders, duplicate and nested
directories, cancellation, empty folders, permission denial, and application
restart after a completed import.
