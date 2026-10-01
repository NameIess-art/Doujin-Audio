package com.doujin.audio

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.AndroidJUnit4
import com.doujin.audio.player.session.NativePlaybackStateStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Uses the platform JSON reader and preferences; no playback service is started. */
@Suppress("DEPRECATION")
@RunWith(AndroidJUnit4::class)
class NativePlaybackTimerCandidatesTest {
    private lateinit var preferences: SharedPreferences
    private lateinit var storeContext: Context

    @Before
    fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        preferences = context.getSharedPreferences("timer_candidates_test", Context.MODE_PRIVATE)
        storeContext = object : ContextWrapper(context) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = preferences
        }
        preferences.edit().clear().commit()
        NativePlaybackStateStore.clearSessions(storeContext)
    }

    @After
    fun tearDown() {
        NativePlaybackStateStore.clearSessions(storeContext)
        preferences.edit().clear().commit()
    }

    @Test
    fun testLargeQueuesAndInvalidEntriesDoNotHideActiveSessions() {
        val queue = (1..2000).joinToString(",") { "{\"uri\":\"file:///track$it.mp3\",\"title\":\"Track $it\"}" }
        preferences.edit().putString("sessions", """
            [null, 12, {}, {"sessionId":"missing-uri","playing":true},
             {"sessionId":"paused","uri":"file:///paused","playing":false,"playWhenReady":false},
             {"sessionId":"active","uri":"file:///active","playing":true,"queue":[$queue]},
             {"sessionId":"ready","uri":"file:///ready","playing":null,"playWhenReady":"true"}]
        """).commit()

        assertEquals(setOf("active", "ready"), NativePlaybackStateStore.loadActiveSessionRevisions(storeContext).keys)
    }

    @Test
    fun testProgressOverlayDeterminesCandidatesInsteadOfOlderDefinitionFlags() {
        preferences.edit().putString("sessions", """
            [{"sessionId":"stopped","uri":"file:///a","playing":true},
             {"sessionId":"started","uri":"file:///b","playing":false}]
        """).putString("session_progress_v1", """
            [{"sessionId":"stopped","positionMs":10,"playing":false,"playWhenReady":false},
             {"sessionId":"started","positionMs":20,"playing":false,"playWhenReady":true}]
        """).commit()

        assertEquals(setOf("started"), NativePlaybackStateStore.loadActiveSessionRevisions(storeContext).keys)
    }

    @Test
    fun testTemporaryPlayingSessionSurvivesCorruptPersistedDefinitions() {
        preferences.edit().putString("sessions", """
            [{"sessionId":"seed","uri":"file:///a","playing":false}]
        """).commit()
        val session = NativePlaybackStateStore.loadSessions(storeContext).single().copy(
            sessionId = "temporary", isTemporary = true, playWhenReady = true
        )
        NativePlaybackStateStore.saveTemporarySession(session)
        preferences.edit().putString("sessions", "[").commit()

        assertEquals(setOf("temporary"), NativePlaybackStateStore.loadActiveSessionRevisions(storeContext).keys)
    }

    @Test
    fun testInvalidationDuringReadCannotMakeOldDefinitionCurrent() {
        preferences.edit().putString("sessions", """
            [{"sessionId":"removed","uri":"file:///a","playing":true},
             {"sessionId":"unchanged","uri":"file:///b","playing":true}]
        """).commit()
        val invalidatingContext = object : ContextWrapper(storeContext) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                object : SharedPreferences by preferences {
                    override fun getString(key: String?, default: String?): String? {
                        if (key == "sessions") NativePlaybackStateStore.invalidateSession("removed")
                        return preferences.getString(key, default)
                    }
                }
        }

        assertEquals(setOf("unchanged"), NativePlaybackStateStore.loadActiveSessionRevisions(invalidatingContext).keys)
    }
}
