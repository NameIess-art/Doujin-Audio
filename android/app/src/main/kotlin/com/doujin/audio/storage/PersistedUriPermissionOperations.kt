package com.doujin.audio.storage

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal data class PersistedUriPermissionReconcileResult(
    val retainedCount: Int,
    val releasedCount: Int,
    val failedUris: List<String>
) {
    fun toMap(): Map<String, Any> = mapOf(
        "retainedCount" to retainedCount,
        "releasedCount" to releasedCount,
        "failedUris" to failedUris
    )
}

internal data class NewlyPersistedUriPermission(
    val uri: Uri,
    val modeFlags: Int
)

internal object PersistedUriPermissionOperations {
    private const val pendingPickerGrantTtlMs = 2 * 60 * 1000L
    private val permissionLock = ReentrantLock()
    private val pendingTransitionGrants = linkedMapOf<String, Long>()

    fun <T> withPermissionLock(block: () -> T): T = permissionLock.withLock(block)

    fun takeForPicker(
        resolver: ContentResolver,
        uri: Uri,
        intentFlags: Int
    ): NewlyPersistedUriPermission? = withPermissionLock {
        require(intentFlags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) {
            "The selected provider did not offer a persistable URI permission."
        }
        val modeFlags = grantedReadWriteFlags(intentFlags)
        require(modeFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0) {
            "The selected provider did not offer a readable URI permission."
        }
        val rawUri = uri.toString()
        val existingPermissions = resolver.persistedUriPermissions
        val coveringPermissions = existingPermissions.filter {
            persistedGrantCoversReference(it.uri.toString(), rawUri)
        }
        if (permissionModesCover(
                requestedRead = modeFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0,
                requestedWrite = modeFlags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0,
                hasRead = coveringPermissions.any { it.isReadPermission },
                hasWrite = coveringPermissions.any { it.isWritePermission }
            )
        ) {
            pendingTransitionGrants[rawUri] = System.currentTimeMillis()
            return@withPermissionLock NewlyPersistedUriPermission(uri, 0)
        }
        val existingExact = existingPermissions.firstOrNull { it.uri == uri }
        val existingExactFlags = permissionModeFlags(
            existingExact?.isReadPermission == true,
            existingExact?.isWritePermission == true
        )
        val addedModeFlags = modeFlags and existingExactFlags.inv()
        try {
            resolver.takePersistableUriPermission(uri, modeFlags)
        } catch (error: Exception) {
            throw SecurityException("Unable to persist the selected URI permission.", error)
        }
        val persisted = resolver.persistedUriPermissions.firstOrNull { it.uri == uri }
        if (persisted == null || !permissionModesCover(
                requestedRead = modeFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0,
                requestedWrite = modeFlags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0,
                hasRead = persisted.isReadPermission,
                hasWrite = persisted.isWritePermission
            )
        ) {
            if (addedModeFlags != 0) {
                runCatching { resolver.releasePersistableUriPermission(uri, addedModeFlags) }
            }
            throw SecurityException("The selected URI permission was not persisted.")
        }
        pendingTransitionGrants[rawUri] = System.currentTimeMillis()
        NewlyPersistedUriPermission(uri, addedModeFlags)
    }

    fun rollbackPickerGrants(
        resolver: ContentResolver,
        grants: Iterable<NewlyPersistedUriPermission>
    ) = withPermissionLock {
        grants.toList().asReversed().forEach { grant ->
            pendingTransitionGrants.remove(grant.uri.toString())
            if (grant.modeFlags != 0) {
                runCatching {
                    resolver.releasePersistableUriPermission(grant.uri, grant.modeFlags)
                }
            }
        }
    }

    fun migrateRenamedGrant(
        resolver: ContentResolver,
        oldUri: Uri,
        newUri: Uri
    ) = withPermissionLock {
        if (!permissionMigrationRequired(oldUri.toString(), newUri.toString())) {
            return@withPermissionLock
        }
        val existing = resolver.persistedUriPermissions.firstOrNull { it.uri == oldUri }
            ?: return@withPermissionLock
        val modeFlags = permissionModeFlags(existing.isReadPermission, existing.isWritePermission)
        if (modeFlags == 0) return@withPermissionLock
        val existingNew = resolver.persistedUriPermissions.firstOrNull { it.uri == newUri }
        val existingNewFlags = permissionModeFlags(
            existingNew?.isReadPermission == true,
            existingNew?.isWritePermission == true
        )
        val addedNewModeFlags = modeFlags and existingNewFlags.inv()
        try {
            resolver.takePersistableUriPermission(newUri, modeFlags)
        } catch (error: Exception) {
            throw SecurityException("Unable to persist permission for the renamed document.", error)
        }
        if (resolver.persistedUriPermissions.none { it.uri == newUri }) {
            if (addedNewModeFlags != 0) {
                runCatching {
                    resolver.releasePersistableUriPermission(newUri, addedNewModeFlags)
                }
            }
            throw SecurityException("Permission for the renamed document was not persisted.")
        }
        try {
            resolver.releasePersistableUriPermission(oldUri, modeFlags)
        } catch (error: Exception) {
            if (addedNewModeFlags != 0) {
                runCatching {
                    resolver.releasePersistableUriPermission(newUri, addedNewModeFlags)
                }
            }
            throw SecurityException("Unable to release permission for the previous document.", error)
        }
        pendingTransitionGrants[newUri.toString()] = System.currentTimeMillis()
    }

