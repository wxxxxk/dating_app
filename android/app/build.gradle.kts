import java.io.File
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ===== Release signing (fail-closed) =====
// 실제 keystore/비밀번호는 저장소 밖 android/key.properties 로만 주입한다.
// (key.properties, *.jks, *.keystore 는 .gitignore 로 커밋 차단됨)
// - debug/test/analyze 는 key.properties 없이도 동작한다.
// - release 빌드를 요청했는데 secret 이 없거나 불완전하면 debug 키로 fallback 하지 않고
//   명확한 GradleException 으로 실패한다.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

// 빈 문자열도 미설정으로 취급한다.
fun secretOrNull(key: String): String? = keystoreProperties.getProperty(key)?.trim()?.takeIf { it.isNotEmpty() }

val releaseStorePath = secretOrNull("storeFile")
val releaseStorePassword = secretOrNull("storePassword")
val releaseKeyAlias = secretOrNull("keyAlias")
val releaseKeyPassword = secretOrNull("keyPassword")

// storeFile 은 절대 경로와 (저장소 루트 기준) 안전한 상대 경로를 모두 처리한다.
fun resolveKeystoreFile(path: String): File {
    val candidate = File(path)
    return if (candidate.isAbsolute) candidate else rootProject.file(path)
}

val resolvedKeystoreFile = releaseStorePath?.let { resolveKeystoreFile(it) }

val hasCompleteReleaseSigning =
    hasKeystoreProperties &&
        releaseStorePath != null &&
        releaseStorePassword != null &&
        releaseKeyAlias != null &&
        releaseKeyPassword != null &&
        resolvedKeystoreFile != null &&
        resolvedKeystoreFile.exists()

// release 산출물을 만들려는 요청인지 감지한다 (signingReport/analyze/test/debug 는 제외).
val isReleaseBuildRequested = gradle.startParameter.taskNames.any { rawTask ->
    val task = rawTask.substringAfterLast(':').lowercase()
    task.contains("release") &&
        (task.startsWith("assemble") ||
            task.startsWith("bundle") ||
            task.startsWith("package") ||
            task.startsWith("install"))
}

if (isReleaseBuildRequested && !hasCompleteReleaseSigning) {
    // 비밀 값 자체는 절대 출력하지 않는다. 어떤 항목이 비었는지 이름만 알린다.
    val missing = buildList {
        if (!hasKeystoreProperties) add("android/key.properties (파일 없음)")
        if (releaseStorePath == null) add("storeFile")
        if (releaseStorePassword == null) add("storePassword")
        if (releaseKeyAlias == null) add("keyAlias")
        if (releaseKeyPassword == null) add("keyPassword")
        if (releaseStorePath != null && (resolvedKeystoreFile == null || !resolvedKeystoreFile.exists())) {
            add("keystore file (지정된 storeFile 경로에 파일 없음)")
        }
    }
    throw GradleException(
        "Release signing is not configured. Refusing to fall back to the debug key.\n" +
            "Provide android/key.properties (see android/key.properties.example) with a real upload/release keystore.\n" +
            "Missing: ${missing.joinToString(", ")}"
    )
}

android {
    namespace = "com.cvrlab.dating_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cvrlab.dating_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // release signingConfig 은 완전한 secret 이 있을 때만 생성한다.
        if (hasCompleteReleaseSigning) {
            create("release") {
                storeFile = resolvedKeystoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // debug 키로 서명하지 않는다. secret 이 없으면 위에서 이미 fail-closed 로 막힌다.
            signingConfig = if (hasCompleteReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                null
            }
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
