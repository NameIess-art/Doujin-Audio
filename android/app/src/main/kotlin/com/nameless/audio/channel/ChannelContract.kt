package com.nameless.audio.channel

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

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

internal class ChannelEnvelopeResult(
    private val delegate: MethodChannel.Result
) : MethodChannel.Result {
    override fun success(result: Any?) {
        delegate.success(channelSuccess(result))
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        delegate.success(
            channelFailure(
                code = errorCode.ifBlank { ChannelErrorCodes.PLATFORM_ERROR },
                message = errorMessage ?: "Platform operation failed",
                details = errorDetails
            )
        )
    }

    override fun notImplemented() {
        delegate.notImplemented()
    }
}

internal fun MethodCall.argumentsMap(): Map<String, Any?> {
    val rawArguments = arguments as? Map<*, *> ?: return emptyMap()
    return buildMap {
        rawArguments.forEach { (key, value) ->
            if (key is String) put(key, value)
        }
    }
}

internal class ChannelArgumentReader(call: MethodCall) {
    private val arguments = call.argumentsMap()

    fun hasKey(key: String): Boolean = arguments.containsKey(key)

    fun requiredString(key: String, allowBlank: Boolean = false): String {
        val value = arguments[key] as? String
        require(value != null && (allowBlank || value.isNotBlank())) {
            "Missing or invalid string argument: $key"
        }
        return if (allowBlank) value else value.trim()
    }

    fun optionalString(key: String): String? {
        val value = arguments[key] ?: return null
        require(value is String) { "Invalid string argument: $key" }
        return value
    }

    fun requiredNullableString(key: String): String? {
        require(arguments.containsKey(key)) { "Missing argument: $key" }
        val value = arguments[key] ?: return null
        require(value is String) { "Invalid string argument: $key" }
        return value
    }

    fun requiredInt(key: String): Int {
        val value = requiredIntegralNumber(key)
        val converted = value.toLong()
        require(converted in Int.MIN_VALUE..Int.MAX_VALUE) {
            "Numeric argument is outside the integer range: $key"
        }
        return converted.toInt()
    }

    fun requiredLong(key: String): Long = requiredIntegralNumber(key).toLong()

    fun requiredIntInRange(key: String, range: IntRange): Int {
        val value = requiredInt(key)
        require(value in range) { "Numeric argument is outside the allowed range: $key" }
        return value
    }

    fun requiredNullableInt(key: String, range: IntRange? = null): Int? {
        require(arguments.containsKey(key)) { "Missing argument: $key" }
        if (arguments[key] == null) return null
        val value = requiredInt(key)
        require(range == null || value in range) {
            "Numeric argument is outside the allowed range: $key"
        }
        return value
    }

    fun requiredNullableLong(key: String, minimum: Long? = null): Long? {
        require(arguments.containsKey(key)) { "Missing argument: $key" }
        val value = optionalLong(key) ?: return null
        require(minimum == null || value >= minimum) {
            "Numeric argument is outside the allowed range: $key"
        }
        return value
    }

    fun optionalLong(key: String): Long? {
        val value = arguments[key] ?: return null
        require(value is Number) { "Invalid numeric argument: $key" }
        if (value is Float || value is Double) {
            val doubleValue = value.toDouble()
            require(doubleValue.isFinite() && doubleValue % 1.0 == 0.0) {
                "Numeric argument must be an integer: $key"
            }
            require(doubleValue >= Long.MIN_VALUE.toDouble() && doubleValue < Long.MAX_VALUE.toDouble()) {
                "Numeric argument is outside the long range: $key"
            }
        }
        return value.toLong()
    }

    fun requiredDouble(key: String): Double {
        val value = requiredNumber(key).toDouble()
        require(value.isFinite()) { "Numeric argument must be finite: $key" }
        return value
    }

    fun requiredNullableDouble(
        key: String,
        range: ClosedRange<Double>? = null
    ): Double? {
        require(arguments.containsKey(key)) { "Missing argument: $key" }
        if (arguments[key] == null) return null
        val value = requiredDouble(key)
        require(range == null || value in range) {
            "Numeric argument is outside the allowed range: $key"
        }
        return value
    }

    fun requiredBoolean(key: String): Boolean {
        val value = arguments[key]
        require(value is Boolean) { "Missing or invalid boolean argument: $key" }
        return value
    }

    fun optionalBoolean(key: String, defaultValue: Boolean): Boolean {
        val value = arguments[key] ?: return defaultValue
        require(value is Boolean) { "Invalid boolean argument: $key" }
        return value
    }

    fun requiredByteArray(key: String): ByteArray {
        val value = arguments[key]
        require(value is ByteArray) { "Missing or invalid byte array argument: $key" }
        return value
    }

    fun requiredList(key: String): List<*> {
        val value = arguments[key]
        require(value is List<*>) { "Missing or invalid list argument: $key" }
        return value
    }

    fun requiredStringList(key: String, allowBlank: Boolean = false): List<String> {
        return requiredList(key).mapIndexed { index, value ->
            require(value is String && (allowBlank || value.isNotBlank())) {
                "Invalid string list item at $key[$index]"
            }
            if (allowBlank) value else value.trim()
        }
    }

    fun requiredMap(key: String): Map<*, *> {
        val value = arguments[key]
        require(value is Map<*, *>) { "Missing or invalid map argument: $key" }
        return value
    }

    private fun requiredNumber(key: String): Number {
        val value = arguments[key]
        require(value is Number) { "Missing or invalid numeric argument: $key" }
        return value
    }

    private fun requiredIntegralNumber(key: String): Number {
        val value = requiredNumber(key)
        if (value is Float || value is Double) {
            val doubleValue = value.toDouble()
            require(doubleValue.isFinite() && doubleValue % 1.0 == 0.0) {
                "Numeric argument must be an integer: $key"
            }
            require(
                doubleValue >= Long.MIN_VALUE.toDouble() &&
                    doubleValue < Long.MAX_VALUE.toDouble()
            ) { "Numeric argument is outside the long range: $key" }
        }
        return value
    }
}

internal fun MethodCall.argumentReader(): ChannelArgumentReader =
    ChannelArgumentReader(this)

internal fun MethodCall.requiredString(key: String): String {
    return argumentReader().requiredString(key)
}

internal fun MethodCall.requiredLong(key: String): Long {
    return argumentReader().requiredLong(key)
}

internal fun MethodCall.requiredDouble(key: String): Double {
    return argumentReader().requiredDouble(key)
}
