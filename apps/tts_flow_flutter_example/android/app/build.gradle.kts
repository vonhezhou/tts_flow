import java.io.FileInputStream
import java.util.Properties

val releaseSigningProperties = Properties()
val releaseSigningPropertiesFile = rootProject.file("key.properties")

if (releaseSigningPropertiesFile.exists()) {
    releaseSigningProperties.load(FileInputStream(releaseSigningPropertiesFile))
}

fun requiredReleaseSigningProperty(name: String): String =
    releaseSigningProperties.getProperty(name)
        ?: error("Missing $name in android/key.properties.")

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.github.vonhezhou.tts_flow_flutter_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.github.vonhezhou.tts_flow_flutter_example"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningPropertiesFile.exists()) {
            create("release") {
                keyAlias = requiredReleaseSigningProperty("keyAlias")
                keyPassword = requiredReleaseSigningProperty("keyPassword")
                storeFile = file(requiredReleaseSigningProperty("storeFile"))
                storePassword = requiredReleaseSigningProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // This is a runnable demonstration app. Do not distribute an APK
            // signed with the fallback debug key; see android/key.properties.example.
            signingConfig = if (releaseSigningPropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
