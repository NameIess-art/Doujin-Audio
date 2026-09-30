@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.doujin.audio.player.session

import android.os.Handler
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import com.doujin.audio.player.common.nativePlaybackWakeModeForUris
import com.doujin.audio.player.common.NativePrepareSessionArguments
import com.doujin.audio.player.common.NativeRepeatOneArguments
import com.doujin.audio.player.common.NativeUpdateQueueArguments
import java.util.concurrent.Executors

/** Immutable queue structures are prepared once, independently of player state. */
internal class NativePlaybackQueue(val descriptors: List<NativeMediaItemDescriptor>) {
    val mediaItems: List<MediaItem> by lazy {
        descriptors.map { descriptor ->
            val metadata = MediaMetadata.Builder()
                .setTitle(descriptor.title)
                .setArtist(descriptor.subtitle)
            descriptor.artUri?.takeIf(String::isNotBlank)?.let {
                metadata.setArtworkUri(android.net.Uri.parse(it))
            }
            MediaItem.Builder().setMediaId(descriptor.path).setUri(descriptor.uri)
                .setMediaMetadata(metadata.build()).build()
        }
    }
    val storedItems: List<StoredNativePlaybackQueueItem> by lazy {
        descriptors.map { descriptor ->
            StoredNativePlaybackQueueItem(
                descriptor.path, descriptor.uri, descriptor.title, descriptor.subtitle,
                descriptor.artUri, descriptor.candidateUris
            )
        }
    }
    val wakeMode: Int by lazy {
        nativePlaybackWakeModeForUris(descriptors.asSequence().flatMap {
            sequenceOf(it.uri) + it.candidateUris.asSequence()
        }.asIterable())
    }
    val retainedUris: List<String> by lazy {
        descriptors.asSequence().flatMap { sequenceOf(it.path, it.uri, it.artUri) }
            .filterNotNull().filter { it.startsWith("content://", ignoreCase = true) }
            .map { it.substringBefore("::") }.distinct().toList()
    }

    fun prepare() {
        mediaItems
        storedItems
        wakeMode
        retainedUris
    }
}

internal interface NativePlaybackQueuePreparationEnvironment {
    fun execute(task: () -> Unit)
    fun postMain(task: () -> Unit)
    fun shutdown()
}

internal class AndroidNativePlaybackQueuePreparationEnvironment(
    private val mainHandler: Handler
) : NativePlaybackQueuePreparationEnvironment {
    private val executor = Executors.newFixedThreadPool(2) { runnable ->
        Thread(runnable, "NativePlaybackQueue").apply { isDaemon = true }
    }
    override fun execute(task: () -> Unit) = executor.execute(task)
    override fun postMain(task: () -> Unit) { mainHandler.post(task) }
    override fun shutdown() { executor.shutdownNow() }
}

internal class NativePlaybackQueuePreparation(
    private val environment: NativePlaybackQueuePreparationEnvironment
) {
    private val requests = mutableMapOf<String, PendingQueue>()
    private var closed = false

    fun prepareSession(
        args: NativePrepareSessionArguments,
        sessions: NativePlaybackSessionManager,
        isServiceCurrent: () -> Boolean,
        complete: (Result<NativePrepareSessionArguments>) -> Unit
    ) {
        val expectedSession = sessions.get(args.sessionId)
        prepare(args.sessionId, args.playbackQueue(), {
            sessions.get(args.sessionId) === expectedSession && isServiceCurrent()
        }) { prepared ->
            complete(prepared.map { queue ->
                args.copy(queue = queue.descriptors, candidateUris = emptyList(), preparedQueue = queue)
            })
        }
    }

    fun prepareRepeatOne(
        args: NativeRepeatOneArguments,
        sessions: NativePlaybackSessionManager,
        isServiceCurrent: () -> Boolean,
        complete: (Result<NativeRepeatOneArguments>) -> Unit
    ) {
        val session = sessions.get(args.sessionId)
        if (session == null || args.queue.isEmpty()) {
            complete(Result.success(args))
            return
        }
        prepare(args.sessionId, args.queue, {
            sessions.get(args.sessionId) === session && isServiceCurrent()
        }) { prepared -> complete(prepared.map { args.copy(preparedQueue = it) }) }
    }

    fun prepareUpdate(
        args: NativeUpdateQueueArguments,
        sessions: NativePlaybackSessionManager,
        isServiceCurrent: () -> Boolean,
        complete: (Result<NativePlaybackQueue?>) -> Unit
    ) {
        val session = sessions.get(args.sessionId)
        if (session == null || args.queueRevision < session.queueRevision || args.queue.isEmpty()) {
            complete(Result.success(null))
            return
        }
        session.queueRevision = args.queueRevision
        prepare(args.sessionId, args.queue, {
            sessions.get(args.sessionId) === session && isServiceCurrent() &&
                session.queueRevision == args.queueRevision
        }, complete)
    }

    fun prepare(
        sessionId: String,
        queue: List<NativeMediaItemDescriptor>,
        isCurrent: () -> Boolean,
        complete: (Result<NativePlaybackQueue>) -> Unit
    ) {
        cancel(sessionId)
        val request = PendingQueue(complete)
        if (closed) { request.cancel(); return }
        requests[sessionId] = request
        environment.execute {
            if (request.completed) return@execute
            val prepared = runCatching { NativePlaybackQueue(queue).also(NativePlaybackQueue::prepare) }
            environment.postMain {
                if (requests[sessionId] !== request) return@postMain
                requests.remove(sessionId)
                if (!closed && isCurrent()) request.finish(prepared) else request.cancel()
            }
        }
    }

    fun cancel(sessionId: String) {
        requests.remove(sessionId)?.cancel()
    }
    fun cancelAll() { requests.keys.toList().forEach(::cancel) }
    fun shutdown() { closed = true; cancelAll(); environment.shutdown() }

    private class PendingQueue(private val complete: (Result<NativePlaybackQueue>) -> Unit) {
        @Volatile var completed = false
            private set
        fun finish(result: Result<NativePlaybackQueue>) {
            if (completed) return
            completed = true
            complete(result)
        }
        fun cancel() = finish(Result.failure(IllegalStateException("Playback queue preparation was superseded.")))
    }
}
