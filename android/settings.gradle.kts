pluginManagement {
    val flutterSdkPath = run {
        // Avoid java.util.Properties here: Gradle's Kotlin DSL exposes a
        // `java` extension which can shadow the Java package in CI.
        val flutterSdkPath = file("local.properties")
            .readLines()
            .firstOrNull { it.startsWith("flutter.sdk=") }
            ?.substringAfter('=')
            ?.trim()
        require(!flutterSdkPath.isNullOrEmpty()) {
            "flutter.sdk not set in local.properties"
        }
        flutterSdkPath
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
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}

include(":app")
