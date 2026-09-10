plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localPropertiesFile = rootProject.file("local.properties")
val localProperties: Map<String, String> = if (localPropertiesFile.exists()) {
    localPropertiesFile.readLines().mapNotNull { line ->
        val separator = line.indexOf('=')
        if (separator <= 0) null
        else line.substring(0, separator).trim() to
            line.substring(separator + 1).trim()
    }.toMap()
} else {
    emptyMap()
}

val flutterVersionCode: Int = localProperties["flutter.versionCode"]?.toIntOrNull() ?: 1
val flutterVersionName: String = localProperties["flutter.versionName"] ?: "1.0.0"

// Production signing values belong in android/key.properties. The keystore and
// this properties file are gitignored; CI creates them from encrypted secrets.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties: Map<String, String> = if (keyPropertiesFile.exists()) {
    keyPropertiesFile.readLines().mapNotNull { line ->
        val separator = line.indexOf('=')
        if (separator <= 0) null
        else line.substring(0, separator).trim() to
            line.substring(separator + 1).trim()
    }.toMap()
} else {
    emptyMap()
}
val releaseStoreFile = keyProperties["storeFile"]?.let { rootProject.file(it) }
val hasReleaseSigning = releaseStoreFile?.exists() == true &&
    !keyProperties["storePassword"].isNullOrEmpty() &&
    !keyProperties["keyAlias"].isNullOrEmpty() &&
    !keyProperties["keyPassword"].isNullOrEmpty()

android {
    namespace = "app.roamio.tourism"
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

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = keyProperties["storePassword"]
                keyAlias = keyProperties["keyAlias"]
                keyPassword = keyProperties["keyPassword"]
                storeType = keyProperties["storeType"] ?: "JKS"
            }
        }
    }

    defaultConfig {
        applicationId = "app.roamio.tourism"
        minSdk = 23
        targetSdk = 35
        versionCode = flutterVersionCode
        versionName = flutterVersionName
    }

    buildTypes {
        release {
            // A permanent key enables in-place upgrades and stable Firebase
            // OAuth fingerprints. Debug signing remains a CI fallback only.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

// Print the public signing-certificate fingerprints in CI. This makes it
// possible to register the exact certificate used by an installable APK in
// Firebase without exposing any private signing material.
val printReleaseSigningCertificate =
    tasks.register<Exec>("printReleaseSigningCertificate") {
        val signing = android.signingConfigs.getByName(
            if (hasReleaseSigning) "release" else "debug",
        )
        commandLine(
            "${System.getProperty("java.home")}/bin/keytool",
            "-list",
            "-v",
            "-keystore",
            signing.storeFile!!.absolutePath,
            "-storepass",
            signing.storePassword!!,
            "-alias",
            signing.keyAlias!!,
        )
    }

tasks.matching { it.name == "assembleRelease" }.configureEach {
    finalizedBy(printReleaseSigningCertificate)
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
