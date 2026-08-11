import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: loaded from android/key.properties (git-ignored) when it
// exists. Without it, the app falls back to the debug key (dev + the current
// in-place Shorebird update line). See key.properties.example.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.dopcollect.dop_collect"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dopcollect.dop_collect"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                // storeFile is resolved relative to android/ (rootProject).
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the upload key for Play once key.properties exists; otherwise
            // the debug key (keeps the current in-place Shorebird update line
            // working). SECURITY (SECURITY_AUDIT.md S3): a release APK signed
            // with the debug key can be stripped, trojanised and re-signed by
            // anyone (the debug keystore is identical on every machine). This
            // MUST NOT happen for a Play Store build — so warn loudly here, and
            // hard-fail when an official release is requested via
            //   ./gradlew ... -PrequireReleaseSigning=true
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                if (project.hasProperty("requireReleaseSigning")) {
                    throw GradleException(
                        "android/key.properties is required for a release build. " +
                        "Create the upload keystore before publishing to Play."
                    )
                }
                logger.warn(
                    "\n*** WARNING: release build is DEBUG-SIGNED (no android/key.properties). " +
                    "Fine for local/Shorebird testing, but DO NOT publish this APK to the " +
                    "Play Store. Generate the upload keystore and build with " +
                    "-PrequireReleaseSigning=true for production. ***\n"
                )
                signingConfigs.getByName("debug")
            }
            // Disable R8/shrinking: ML Kit references optional non-Latin text
            // recognizers we don't bundle, which trips R8's missing-class check.
            // We only use Latin OCR, so no shrinking is the simplest safe fix.
            isMinifyEnabled = false
            isShrinkResources = false
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
