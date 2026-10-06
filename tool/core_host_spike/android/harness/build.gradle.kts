// #15: the race-timer stand-in. Debug-only and never shipped: link_build.sh signs the
// one APK this builds twice, with a "trusted" key the companion pins and an "imposter"
// key it does not, so both copies carry the same package and differ only in signer.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.procompanion.link_harness"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.procompanion.link_harness"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
