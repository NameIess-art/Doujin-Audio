pluginManagement {
    val flutterSdkPath = run {
        val localPropertiesFile = file("local.properties")
        val fromEnv = System.getenv("FLUTTER_ROOT")?.takeIf { it.isNotBlank() }
        if (localPropertiesFile.exists()) {
            val properties = java.util.Properties()
            localPropertiesFile.inputStream().use { properties.load(it) }
            val fromLocal = properties.getProperty("flutter.sdk")?.takeIf { it.isNotBlank() }
            fromLocal ?: fromEnv
        } else {
            fromEnv
        }
    }
    require(flutterSdkPath != null) {
        "Flutter SDK path not found. Set flutter.sdk in android/local.properties or FLUTTER_ROOT environment variable."
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("com.android.library") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
