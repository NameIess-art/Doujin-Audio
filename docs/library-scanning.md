# Library Scanning Flow

```text
LibraryTab
  -> LibraryScanCoordinator
  -> LibraryScannerService
  -> LibraryScanDataSource
  -> FileCachePlatformGateway / file-system isolate
  -> AudioProviderLibraryCatalog
  -> AudioProvider facade
  -> LibraryService + database repository
```

`LibraryScanCoordinator` exposes `refresh`, `importFolder`, `importLibrary`,
`importFiles`, and `cancel`, and publishes idle/running/success/cancelled/failure
operation state. UI feedback remains a presentation concern.

Library presentation converts localized picker labels into `LibraryScanLabels`
and maps the returned `LibraryScanOutcome` to localized text, tone, and icon.
The coordinator stores the typed outcome and a stable `AppFailure` when needed;
it does not import localization, call snackbar callbacks, or expose
`Exception.toString()` to the UI. The scanner reports stable codes, an operation
source, and count details.

Native scan wire DTOs and parsers live in `core/platform`; library labels and
outcomes remain in library application. This lets `FileCachePlatformGateway`
decode native payloads without depending back on a feature application layer.

`LibraryScanDataSource` owns Android permission checks, picker fallbacks,
temporary imports, native local/SAF calls, and the isolate-backed local scan.
`LibraryScanRules` is pure Dart and owns duplicate/nested/overlap decisions.

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

On Android, `FolderScanOperations` owns local, SAF, DocumentsContract, and
MediaStore enumeration. `DocumentStorageOperations`,
`MediaMetadataOperations`, `SubtitleOperations`, and
`CoverArtworkOperations` own their respective boundaries; the channel-facing
`FileCacheOperations` facade contains no scan or parsing rules. Stream events
are correlated with `taskId` plus `generationId`, and are suppressed after
cancellation or listener detachment.

Manual Android checks should cover local and SAF folders, duplicate and nested
directories, cancellation, empty folders, permission denial, and application
restart after a completed import.