    fun reconcile(
        resolver: ContentResolver,
        retainedUris: Set<String>
    ): PersistedUriPermissionReconcileResult = withPermissionLock {
        val nowMs = System.currentTimeMillis()
        pendingTransitionGrants.entries.removeAll { (_, acquiredAtMs) ->
            !pendingPickerGrantIsActive(
                acquiredAtMs = acquiredAtMs,
                nowMs = nowMs,
                ttlMs = pendingPickerGrantTtlMs
            )
        }
        val acknowledgedPendingUris = pendingTransitionGrants.keys.filter { pendingUri ->
            retainedUris.any { retainedUri ->
                persistedGrantCoversReference(pendingUri, retainedUri)
            }
        }
        acknowledgedPendingUris.forEach(pendingTransitionGrants::remove)
        var retainedCount = 0
        var releasedCount = 0
        val failedUris = mutableListOf<String>()
        resolver.persistedUriPermissions.forEach { permission ->
            val persistedUri = permission.uri.toString()
            if (retainedUris.any { persistedGrantCoversReference(persistedUri, it) } ||
                pendingTransitionGrants.keys.any {
                    persistedGrantCoversReference(persistedUri, it)
                }
            ) {
                retainedCount += 1
                return@forEach
            }
            val modeFlags = permissionModeFlags(
                permission.isReadPermission,
                permission.isWritePermission
            )
            try {
                resolver.releasePersistableUriPermission(permission.uri, modeFlags)
                releasedCount += 1
            } catch (_: Exception) {
                failedUris += persistedUri
            }
        }
        PersistedUriPermissionReconcileResult(
            retainedCount = retainedCount,
            releasedCount = releasedCount,
            failedUris = failedUris
        )
    }

    private fun grantedReadWriteFlags(flags: Int): Int = permissionModeFlags(
        flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0,
        flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0
    )

    private fun permissionModeFlags(canRead: Boolean, canWrite: Boolean): Int {
        var modeFlags = 0
        if (canRead) modeFlags = modeFlags or Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (canWrite) modeFlags = modeFlags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        return modeFlags
    }
}

internal fun permissionModesCover(
    requestedRead: Boolean,
    requestedWrite: Boolean,
    hasRead: Boolean,
    hasWrite: Boolean
): Boolean = (!requestedRead || hasRead) && (!requestedWrite || hasWrite)

internal fun pendingPickerGrantIsActive(
    acquiredAtMs: Long,
    nowMs: Long,
    ttlMs: Long
): Boolean = nowMs >= acquiredAtMs && nowMs - acquiredAtMs < ttlMs

internal fun persistedGrantCoversReference(
    persistedGrantUri: String,
    retainedReferenceUri: String
): Boolean {
    val grant = parsedContentReference(persistedGrantUri) ?: return false
    val reference = parsedContentReference(retainedReferenceUri) ?: return false
    if (!grant.authority.equals(reference.authority, ignoreCase = true)) return false
    if (grant.canonicalBase == reference.canonicalBase) return true
    if (grant.documentId != null) return false
    val treeId = grant.treeDocumentId ?: return false
    if (reference.treeDocumentId == treeId) return true
    val referenceId = reference.documentId ?: reference.treeDocumentId ?: return false
    return referenceId == treeId || referenceId.startsWith("${treeId.trimEnd('/')}/")
}

internal fun shouldMigratePermissionAfterRename(
    hasTreeRootGrant: Boolean,
    renamingTreeRoot: Boolean
): Boolean = renamingTreeRoot || !hasTreeRootGrant

internal fun permissionMigrationRequired(oldUri: String, newUri: String): Boolean =
    oldUri.trim() != newUri.trim()

private data class ParsedContentReference(
    val authority: String,
    val canonicalBase: String,
    val treeDocumentId: String?,
    val documentId: String?
)

private fun parsedContentReference(raw: String): ParsedContentReference? {
    val base = raw.trim().substringBefore("::")
    val uri = runCatching { URI(base) }.getOrNull() ?: return null
    if (!uri.scheme.equals("content", ignoreCase = true)) return null
    val authority = uri.authority?.takeIf { it.isNotBlank() } ?: return null
    val rawSegments = uri.rawPath.orEmpty().split('/').filter(String::isNotEmpty)
    fun decodedSegmentAfter(marker: String): String? {
        val index = rawSegments.indexOf(marker)
        if (index < 0 || index + 1 >= rawSegments.size) return null
        return URLDecoder.decode(rawSegments[index + 1], StandardCharsets.UTF_8.name())
    }
    val treeId = decodedSegmentAfter("tree")
    val documentId = decodedSegmentAfter("document")
    val canonicalBase = buildString {
        append(uri.scheme.lowercase())
        append("://")
        append(authority.lowercase())
        append(uri.rawPath.orEmpty())
        if (!uri.rawQuery.isNullOrEmpty()) append('?').append(uri.rawQuery)
    }
    return ParsedContentReference(authority, canonicalBase, treeId, documentId)
}
