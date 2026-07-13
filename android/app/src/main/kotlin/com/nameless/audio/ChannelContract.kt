package com.nameless.audio

import io.flutter.plugin.common.MethodCall

internal object ChannelErrorCodes {
    const val INVALID_ARGUMENT = "invalid_argument"
    const val SERVICE_UNAVAILABLE = "service_unavailable"
    const val PLAYER_ERROR = "player_error"
    const val PLATFORM_ERROR = "platform_error"
    const val UNEXPECTED = "unexpected"
}

internal fun channelSuccess(value: Any?): Map<String, Any?> = mapOf(
    "ok" to true,
    "value" to value
)

internal fun channelFailure(
    code: String,
    message: String,
    details: Any? = null
): Map<String, Any?> = mapOf(
    "ok" to false,
    "errorCode" to code,
    "error" to message,
    "details" to details
)

internal fun MethodCall.argumentsMap(): Map<String, Any?> {
    val rawArguments = arguments as? Map<*, *> ?: return emptyMap()
    return buildMap {
        rawArguments.forEach { (key, value) ->
            if (key is String) put(key, value)
        }
    }
}

internal fun MethodCall.requiredString(key: String): String {
    val value = argument<String>(key)?.trim()
    require(!value.isNullOrEmpty()) { "Missing required argument: $key" }
    return value
}

internal fun MethodCall.requiredLong(key: String): Long {
    val value = argument<Any>(key)
    require(value is Number) { "Missing or invalid numeric argument: $key" }
    return value.toLong()
}

internal fun MethodCall.requiredDouble(key: String): Double {
    val value = argument<Any>(key)
    require(value is Number) { "Missing or invalid numeric argument: $key" }
    return value.toDouble()
}
