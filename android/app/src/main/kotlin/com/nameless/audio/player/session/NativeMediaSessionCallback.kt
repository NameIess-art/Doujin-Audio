package com.nameless.audio.player.session

import android.os.Bundle
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionCommands
import androidx.media3.session.SessionResult
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

@UnstableApi
internal class NativeMediaSessionCallback(
    appPackageName: String,
    appUid: Int,
    private val logSecurityEvent: (String, Throwable?) -> Unit
) : MediaSession.Callback {
    private val accessPolicy = NativeMediaControllerAccessPolicy(
        appPackageName = appPackageName,
        appUid = appUid
    )

    override fun onConnect(
        session: MediaSession,
        controller: MediaSession.ControllerInfo
    ): MediaSession.ConnectionResult {
        val identity = identityFor(session, controller)
        val accessLevel = accessPolicy.accessFor(identity)
        val allowedCommands = accessPolicy.commandsFor(accessLevel)
        return MediaSession.ConnectionResult.accept(
            if (allowedCommands.useDefaultSessionCommands) {
                MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS
            } else {
                SessionCommands.EMPTY
            },
            allowedCommands.toPlayerCommands()
        )
    }

    override fun onCustomCommand(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
        customCommand: SessionCommand,
        args: Bundle
    ): ListenableFuture<SessionResult> {
        val accessLevel = accessPolicy.accessFor(identityFor(session, controller))
        val resultCode = accessPolicy.rejectedCustomCommandResult(accessLevel)
        logSecurityEvent(
            "media_custom_command_rejected access=$accessLevel reason=not_advertised",
            null
        )
        return Futures.immediateFuture(SessionResult(resultCode))
    }

    private fun identityFor(
        session: MediaSession,
        controller: MediaSession.ControllerInfo
    ): ControllerIdentity {
        val trustedByMedia3 = try {
            controller.isTrusted
        } catch (error: RuntimeException) {
            logSecurityEvent("media_controller_trust_unavailable", error)
            null
        }
        return ControllerIdentity(
            packageName = controller.packageName,
            uid = controller.uid,
            packageNameVerified = controller.isPackageNameVerified,
            trustedByMedia3 = trustedByMedia3,
            mediaNotificationController = session.isMediaNotificationController(controller),
            automotiveController = session.isAutomotiveController(controller),
            autoCompanionController = session.isAutoCompanionController(controller),
            legacyController =
                controller.controllerVersion == MediaSession.ControllerInfo.LEGACY_CONTROLLER_VERSION ||
                    controller.interfaceVersion ==
                    MediaSession.ControllerInfo.LEGACY_CONTROLLER_INTERFACE_VERSION
        )
    }
}

private fun AllowedMediaCommands.toPlayerCommands(): Player.Commands {
    val builder = Player.Commands.Builder()
    if (allowAllPlayerCommands) {
        builder.addAllCommands()
    } else {
        playerCommandCodes.forEach(builder::add)
    }
    return builder.build()
}
