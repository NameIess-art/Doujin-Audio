package com.doujin.audio.storage

import java.util.concurrent.locks.ReentrantLock

internal data class SafDocumentRecovery<T>(
    val document: T?,
    val failed: Boolean = false
)

internal fun <T> recoverSafDocument(
    targetName: String,
    existing: T?,
    staleBackup: T?,
    staleTemp: T?,
    isValid: (T) -> Boolean,
    rename: (T, String) -> T?,
    delete: (T) -> Boolean
): SafDocumentRecovery<T> {
    fun remove(document: T?): Boolean = document == null ||
        runCatching { delete(document) }.getOrDefault(false)

    if (existing != null && runCatching { isValid(existing) }.getOrDefault(false)) {
        if (!remove(staleBackup) || !remove(staleTemp)) {
            return SafDocumentRecovery(document = existing, failed = true)
        }
        return SafDocumentRecovery(document = existing)
    }

    if (staleBackup != null && runCatching { isValid(staleBackup) }.getOrDefault(false)) {
        if (!remove(existing) || !remove(staleTemp)) {
            return SafDocumentRecovery(document = null, failed = true)
        }
        val restored = runCatching { rename(staleBackup, targetName) }.getOrNull()
        return SafDocumentRecovery(
            document = restored,
            failed = restored == null
        )
    }

    if (staleTemp != null && runCatching { isValid(staleTemp) }.getOrDefault(false)) {
        if (!remove(existing) || !remove(staleBackup)) {
            return SafDocumentRecovery(document = null, failed = true)
        }
        val committed = runCatching { rename(staleTemp, targetName) }.getOrNull()
        return SafDocumentRecovery(
            document = committed,
            failed = committed == null
        )
    }

    return SafDocumentRecovery(
        document = null,
        failed = existing != null || staleBackup != null || staleTemp != null
    )
}

internal object JsonDocumentOperationLocks {
    private data class Entry(
        val lock: ReentrantLock = ReentrantLock(),
        var references: Int = 0
    )

    private val monitor = Any()
    private val entries = mutableMapOf<String, Entry>()

    fun <T> withLock(key: String, action: () -> T): T {
        val entry = synchronized(monitor) {
            entries.getOrPut(key) { Entry() }.also { it.references++ }
        }
        entry.lock.lock()
        try {
            return action()
        } finally {
            entry.lock.unlock()
            synchronized(monitor) {
                entry.references--
                if (entry.references == 0 && entries[key] === entry) {
                    entries.remove(key)
                }
            }
        }
    }
}

internal fun <T> commitSafDocumentReplacement(
    targetName: String,
    current: T?,
    temporary: T,
    isValidCommitted: (T) -> Boolean = { true },
    rename: (T, String) -> T?,
    delete: (T) -> Boolean
): T? {
    val backupName = "$targetName.doujin.bak"
    val backup = if (current != null) {
        runCatching { rename(current, backupName) }.getOrNull().also {
            if (it == null) runCatching { delete(temporary) }
        } ?: return null
    } else {
        null
    }

    val committed = runCatching { rename(temporary, targetName) }.getOrNull()
    if (committed == null ||
        !runCatching { isValidCommitted(committed) }.getOrDefault(false)) {
        if (committed != null) runCatching { delete(committed) }
        if (backup != null) runCatching { rename(backup, targetName) }
        runCatching { delete(temporary) }
        return null
    }

    if (backup != null) runCatching { delete(backup) }
    return committed
}

internal fun <T> replaceSafDocument(
    targetName: String,
    existing: T?,
    staleBackup: T?,
    createTemp: () -> T?,
    writeTemp: (T) -> Boolean,
    rename: (T, String) -> T?,
    delete: (T) -> Boolean
): T? {
    var current = existing
    if (current == null && staleBackup != null) {
        current = runCatching { rename(staleBackup, targetName) }.getOrNull()
            ?: return null
    } else if (current != null && staleBackup != null) {
        return null
    }

    val temp = runCatching { createTemp() }.getOrNull() ?: return null
    fun cleanupTemp() {
        runCatching { delete(temp) }
    }
    if (runCatching { writeTemp(temp) }.getOrDefault(false).not()) {
        cleanupTemp()
        return null
    }

    return commitSafDocumentReplacement(
        targetName = targetName,
        current = current,
        temporary = temp,
        rename = rename,
        delete = delete
    )
}

internal fun <T> createSafDocumentIfAbsent(
    listFiles: () -> List<T>,
    isTarget: (T) -> Boolean,
    sameDocument: (T, T) -> Boolean,
    create: () -> T?,
    write: (T) -> Boolean,
    delete: (T) -> Boolean
): Boolean {
    if (listFiles().any(isTarget)) return false
    val created = runCatching { create() }.getOrNull() ?: return false
    // Some SAF providers return an existing same-name document from
    // createFile(). Never write to or delete that URI.
    if (isTarget(created)) return false
    if (listFiles().any { isTarget(it) && !sameDocument(it, created) }) {
        runCatching { delete(created) }
        return false
    }
    if (!runCatching { write(created) }.getOrDefault(false)) {
        runCatching { delete(created) }
        return false
    }
    return true
}
