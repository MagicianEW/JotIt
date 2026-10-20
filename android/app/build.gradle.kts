import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 工程内固定的签名材料（android/key.properties + android/keystore/）。
//
// 默认的 debug 签名取自每台机器各自的 ~/.android/debug.keystore，两台机器
// 签出来的包不同 —— 装到同一台设备上会被系统以「签名不一致」拒绝，只能
// 先卸载，而卸载会带走用户的笔记。签名固定在工程里之后，换机器、换设备
// 都能直接覆盖安装。
//
// 缺了 key.properties 就退回 AGP 自带的 debug 签名：构建不应该因为一个
// 附属文件不存在而失败。
val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
val hasFixedSigning = signingPropertiesFile.exists()
if (hasFixedSigning) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}

android {
    namespace = "com.jotit.jotit"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.jotit.jotit"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasFixedSigning) {
            create("jotit") {
                storeFile = rootProject.file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        // debug 和 release 用同一份签名，是有意为之：开发时用 release 包
        // 覆盖安装到 debug 包上，不会因为签名不同而被拒。
        getByName("debug") {
            signingConfig = if (hasFixedSigning) {
                signingConfigs.getByName("jotit")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        release {
            signingConfig = if (hasFixedSigning) {
                signingConfigs.getByName("jotit")
            } else {
                signingConfigs.getByName("debug")
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
