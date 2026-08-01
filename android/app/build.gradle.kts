plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val requiredReleaseSigningProperties = listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
)

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

val releaseKeystoreFile = (keystoreProperties["storeFile"] as String?)?.let(rootProject::file)
val generatedPluginRegistrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
val integrationTestRegistrantBlock = Regex(
    """(?s)\s+try \{\s+flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\s+\} catch \(Exception e\) \{\s+Log\.e\(TAG, "Error registering plugin integration_test,[^"]+", e\);\s+\}""",
)
val releaseSigningConfigured = keystorePropertiesFile.exists() &&
    requiredReleaseSigningProperties.all { !keystoreProperties.getProperty(it).isNullOrBlank() } &&
    releaseKeystoreFile?.isFile == true

val validateReleaseSigning by tasks.registering {
    group = "verification"
    description = "Fails if a complete release signing configuration is not available."
    doLast {
        if (!keystorePropertiesFile.exists()) {
            throw GradleException(
                "Release signing requires android/key.properties. " +
                    "Debug signing is never allowed for release builds. " +
                    "For local deployment, run tool/setup_local_release_signing.ps1.",
            )
        }
        requiredReleaseSigningProperties.forEach { property ->
            if (keystoreProperties.getProperty(property).isNullOrBlank()) {
                throw GradleException("Release signing property '$property' is missing from android/key.properties.")
            }
        }
        if (releaseKeystoreFile?.isFile != true) {
            throw GradleException("Release keystore does not exist: ${releaseKeystoreFile?.path ?: "<missing storeFile>"}")
        }
    }
}

android {
    namespace = "com.nameless.audio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.nameless.audio"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    lint {
        abortOnError = true
        // local.properties contains machine-local Windows paths and is not a
        // shipped resource; Windows path escaping varies by Flutter tooling.
        disable += "PropertyEscape"
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = releaseKeystoreFile
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    buildTypes {
        debug {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        release {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
        }
    }
}

tasks.configureEach {
    if (name == "compileReleaseJavaWithJavac") {
        // A prior integration-test/debug build can leave a dev-only plugin in
        // this ignored generated file. It must never enter a release compile.
        doFirst {
            if (generatedPluginRegistrant.isFile) {
                generatedPluginRegistrant.writeText(
                    integrationTestRegistrantBlock.replace(
                        generatedPluginRegistrant.readText(),
                        "",
                    ),
                )
            }
        }
    }
    if (
        name == "compileFlutterBuildRelease" ||
        (
            name.endsWith("Release") &&
            (name.startsWith("assemble") || name.startsWith("bundle") || name.startsWith("package"))
        )
    ) {
        dependsOn(validateReleaseSigning)
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.media:media:1.8.0")
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-session:1.10.1")
    implementation("androidx.media3:media3-ui:1.10.1")
    testImplementation("junit:junit:4.13.2")
}
