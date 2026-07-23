package com.nameless.audio

import com.nameless.audio.player.session.*

import androidx.media3.common.Player
import androidx.media3.session.SessionResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeMediaControllerAccessPolicyTest {
    private val policy = NativeMediaControllerAccessPolicy(
        appPackageName = "com.nameless.audio",
        appUid = 1000
    )

    @Test
    fun `app controller receives the complete player command profile`() {
        val decision = policy.connectionFor(
            identity(packageName = "com.nameless.audio", uid = 1000)
        )
        val access = decision.accessLevel
        val commands = decision.allowedCommands

        assertEquals(ControllerAccessLevel.APP_SELF, access)
        assertTrue(decision.accepted)
        assertTrue(commands.allowAllPlayerCommands)
        assertTrue(commands.useDefaultSessionCommands)
        assertEquals(
            SessionResult.RESULT_ERROR_NOT_SUPPORTED,
            policy.rejectedCustomCommandResult(access)
        )
    }

    @Test
    fun `trusted system controller receives standard transport commands only`() {
        val decision = policy.connectionFor(identity(trustedByMedia3 = true))
        val access = decision.accessLevel
        val commands = decision.allowedCommands

        assertEquals(ControllerAccessLevel.SYSTEM_TRUSTED, access)
        assertTrue(decision.accepted)
        assertStandardTransportCommands(commands)
        assertFalse(commands.playerCommandCodes.contains(Player.COMMAND_CHANGE_MEDIA_ITEMS))
        assertFalse(commands.playerCommandCodes.contains(Player.COMMAND_SEEK_TO_MEDIA_ITEM))
        assertFalse(commands.playerCommandCodes.contains(Player.COMMAND_SET_SPEED_AND_PITCH))
        assertFalse(commands.playerCommandCodes.contains(Player.COMMAND_SET_VOLUME))
        assertEquals(
            SessionResult.RESULT_ERROR_PERMISSION_DENIED,
            policy.rejectedCustomCommandResult(access)
        )
    }

    @Test
    fun `verified automotive and trusted legacy controllers use the media button profile`() {
        val automotive = policy.accessFor(
            identity(
                packageNameVerified = true,
                automotiveController = true
            )
        )
        val autoCompanion = policy.accessFor(
            identity(
                packageNameVerified = true,
                autoCompanionController = true
            )
        )
        val legacy = policy.accessFor(
            identity(
                trustedByMedia3 = true,
                legacyController = true
            )
        )

        assertEquals(ControllerAccessLevel.AUTOMOTIVE_OR_BLUETOOTH, automotive)
        assertEquals(ControllerAccessLevel.AUTOMOTIVE_OR_BLUETOOTH, autoCompanion)
        assertEquals(ControllerAccessLevel.AUTOMOTIVE_OR_BLUETOOTH, legacy)
        assertStandardTransportCommands(policy.commandsFor(automotive))
    }

    @Test
    fun `unverified automotive hint is not treated as authorization`() {
        val access = policy.accessFor(
            identity(
                packageNameVerified = false,
                trustedByMedia3 = false,
                automotiveController = true
            )
        )

        assertEquals(ControllerAccessLevel.UNKNOWN_EXTERNAL, access)
    }

    @Test
    fun `trusted auto controller without verified package uses trusted system classification`() {
        val access = policy.accessFor(
            identity(
                packageNameVerified = false,
                trustedByMedia3 = true,
                automotiveController = true
            )
        )

        assertEquals(ControllerAccessLevel.SYSTEM_TRUSTED, access)
    }

    @Test
    fun `unknown controller is rejected without receiving any commands`() {
        val decision = policy.connectionFor(identity())
        val access = decision.accessLevel
        val commands = decision.allowedCommands

        assertEquals(ControllerAccessLevel.UNKNOWN_EXTERNAL, access)
        assertFalse(decision.accepted)
        assertTrue(commands.playerCommandCodes.isEmpty())
        assertFalse(commands.useDefaultSessionCommands)
        assertEquals(
            SessionResult.RESULT_ERROR_PERMISSION_DENIED,
            policy.rejectedCustomCommandResult(access)
        )
    }

    @Test
    fun `missing trust signal fails closed unless controller is the media notification controller`() {
        val unknown = policy.connectionFor(identity(trustedByMedia3 = null))
        val notification = policy.connectionFor(
            identity(
                trustedByMedia3 = null,
                mediaNotificationController = true
            )
        )

        assertEquals(ControllerAccessLevel.UNKNOWN_EXTERNAL, unknown.accessLevel)
        assertFalse(unknown.accepted)
        assertEquals(ControllerAccessLevel.SYSTEM_TRUSTED, notification.accessLevel)
        assertTrue(notification.accepted)
    }

    private fun assertStandardTransportCommands(commands: AllowedMediaCommands) {
        assertEquals(expectedTransportCommands, commands.playerCommandCodes)
        assertTrue(commands.playerCommandCodes.contains(Player.COMMAND_PLAY_PAUSE))
        assertTrue(commands.playerCommandCodes.contains(Player.COMMAND_STOP))
        assertTrue(commands.playerCommandCodes.contains(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM))
        assertTrue(commands.playerCommandCodes.contains(Player.COMMAND_SEEK_TO_PREVIOUS))
        assertTrue(commands.playerCommandCodes.contains(Player.COMMAND_SEEK_TO_NEXT))
    }

    private fun identity(
        packageName: String = "external.app",
        uid: Int = 2000,
        packageNameVerified: Boolean = false,
        trustedByMedia3: Boolean? = false,
        mediaNotificationController: Boolean = false,
        automotiveController: Boolean = false,
        autoCompanionController: Boolean = false,
        legacyController: Boolean = false
    ) = ControllerIdentity(
        packageName = packageName,
        uid = uid,
        packageNameVerified = packageNameVerified,
        trustedByMedia3 = trustedByMedia3,
        mediaNotificationController = mediaNotificationController,
        automotiveController = automotiveController,
        autoCompanionController = autoCompanionController,
        legacyController = legacyController
    )

    @Suppress("DEPRECATION")
    private val expectedReadOnlyCommands = setOf(
        Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
        Player.COMMAND_GET_TIMELINE,
        Player.COMMAND_GET_MEDIA_ITEMS_METADATA,
        Player.COMMAND_GET_METADATA,
        Player.COMMAND_GET_AUDIO_ATTRIBUTES,
        Player.COMMAND_GET_VOLUME,
        Player.COMMAND_GET_DEVICE_VOLUME,
        Player.COMMAND_GET_TRACKS,
        Player.COMMAND_GET_TEXT
    )

    private val expectedTransportCommands = expectedReadOnlyCommands + setOf(
        Player.COMMAND_PREPARE,
        Player.COMMAND_PLAY_PAUSE,
        Player.COMMAND_STOP,
        Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
        Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
        Player.COMMAND_SEEK_BACK,
        Player.COMMAND_SEEK_FORWARD,
        Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
        Player.COMMAND_SEEK_TO_PREVIOUS,
        Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
        Player.COMMAND_SEEK_TO_NEXT
    )
}
