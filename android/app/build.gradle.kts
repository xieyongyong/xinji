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

        // 只打真机常见的两种 ARM 架构：ONNX Runtime 每个 ABI 的 so 都在 15MB 上下，
        // 留 x86 只是让模拟器能跑，真机用不上，白占包体
        ndk {
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a"))
        }
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
// 文字识别不再走 Flutter 插件，而是由 OcrService 在 :ocr 进程里直接调。
//
// 主引擎是 PP-OCRv6（ONNX Runtime 跑 PP-OCRv6_small 的 det + rec 模型，
// 模型和字典在 assets/ppocr/ 下，30MB 左右）：
//   · 对工资条这种"表格 + 密集数字"的图，小数点、千分位比 ML Kit 稳得多
//   · 完全离线、不依赖 Google Play 服务
//
// ML Kit 保留着当兜底：设置里可以切回「兼容模式」。
// 它本来就随包发布，多留一份不会让包变大，但能保证引擎出问题时你还有退路。
dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.18.0")

    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

