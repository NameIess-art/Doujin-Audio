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
val releaseSigningConfigured = keystorePropertiesFile.exists() &&
    requiredReleaseSigningProperties.all { !keystoreProperties.getProperty(it).isNullOrBlank() } &&
    releaseKeystoreFile?.isFile == true

val validateReleaseSigning by tasks.registering {
    group = "verification"
    description = "Fails release builds unless a complete release signing configuration is available."
    doLast {
        check(keystorePropertiesFile.exists()) {
            "Release signing requires android/key.properties."
        }
        requiredReleaseSigningProperties.forEach { property ->
            check(!keystoreProperties.getProperty(property).isNullOrBlank()) {
                "Release signing property '$property' is missing from android/key.properties."
            }
        }
        check(releaseKeystoreFile?.isFile == true) {
            "Release keystore does not exist: ${releaseKeystoreFile?.path ?: "<missing storeFile>"}"
        }
    }
}

android {
    namespace = "com.nameless.audio"
    compileSdk = flutter.compileSdkVersion

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
    implementation("androidx.documentfile:documentfile:1.0.1")
    implementation("androidx.media:media:1.7.0")
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-session:1.10.1")
    testImplementation("junit:junit:4.13.2")
}
