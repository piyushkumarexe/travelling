plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = java.util.Properties()
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

    // ---- Release signing: ONE permanent certificate ----
    // CI decodes the upload keystore from GitHub secrets (see
    // .github/workflows/build-apk.yml). Every release APK is signed with the
    // same key, so the SHA-1/SHA-256 fingerprints never change and new
    // versions install directly over old ones. Local builds without the
    // keystore fall back to the debug key (development only).
    val keystorePropsFile = rootProject.file("keystore.properties")
    val keystoreProps = java.util.Properties()
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { keystoreProps.load(it) }
    }
    val uploadStorePath: String? =
        System.getenv("ANDROID_KEYSTORE_FILE") ?: keystoreProps.getProperty("storeFile")
    val uploadStorePassword: String? =
        System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: keystoreProps.getProperty("storePassword")
    val uploadKeyAlias: String? =
        System.getenv("ANDROID_KEY_ALIAS") ?: keystoreProps.getProperty("keyAlias")
    val uploadKeyPassword: String? =
        System.getenv("ANDROID_KEY_PASSWORD") ?: keystoreProps.getProperty("keyPassword")
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
