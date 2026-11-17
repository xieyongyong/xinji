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
        // RapidOCR4j-Android 1.0.0 的硬要求：minSdk >= 29。
        // 它内部用了 java.nio.file（API 26 起）并且作者只保证 29+；
        // 我们的 PY/OpenCV 方案也依赖这个库自带的 opencv:4.9.0。
        // 代价是从旧版覆盖安装会失败，需要备份数据后卸载重装一次。
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只打 64 位 arm64-v8a：现在的新手机（含用户的 Android 11）都是 64 位，
        // armeabi-v7a 是给 2015 年前的老机用的。去掉它能省 ~40MB——
        // ONNX Runtime + OpenCV 每套 ABI 的 so 都很大，双 ABI 等于打包两份。
        // 代价：32 位老手机装不了，但那些机器也跑不动 PP-OCRv6。
        ndk {
            abiFilters.addAll(listOf("arm64-v8a"))
        }
    }

    androidResources {
        // RapidOCR4j 的 AAR 自带 PP-OCRv4 的 det/rec 模型（约 14MB），我们用的是
        // PP-OCRv6_small（assets/ppocr/ 下），这两个文件永远不会被加载。
        //
        // 关键：这些文件在 AAR 的 assets/ 里，走的是 mergeAssets 合并流程，
        // packagingOptions.resources.excludes 管不到它——上一版就是这么漏进包的。
        // 真正生效的是 ignoreAssetsPattern：它作用于 assets 合并阶段，
        // 用「!文件名」表示排除。保留系统默认pattern并追加两条。
        // cls 模型**不能排除**：库构造时无条件 new TextClassifier，就算 useCls=false
        // 也要能加载到那个模型（只有 0.5MB，留着）。
        ignoreAssetsPattern = "!.svn:!.git:!.ds_store:!*.scc:.*:<dir>_*:!CVS:!thumbs.db:!picasa.ini:!*~:!ch_PP-OCRv4_det_infer.onnx:!ch_PP-OCRv4_rec_infer.onnx"
    }

    packagingOptions {
        resources {
            // 双保险：即使某些 AGP 版本下 assets 也走 resources.excludes，这里也拦一道。
            // 真正起作用的是上面的 ignoreAssetsPattern。
            excludes += listOf(
                "assets/ch_PP-OCRv4_det_infer.onnx",
                "assets/ch_PP-OCRv4_rec_infer.onnx"
            )
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
            // 不开混淆：RapidOCR4j 的类要被 ONNX Runtime / OpenCV 的 JNI 反射访问，
            // 混淆后容易崩，包大一点换稳定
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

// ---------------------------------------------------------------- 原生依赖
// 文字识别不走 Flutter 插件，由 OcrService 在 :ocr 进程里直接调。
//
// 引擎就是用户指定的那套：RapidOCR4j-Android + PP-OCRv6_small + OpenCV 预处理。
//   · rapidocr4j-android:1.0.0 传递依赖 opencv:4.9.0 和 onnxruntime-android:1.18.0
//   · 检测/识别模型和字典换成 PP-OCRv6_small，放在 assets/ppocr/（约 31MB）
//   · OpenCV 负责灰度/CLAHE/去噪/二值化，RapidOCR 内部也用它做检测框后处理
//
// 完全离线、不依赖 Google Play 服务。ML Kit 早已删干净，没有第二条识别链路。
dependencies {
    implementation("io.github.hzkitty:rapidocr4j-android:1.0.0")
    // 显式写一遍锁定版本：库本身也引这个，避免 Gradle 与其他传递依赖挑了旧版
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.18.0")
}

