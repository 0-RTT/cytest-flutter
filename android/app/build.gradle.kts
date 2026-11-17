plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.cytest.cytest"
    compileSdk = 37  // 本机 SDK 已有 37，避免额外下载 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cytest.cytest"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29  // WebView 代理覆盖需要 API 29+
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // 必须解压到 nativeLibraryDir，否则无法作为独立进程执行
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        create("release") {
            // 固定签名：本地与 CI 必须一致，否则覆盖安装会报「与已安装应用签名不同」
            // 个人项目，keystore 随仓库分发；若将来公开分发请改用 secrets 注入
            storeFile = file("cytest-release.jks")
            storePassword = "cytest123"
            keyAlias = "cytest"
            keyPassword = "cytest123"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
