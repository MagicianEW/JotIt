import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 工程内固定的签名材料。
//
// 两份，性质完全不同：
//
//   key.properties          开发用，**有意入库**。口令是公开的。
//   key-release.properties  发布用，**绝不入库**（见 .gitignore）。
//
// 开发签名为什么固定：Android 的 debug 签名默认取自每台机器各自的
// ~/.android/debug.keystore，两台机器编出来的同一个 App 签名不同 —— 装到
// 同一台设备上会被系统以「签名不一致」拒绝，只能先卸载，而卸载会带走用户的
// 笔记。签名固定在工程里之后，换机器、换设备都能直接覆盖安装。
val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
val hasFixedSigning = signingPropertiesFile.exists()
if (hasFixedSigning) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}

// 发布签名。有就用，没有就退回开发签名并把话说清楚。
val releaseProperties = Properties()
val releasePropertiesFile = rootProject.file("key-release.properties")
val hasReleaseSigning = releasePropertiesFile.exists()
if (hasReleaseSigning) {
    releasePropertiesFile.inputStream().use { releaseProperties.load(it) }
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
        if (hasReleaseSigning) {
            create("jotitRelease") {
                storeFile = rootProject.file(releaseProperties.getProperty("storeFile"))
                storePassword = releaseProperties.getProperty("storePassword")
                keyAlias = releaseProperties.getProperty("keyAlias")
                keyPassword = releaseProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        // debug 用工程内那把固定密钥：换机器、换设备都能直接覆盖安装。
        //
        // 缺了 key.properties 就退回 AGP 自带的 debug 签名：构建不应该因为
        // 一个附属文件不存在而失败。
        getByName("debug") {
            signingConfig = if (hasFixedSigning) {
                signingConfigs.getByName("jotit")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        release {
            // release 优先用自己的私钥（key-release.properties，不入库）。
            // 没有它时退回开发密钥——能装能用，但密钥是公开的，**不能上架**：
            // 任何人都能签出一个「更新」装到用户手机上顶掉官方包。
            signingConfig = when {
                hasReleaseSigning -> signingConfigs.getByName("jotitRelease")
                hasFixedSigning -> {
                    // 打印到 stdout 而不是 logger.warn：Gradle 的 logger 在
                    // 配置阶段常常被静默掉，而这条警告恰恰是最不能被静默的
                    // 一次——它说的是「你手上这个包不能拿去上架」。
                    println(
                        "WARNING: no android/key-release.properties — the release " +
                            "build is signed with the shared DEVELOPMENT key. That " +
                            "key is public: anyone can sign an update that " +
                            "replaces this app on a user's phone. Do not " +
                            "publish a build signed this way.",
                    )
                    signingConfigs.getByName("jotit")
                }
                else -> signingConfigs.getByName("debug")
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
