import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (#23, groom decision G20). A release build signs with the owner's upload key and
// never with the debug keys. Each of the four values is read from its environment variable first,
// then from an untracked android/key.properties; a relative storeFile resolves against android/.
// With any value missing, or a keystore that is not there, a release build stops at
// checkReleaseSigning naming what is missing. A debug build needs none of it, but key.properties is
// read when Gradle configures any build, so a malformed one fails debug builds too. A backslash is
// an escape there: "...\keys\upload.jks" fails on "\u" (Malformed \uxxxx encoding), and any other
// backslash vanishes silently. Write paths with forward slashes.
// docs/field-builds.md is the owner's guide, and scripts/check_release_signing.sh the proof.
val releaseSigningSources = linkedMapOf(
    "storeFile" to "PRO_COMPANION_KEYSTORE",
    "storePassword" to "PRO_COMPANION_KEYSTORE_PASSWORD",
    "keyAlias" to "PRO_COMPANION_KEY_ALIAS",
    "keyPassword" to "PRO_COMPANION_KEY_PASSWORD",
)
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties().apply {
    if (keyPropertiesFile.isFile) keyPropertiesFile.inputStream().use { load(it) }
}
val releaseSigning: Map<String, String?> = releaseSigningSources.mapValues { (property, variable) ->
    providers.environmentVariable(variable).orNull?.takeIf { it.isNotBlank() }
        ?: keyProperties.getProperty(property)?.takeIf { it.isNotBlank() }
}
val releaseKeystore = releaseSigning["storeFile"]?.let { rootProject.file(it) }
val releaseSigningProblems: List<String> = buildList {
    releaseSigning.filterValues { it == null }.keys.forEach { property ->
        add("${releaseSigningSources.getValue(property)} (or $property in android/key.properties) is not set")
    }
    if (releaseKeystore != null && !releaseKeystore.isFile) {
        add("the keystore ${releaseKeystore.path} does not exist")
    }
}

android {
    namespace = "com.procompanion.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.procompanion.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The volume-key test (#19) is an instrumented test: a key injected through the
        // input system reaches MainActivity the way a hardware press does, which no test
        // inside Flutter can do. integration_test/volume_key.sh runs it.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (releaseSigningProblems.isEmpty()) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = releaseSigning["storePassword"]
                keyAlias = releaseSigning["keyAlias"]
                keyPassword = releaseSigning["keyPassword"]
            }
        }
    }

    buildTypes {
        release {
            // Null when the upload key is missing, and checkReleaseSigning then stops the build.
            // There is deliberately no fallback to the debug keys.
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

val checkReleaseSigning by tasks.registering {
    val problems = releaseSigningProblems
    doLast {
        if (problems.isNotEmpty()) {
            throw GradleException(
                "A release build needs the upload key, and it is not configured:\n" +
                    problems.joinToString("\n") { "  - $it" } +
                    "\nSet the four PRO_COMPANION_* variables, or fill in android/key.properties" +
                    " (see docs/field-builds.md). Release builds never fall back to the debug keys."
            )
        }
    }
}
tasks.matching { it.name == "preReleaseBuild" }.configureEach { dependsOn(checkReleaseSigning) }

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// The integration_test plugin puts androidx.test:runner 1.3.0 (and monitor 1.3.0) on the debug
// app's classpath, and AGP's consistent resolution holds the test APK to the same versions: asking
// for a newer runner fails the build ("strictly 1.3.0"). So these are that generation's. No
// androidx.test.ext:junit: its androidx.test:core 1.3.0 declares activities without
// android:exported, which the manifest merge refuses at this target SDK, and the runner needs
// neither to run a JUnit 4 class.
dependencies {
    androidTestImplementation("androidx.test:runner:1.3.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.2.0")
}
