package com.nameless.audio.player.session

import androidx.media3.common.Player
import androidx.media3.session.SessionResult

internal data class ControllerIdentity(
    val packageName: String,
    val uid: Int,
    val packageNameVerified: Boolean,
    val trustedByMedia3: Boolean?,
    val mediaNotificationController: Boolean,
    val automotiveController: Boolean,
    val autoCompanionController: Boolean,
    val legacyController: Boolean
)

internal enum class ControllerAccessLevel {
    APP_SELF,
    SYSTEM_TRUSTED,
    AUTOMOTIVE_OR_BLUETOOTH,
    UNKNOWN_EXTERNAL
}

internal data class AllowedMediaCommands(
    val playerCommandCodes: Set<Int>,
    val allowAllPlayerCommands: Boolean = false,
    val useDefaultSessionCommands: Boolean = false
)

internal class NativeMediaControllerAccessPolicy(
    private val appPackageName: String,
    private val appUid: Int
) {
    fun accessFor(identity: ControllerIdentity): ControllerAccessLevel {
        if (identity.uid == appUid && identity.packageName == appPackageName) {
            return ControllerAccessLevel.APP_SELF
        }
        if (identity.mediaNotificationController) {
            return ControllerAccessLevel.SYSTEM_TRUSTED
        }
        val verifiedAutomotiveController =
            (identity.automotiveController || identity.autoCompanionController) &&
                identity.packageNameVerified
        val trustedLegacyController =
            identity.legacyController && identity.trustedByMedia3 == true
        if (verifiedAutomotiveController || trustedLegacyController) {
            return ControllerAccessLevel.AUTOMOTIVE_OR_BLUETOOTH
        }
        if (identity.trustedByMedia3 == true) {
            return ControllerAccessLevel.SYSTEM_TRUSTED
        }
        return ControllerAccessLevel.UNKNOWN_EXTERNAL
    }

    fun commandsFor(accessLevel: ControllerAccessLevel): AllowedMediaCommands {
        return when (accessLevel) {
            ControllerAccessLevel.APP_SELF -> AllowedMediaCommands(
                playerCommandCodes = emptySet(),
                allowAllPlayerCommands = true,
                useDefaultSessionCommands = true
            )
            ControllerAccessLevel.SYSTEM_TRUSTED,
            ControllerAccessLevel.AUTOMOTIVE_OR_BLUETOOTH -> AllowedMediaCommands(
                playerCommandCodes = standardTransportPlayerCommands
            )
            ControllerAccessLevel.UNKNOWN_EXTERNAL -> AllowedMediaCommands(
                playerCommandCodes = readOnlyPlayerCommands
            )
        }
    }

    fun rejectedCustomCommandResult(accessLevel: ControllerAccessLevel): Int {
        return if (accessLevel == ControllerAccessLevel.APP_SELF) {
            SessionResult.RESULT_ERROR_NOT_SUPPORTED
        } else {
            SessionResult.RESULT_ERROR_PERMISSION_DENIED
        }
    }
}

@Suppress("DEPRECATION")
private val readOnlyPlayerCommands = setOf(
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

private val standardTransportPlayerCommands = readOnlyPlayerCommands + setOf(
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
