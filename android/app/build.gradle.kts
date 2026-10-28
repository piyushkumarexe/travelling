import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after Android and Kotlin.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

val flutterVersionCode: Int =
    localProperties.getProperty("flutter.versionCode")?.toIntOrNull() ?: 1
val flutterVersionName: String =
    localProperties.getProperty("flutter.versionName") ?: "1.0.0"

// Release signing is opt-in and complete, or release packaging fails. Debug
// builds need none of these values. Secret values come only from a local
// gitignored properties file or protected CI environment variables.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties()
if (keystorePropsFile.exists()) {
    keystorePropsFile.inputStream().use { keystoreProps.load(it) }
}
fun signingValue(environmentName: String, propertyName: String): String? =
    System.getenv(environmentName)?.takeIf { it.isNotBlank() }
        ?: keystoreProps.getProperty(propertyName)?.takeIf { it.isNotBlank() }

val uploadStorePath = signingValue("ANDROID_KEYSTORE_FILE", "storeFile")
val uploadStorePassword =
    signingValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val uploadKeyAlias = signingValue("ANDROID_KEY_ALIAS", "keyAlias")
val uploadKeyPassword = signingValue("ANDROID_KEY_PASSWORD", "keyPassword")
val hasReleaseSigning = uploadStorePath != null &&
    project.file(uploadStorePath).isFile &&
    uploadStorePassword != null && uploadKeyAlias != null &&
    uploadKeyPassword != null

android {
    namespace = "app.roamio.tourism"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_1_8.toString()
    }

    defaultConfig {
        // Compatibility-sensitive package/application ID: do not rename.
        applicationId = "app.roamio.tourism"
        minSdk = 23
        targetSdk = 36
        versionCode = flutterVersionCode
        versionName = flutterVersionName
        manifestPlaceholders["MAPS_API_KEY"] =
            System.getenv("MAPS_ANDROID_API_KEY")
                ?: "REPLACE_WITH_GOOGLE_MAPS_ANDROID_API_KEY"
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = project.file(uploadStorePath!!)
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
                if (uploadStorePath!!.lowercase().let {
                    it.endsWith(".p12") || it.endsWith(".pfx")
                }) {
                    storeType = "PKCS12"
                }
                // API 23 needs v1; modern Android uses v2 as well.
                isV1SigningEnabled = true
                isV2SigningEnabled = true
            }
        }
    }

    buildTypes {
        release {
            // NEVER silently substitute the debug certificate. With no full
            // signing configuration this stays unsigned and packageRelease
            // fails below with an actionable error.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

// AGP creates release packaging tasks after this script is evaluated.
tasks.configureEach {
    if (name == "packageRelease" || name == "bundleRelease") {
        doFirst {
            if (!hasReleaseSigning) {
                throw GradleException(
                    "Refusing an unsigned/debug-signed release. Set " +
                        "ANDROID_KEYSTORE_FILE, ANDROID_KEYSTORE_PASSWORD, " +
                        "ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD (or the " +
                        "equivalent gitignored keystore.properties values)."
                )
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
