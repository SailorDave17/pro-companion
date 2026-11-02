// #15: the race-timer stand-in. Debug-only and never shipped: link_build.sh signs the
// one APK this builds twice, with a "trusted" key the companion pins and an "imposter"
// key it does not, so both copies carry the same package and differ only in signer.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// #33: the same stand-in drives the real app under race-timer's package, which is the only
// package the app pins, so its identity is a property. Unset, this is the spike's harness. The
// namespace stays, so the service's class name does not move with the package: start it by
// its full name, <package>/com.procompanion.link_harness.EmitService.
val harnessPackage = providers.gradleProperty("linkHarnessPackage")
    .getOrElse("com.procompanion.link_harness")
val companionPackage = providers.gradleProperty("linkHarnessCompanion")
    .getOrElse("com.procompanion.core_host_spike")

android {
    namespace = "com.procompanion.link_harness"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = harnessPackage
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        manifestPlaceholders["companionPackage"] = companionPackage
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
