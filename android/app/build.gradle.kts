import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

val flutterVersionCode: Int = localProperties.getProperty("flutter.versionCode")?.toIntOrNull() ?: 1
val flutterVersionName: String = localProperties.getProperty("flutter.versionName") ?: "1.0.0"

android {
    namespace = "com.roamio.app"
    compileSdk = 35
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications on Android. Several java.time
        // APIs used by the plugin are backported to devices below API 26.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_1_8.toString()
    }

    defaultConfig {
        applicationId = "com.roamio.app"
        minSdk = 23
        targetSdk = 35
        versionCode = flutterVersionCode
        versionName = flutterVersionName
    }

    buildTypes {
        release {
            // Release builds are signed with the debug keystore by default so that
            // CI can produce an installable APK without a committed keystore.
            // Configure your own upload keystore (see README > "Release signing")
            // before publishing to any store.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
