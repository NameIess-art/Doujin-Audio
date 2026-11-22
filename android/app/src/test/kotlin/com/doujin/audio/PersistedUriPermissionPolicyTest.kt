package com.doujin.audio

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import com.doujin.audio.storage.PersistedUriPermissionOperations
import com.doujin.audio.storage.persistedGrantCoversReference
import com.doujin.audio.storage.pendingPickerGrantIsActive
import com.doujin.audio.storage.permissionModesCover
import com.doujin.audio.storage.permissionMigrationRequired
import com.doujin.audio.storage.shouldMigratePermissionAfterRename
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class PersistedUriPermissionPolicyTest {
    @Test
    fun `tree grant covers tree documents and synthetic children`() {
        val tree = "content://com.android.externalstorage.documents/tree/primary%3AMusic"

        assertTrue(
            persistedGrantCoversReference(
                tree,
                "$tree::ASMR/work/audio.mp3"
            )
        )
        assertTrue(
            persistedGrantCoversReference(
                tree,
                "$tree/document/primary%3AMusic%2FASMR%2Fwork%2Faudio.mp3"
            )
        )
    }

    @Test
    fun `tree grant covers opaque child document ids from the same tree`() {
        val tree = "content://cloud.provider/tree/root42"

        assertTrue(
            persistedGrantCoversReference(
                tree,
                "$tree/document/item99"
            )
        )
    }

    @Test
    fun `tree grant does not cover sibling prefix or another authority`() {
        val tree = "content://com.android.externalstorage.documents/tree/primary%3AMusic"

        assertFalse(
            persistedGrantCoversReference(
                tree,
                "content://com.android.externalstorage.documents/" +
                    "document/primary%3AMusicBackup%2Faudio.mp3"
            )
        )
        assertFalse(
            persistedGrantCoversReference(
                tree,
                "content://other.provider/tree/primary%3AMusic"
            )
        )
    }

    @Test
    fun `document grant only covers the exact document`() {
        val document = "content://provider/document/root%3Afile.mp3"

        assertTrue(persistedGrantCoversReference(document, document))
        assertFalse(
            persistedGrantCoversReference(
                document,
                "content://provider/document/root%3Aother.mp3"
            )
        )
    }

    @Test
    fun `tree based document grant does not become a tree grant`() {
        val document = "content://provider/tree/root%3AMusic/" +
            "document/root%3AMusic%2Fone.mp3"

        assertTrue(persistedGrantCoversReference(document, document))
        assertFalse(
            persistedGrantCoversReference(
                document,
                "content://provider/tree/root%3AMusic/" +
                    "document/root%3AMusic%2Ftwo.mp3"
            )
        )
    }

    @Test
    fun `rename migrates only tree roots or independent document grants`() {
        assertTrue(
            shouldMigratePermissionAfterRename(
                hasTreeRootGrant = true,
                renamingTreeRoot = true
            )
        )
        assertTrue(
            shouldMigratePermissionAfterRename(
                hasTreeRootGrant = false,
                renamingTreeRoot = false
            )
        )
        assertFalse(
            shouldMigratePermissionAfterRename(
                hasTreeRootGrant = true,
                renamingTreeRoot = false
            )
        )
    }

    @Test
    fun `provider rename returning the same URI does not migrate permission`() {
        val uri = "content://provider/document/root%3Afile.mp3"

        assertFalse(permissionMigrationRequired(uri, uri))
        assertTrue(
            permissionMigrationRequired(
                uri,
                "content://provider/document/root%3Arenamed.mp3"
            )
        )
    }

    @Test
    fun `existing permission must include every newly requested mode`() {
        assertTrue(
            permissionModesCover(
                requestedRead = true,
                requestedWrite = false,
                hasRead = true,
                hasWrite = false
            )
        )
        assertFalse(
            permissionModesCover(
                requestedRead = true,
                requestedWrite = true,
                hasRead = true,
                hasWrite = false
            )
        )
    }

    @Test
    fun `pending picker or rename grant expires after its reconciliation grace window`() {
        assertTrue(
            pendingPickerGrantIsActive(
                acquiredAtMs = 1_000,
                nowMs = 1_500,
                ttlMs = 1_000
            )
        )
        assertFalse(
            pendingPickerGrantIsActive(
                acquiredAtMs = 1_000,
                nowMs = 2_000,
                ttlMs = 1_000
            )
        )
    }

    @Test
    fun `tree grant covers tree uri with brackets and special characters`() {
        val tree = "content://com.android.externalstorage.documents/tree/primary%3AASMR%2F[RJ123456]"

        assertTrue(
            persistedGrantCoversReference(
                tree,
                "$tree::[RJ123456] Title/track.mp3"
            )
        )
        assertTrue(
            persistedGrantCoversReference(
                tree,
                tree
            )
        )
        assertTrue(
            persistedGrantCoversReference(
                "$tree/",
                tree
            )
        )
    }

    @Test
    fun `storage root tree grant covers child document ids`() {
        val rootTree = "content://com.android.externalstorage.documents/tree/primary%3A"

        assertTrue(
            persistedGrantCoversReference(
                rootTree,
                "content://com.android.externalstorage.documents/tree/primary%3A/document/primary%3AMusic%2Faudio.mp3"
            )
        )
        assertTrue(
            persistedGrantCoversReference(
                rootTree,
                "content://com.android.externalstorage.documents/document/primary%3ADownload%2FASMR"
            )
        )
    }

    @Test
    fun `pending transition grants expire based on monotonic elapsedRealtime clock`() {
        val resolver: ContentResolver = RuntimeEnvironment.getApplication().contentResolver
        val uri = Uri.parse("content://com.android.externalstorage.documents/tree/primary%3ATestMonotonic")
        var monotonicMs = 10_000L
        val previousClock = PersistedUriPermissionOperations.elapsedRealtimeClock
        PersistedUriPermissionOperations.elapsedRealtimeClock = { monotonicMs }
        PersistedUriPermissionOperations.clearPendingTransitionGrantsForTest()
        try {
            PersistedUriPermissionOperations.takeForPicker(
                resolver = resolver,
                uri = uri,
                intentFlags = Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            // Within 2-minute TTL -> retained even if retainedUris does not include it yet.
            monotonicMs += 60_000L
            val retainedResult = PersistedUriPermissionOperations.reconcile(resolver, emptySet())
            assertEquals(1, retainedResult.retainedCount)
            assertEquals(0, retainedResult.releasedCount)

            // Past 2-minute TTL -> expired and released.
            monotonicMs += 60_000L
            val expiredResult = PersistedUriPermissionOperations.reconcile(resolver, emptySet())
            assertEquals(0, expiredResult.retainedCount)
            assertEquals(1, expiredResult.releasedCount)
            assertTrue(resolver.persistedUriPermissions.none { it.uri == uri })
        } finally {
            PersistedUriPermissionOperations.elapsedRealtimeClock = previousClock
            PersistedUriPermissionOperations.clearPendingTransitionGrantsForTest()
        }
    }
}
