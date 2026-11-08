plugins {
    id("com.android.application")
    // Firebase: must come after the Android plugin. Reads
    // android/app/google-services.json (package "com.materiallab").
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.FileInputStream
import java.util.Properties

android {
    // Must match the Firebase console Android app (google-services.json
    // "package_name"); the google-services plugin rejects any other
    // applicationId at build time.
    namespace = "com.materiallab"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by ':flutter_local_notifications' (checks AAR metadata at
        // :app:checkDebugAarMetadata). Without this the build fails with:
        // "Dependency ':flutter_local_notifications' requires core library
        //  desugaring to be enabled for :app."
        isCoreLibraryDesugaringEnabled = true
    }

    // Machine-local signing credentials are ignored by Git. Retain the old
    // external path for installations that already use it.
    val localKeystorePropsFile = rootProject.file("key.properties")
    val keystorePropsFile = if (localKeystorePropsFile.exists())
        localKeystorePropsFile else file("F:/material lab/key.properties")
    val keystoreProps = Properties()
    if (keystorePropsFile.exists()) {
        FileInputStream(keystorePropsFile).use { keystoreProps.load(it) }
    }
    val signingReady = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .all { !keystoreProps.getProperty(it).isNullOrEmpty() }
    val releaseRequested = gradle.startParameter.taskNames.any {
        it.contains("release", ignoreCase = true)
    }
    if (releaseRequested && !signingReady) {
        throw GradleException("Release signing is not configured. Create android/key.properties; debug signing is never used for release.")
    }

    signingConfigs {
        if (signingReady) {
            create("upload") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = "com.materiallab"
        // Firebase Auth / Play-services libraries require API 23+.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // A release must use the configured production identity.
            signingConfig = signingConfigs.findByName("upload")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Pairs with compileOptions.isCoreLibraryDesugaringEnabled above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
