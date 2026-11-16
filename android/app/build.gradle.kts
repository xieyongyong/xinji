import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // Flutter 的 Gradle 插件必须放最后
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------- 签名配置
// key.properties 存在 → 用固定签名；不存在 → 退回 debug 签名（能编译，但换机不能覆盖安装）
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystore = keystorePropertiesFile.exists()
if (hasKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.xinji.payslip"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    // 这两项必须和上面保持一致，否则 Gradle 会报
    // "Inconsistent JVM-target compatibility detected"
    kotlinOptions {
        jvmTarget = "11"
    }

    defaultConfig {
        applicationId = "com.xinji.payslip"
        // 23 是硬下限：local_auth（指纹/面容）从 API 23 才有 BiometricPrompt
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = if (hasKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 不开混淆：ML Kit 通过反射加载识别器，混淆后容易崩，包大一点换稳定
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

// ---------------------------------------------------------------- 原生依赖
// 文字识别不再走 Flutter 插件，而是由 OcrService 在 :ocr 进程里直接调 ML Kit。
// 这样做有两个好处：
//   1. 能选到比插件更新的原生库版本（插件 0.13 绑的是 16.0.0）
//   2. 不再把 japanese / korean / devanagari 三套模型打进 APK，包小一截
//
// 只保留 latin（数字、英文、符号）和 chinese 两套 bundled 模型：
// 都是**离线**的，不依赖 Google Play 服务，国产无 GMS 手机也能用。
dependencies {
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

