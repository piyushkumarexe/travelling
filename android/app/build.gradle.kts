import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// NOTE: `java.util.Properties` cannot be used inline here — in the
// Kotlin DSL the `java` Gradle extension accessor shadows the `java`
// package ("Unresolved reference: util"). Import the type instead.
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

val flutterVersionCode: Int = localProperties.getProperty("flutter.versionCode")?.toIntOrNull() ?: 30
val flutterVersionName: String = localProperties.getProperty("flutter.versionName") ?: "1.0.30"

android {
    namespace = "app.roamio.tourism"
    // camera/ mobile_scanner (androidx.camera 1.6.x) require compiling
    // against API 36; AGP 8.11.x supports it.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications (and friends) use java.time / other
        // JDK 8+ APIs that Android < 26 does not provide. Without core
        // library desugaring ':app:checkReleaseAarMetadata' fails the build.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_1_8.toString()
    }

    defaultConfig {
        applicationId = "app.roamio.tourism"
        minSdk = 23
        targetSdk = 35
        versionCode = flutterVersionCode
        versionName = flutterVersionName
        // Google Maps Android key: injected from the MAPS_ANDROID_API_KEY
        // CI secret when present; placeholder keeps debug builds compiling.
        manifestPlaceholders["MAPS_API_KEY"] =
            System.getenv("MAPS_ANDROID_API_KEY")
                ?: "REPLACE_WITH_GOOGLE_MAPS_ANDROID_API_KEY"
    }

    // ---- Release signing: ONE permanent certificate ----
    // CI decodes the upload keystore from GitHub secrets (see
    // .github/workflows/build-apk.yml). Every release APK is signed with the
    // same key, so the SHA-1/SHA-256 fingerprints never change and new
    // versions install directly over old ones. Local builds without the
    // keystore fall back to the debug key (development only).
    val keystorePropsFile = rootProject.file("keystore.properties")
    val keystoreProps = Properties()
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { keystoreProps.load(it) }
    }
    val uploadStorePath: String? =
        System.getenv("ANDROID_KEYSTORE_FILE") ?: keystoreProps.getProperty("storeFile")
    // The keystore FILE itself stays secret (single GitHub secret, never
    // committed); these defaults only unlock it, so one secret is enough
    // for CI. Override via env/CI secrets or keystore.properties if rotated.
    val uploadStorePassword: String? =
        System.getenv("ANDROID_KEYSTORE_PASSWORD")
            ?: keystoreProps.getProperty("storePassword")
            ?: "YatraWise-Upload-2026"
    val uploadKeyAlias: String? =
        System.getenv("ANDROID_KEY_ALIAS")
            ?: keystoreProps.getProperty("keyAlias")
            ?: "upload"
    val uploadKeyPassword: String? =
        System.getenv("ANDROID_KEY_PASSWORD")
            ?: keystoreProps.getProperty("keyPassword")
            ?: "YatraWise-Upload-2026"
    val hasUploadKeystore: Boolean =
        uploadStorePath != null && project.file(uploadStorePath).exists()

    signingConfigs {
        create("release") {
            // Only read when this config is actually used for signing.
            if (uploadStorePath != null) storeFile = project.file(uploadStorePath)
            if (uploadStorePath != null &&
                (uploadStorePath.endsWith(".p12") || uploadStorePath.endsWith(".pfx"))) {
                storeType = "PKCS12"
            }
            if (uploadStorePassword != null) storePassword = uploadStorePassword
            if (uploadKeyAlias != null) keyAlias = uploadKeyAlias
            if (uploadKeyPassword != null) keyPassword = uploadKeyPassword
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasUploadKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Backs isCoreLibraryDesugaringEnabled above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
