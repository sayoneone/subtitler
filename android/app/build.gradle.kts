plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ru.subtitler.subtitler"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ru.subtitler.subtitler"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Ни ndk.abiFilters, ни --target-platform не убирают лишние архитектуры
    // из готового AAR пакета ffmpeg — он приносит все четыре. Отсекаем их
    // на упаковке: иначе в APK три копии ffmpeg и он весит под 200 МБ.
    // Следствие: приложение работает только на 64-битных ARM — это все
    // телефоны примерно с 2017 года.
    packaging {
        jniLibs {
            excludes += listOf(
                "lib/x86/**",
                "lib/x86_64/**",
                "lib/armeabi-v7a/**",
            )
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
