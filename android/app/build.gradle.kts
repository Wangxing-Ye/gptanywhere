plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.local.gptanywhere"
    // Pinned from Flutter 3.41.6 on 2026-11-02.
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Local id only. Not the store applicationId.
        applicationId = "dev.local.gptanywhere"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

val bundleLlamaCli = tasks.register("bundleLlamaCli") {
    val source = file("../../third_party/llama.cpp/build-android/bin/llama-cli")
    val dest = file("src/main/jniLibs/arm64-v8a/libllama_cli.so")
    onlyIf {
        source.exists() && (!dest.exists() || source.lastModified() > dest.lastModified())
    }
    doLast {
        dest.parentFile.mkdirs()
        source.copyTo(dest, overwrite = true)
    }
}

val bundleAsrBins = tasks.register("bundleAsrBins") {
    val dir = file("src/main/jniLibs/arm64-v8a")
    val sherpa = file("../../third_party/sherpa-onnx/build-android-api24/bin/sherpa-onnx-offline")
    val whisper = file("../../third_party/whisper.cpp/build-android/bin/whisper-cli")
    doLast {
        dir.mkdirs()
        sherpa.copyIfNewer(dir.resolve("libsherpa_offline.so"))
        whisper.copyIfNewer(dir.resolve("libwhisper_cli.so"))
    }
}

fun File.copyIfNewer(dest: File) {
    if (!exists()) return
    if (dest.exists() && dest.length() == length() && dest.lastModified() >= lastModified()) {
        return
    }
    dest.parentFile.mkdirs()
    copyTo(dest, overwrite = true)
}

tasks.configureEach {
    if (name == "preBuild") {
        dependsOn(bundleLlamaCli)
        dependsOn(bundleAsrBins)
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Bundled OCR models. Latin ships inside the plugin.
    // Do not switch these to the Play-services downloader.
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
    implementation("org.apache.commons:commons-compress:1.27.1")
}
