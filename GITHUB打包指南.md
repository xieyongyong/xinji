# 用 GitHub 云端打包 APK（不用装任何开发环境）

> 结论：可以，而且对你这种情况比本地打包省事得多。
> 编译在 GitHub 的服务器上跑，你电脑只需要一个浏览器 + git。
> 编译完 APK 会自动挂到一个固定下载链接上，手机点开就能装。

---

## 一、为什么云构建更划算

| 项目 | 本地打包 | GitHub 云构建（本方案） |
|---|---|---|
| 装环境 | JDK 17 + Flutter SDK + Android Studio + SDK 命令行工具，约 10GB，1.5～2 小时，还要处理各种版本冲突 | **0 分钟，什么都不用装** |
| 下载依赖 | 国内拉 Gradle / Maven / ML Kit 经常卡住或超时 | GitHub 服务器在国外，直连 Google 仓库，通常 1～2 分钟拉完 |
| 每次打包 | 敲半小时命令 | **网页点一下按钮，等 8～12 分钟** |
| 出包位置 | 本地 `build/` 目录，还要手动传手机 | **固定网址，手机浏览器直接下** |
| 改代码后重新打包 | 重来一遍 | commit + push，自动开始编译 |
| 费用 | 免费 | 私有仓库每月 2000 分钟免费额度，每次约 10 分钟 → **约 200 次/月，用不完** |
| 换电脑 | 要重新装一遍环境 | 不需要，任何设备打开网页都能点 |

唯一的复杂点在第 1 步（把代码传上 GitHub），之后就一劳永逸了。

---

## 二、三条铁律（先看，能救命）

**1. 仓库必须设成 Private（私有）**

因为 `android/key.properties` 和 `android/app/keystore/xinji.jks`（应用签名文件）跟着代码一起传上去了。
这是故意这么做的——签名必须永远不变，否则你手机上的 App 没法覆盖升级。
但私有仓库是前提。想公开仓库，先看最后一节「进阶：改用 Secrets」。

**2. 以后更新版本，绝对不要先卸载旧版**

新 APK **直接覆盖安装**，数据全在。一旦卸载，App 内部的数据库和原图全没了（本地存储的必然结果）。
这也是为什么签名文件必须固定：签名一换，Android 就拒绝覆盖安装，逼你卸载 → 数据丢光。

**3. 不要删 `android/` 目录下这几个文件**

`app/build.gradle.kts`（minSdk 23 + 签名配置）、`app/src/main/AndroidManifest.xml`（权限 + 应用名）、
`app/src/main/kotlin/.../MainActivity.kt`（指纹解锁必需）、`key.properties`、`keystore/xinji.jks`。
其余 Android 文件（gradlew、图标、gradle wrapper）由 CI 每次自动补齐，不用管。

---

## 三、操作步骤

### 第 0 步：建一个空仓库

1. 打开 https://github.com/new
2. **Repository name** 填 `xinji`
3. 选 **Private**（重要）
4. 不要勾「Add a README file」「Add .gitignore」「Choose a license」，保持空仓库
5. 点 **Create repository**

建完页面会显示一串命令，先放着，下面用。

### 第 1 步：把代码推上去

代码我已经在本地初始化好 git 并提交过了，你只需要两条命令（在 `xinji` 目录里执行）：

```bash
cd "C:/Users/yongyong.xie001/WorkBuddy/2026-11-14-17-11-53/xinji"

git remote add origin https://github.com/你的用户名/xinji.git
git branch -M main
git push -u origin main
```

> 执行 push 时会弹出一个浏览器窗口让你登录 GitHub 并授权，点同意就行，不用另外配 SSH 或 token。

如果刚才那两条不行（比如仓库名不叫 xinji），换成建仓库页面显示的那串地址即可。

### 第 2 步：点一下按钮开始编译

1. 打开 `https://github.com/你的用户名/xinji/actions`
2. 左边点 **打包 APK**
3. 右边点 **Run workflow** → 再点绿色的 **Run workflow**
4. 刷新页面，会出现一条正在跑的记录，点进去能看到每一步的实时日志

正常情况：**8～12 分钟** 跑完（第一次稍慢，因为要下载 Flutter SDK，约 10～15 分钟）。

最后一步名字叫「发布到 Release」，它不报错就说明 APK 已经生成并挂好了。

### 第 3 步：手机下载安装

编译完成后，手机浏览器直接打开这个链接（**不用登录 GitHub**）：

```
https://github.com/你的用户名/xinji/releases/latest/download/xinji.apk
```

这个链接**永远不会变**，下次打包完它自动指向新版本，建议直接存成手机书签。

点下载 → 打开文件 → 系统提示「出于安全考虑，禁止安装未知来源应用」→ 选择「**设置**」→ 允许该浏览器安装 → 返回继续安装。

装完桌面出现「薪迹」图标。

> 第一次打开会让你设指纹 + PIN + 提示语（找人可见的提示语，忘 PIN 时用）。

---

## 四、以后改了代码怎么更新

```bash
git add -A
git commit -m "改了什么"
git push
```

推上去就会**自动**开始编译（workflow 里配了 push 触发）。
等十分钟，手机上点同一个书签链接下新版，**直接覆盖安装**（不要卸载），数据全在。

如果只是改文案不想等自动编译，也可以去 Actions 里手动点 Run workflow。

---

## 五、编译失败了怎么办

Actions 里点进失败的那条记录，找到**打红叉的那一步**，把日志复制给我。
常见几种我会提前说明：

| 日志里出现 | 原因 | 处理 |
|---|---|---|
| `Could not resolve com.google.mlkit:...` | ML Kit 依赖下载失败（少见，GitHub 网络通常没问题） | 重跑一次 |
| `requires compileSdk 35` / `Inconsistent JVM-target` | 某个依赖包升级后要求更高 SDK | 把日志给我，改两行 `build.gradle.kts` |
| `A problem occurred starting process 'command '.../sdkmanager''` | 缺 SDK platform | 一般 Flutter 会自动装，重跑即可 |
| `Execution failed for task ':app:processReleaseResources'` | 资源/图标问题 | 把日志给我 |
| `flutter pub get` 阶段失败（版本冲突） | 依赖版本要求冲突 | 把日志给我，我调 pubspec 的版本约束 |

`flutter analyze` 和 `flutter test` 两步我设了 `continue-on-error`，它们报问题**不会**中断打包，只会在日志里留记录。这是故意的：lint 提示不影响出包。

---

## 六、进阶：改用 Secrets（想公开仓库时）

如果哪天你想把仓库改成 Public，务必先做这件事，否则任何人都能拿到你的签名文件、签一个冒名 APK：

1. 把 keystore 转成 base64（Windows 上在 Git Bash 里执行）：
   ```bash
   base64 -w 0 android/app/keystore/xinji.jks > keystore.b64
   ```
2. 仓库 → Settings → Secrets and variables → Actions → New repository secret，加四个：
   | 名称 | 值 |
   |---|---|
   | `KEYSTORE_B64` | `keystore.b64` 文件里的那一长串 |
   | `KEYSTORE_PASSWORD` | `xinji2026` |
   | `KEY_ALIAS` | `xinji` |
   | `KEY_PASSWORD` | `xinji2026` |
3. 在 workflow 的「拉取依赖」之前插一步解码：
   ```yaml
   - name: 还原签名文件
     run: |
       mkdir -p android/app/keystore
       echo "${{ secrets.KEYSTORE_B64 }}" | base64 -d > android/app/keystore/xinji.jks
       cat > android/key.properties <<EOF
       storePassword=${{ secrets.KEYSTORE_PASSWORD }}
       keyPassword=${{ secrets.KEY_PASSWORD }}
       keyAlias=${{ secrets.KEY_ALIAS }}
       storeFile=keystore/xinji.jks
       EOF
   ```
4. 从 git 里删掉签名文件：
   ```bash
   git rm --cached android/key.properties android/app/keystore/xinji.jks
   ```
   然后把 `.gitignore` 里注释掉的那两行恢复。

改完之后你自己电脑上仍然要留一份 `xinji.jks` 备份（放网盘/U盘），丢了就再也无法覆盖升级。

---

## 七、这套配置到底是什么（想改的时候看）

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-apk.yml` | 编译流水线：拉代码 → 装 JDK 17 → 装 Flutter 3.29.3 → 补 Android 骨架 → 拉依赖 → 编译 → 上传 → 发 Release |
| `android/app/build.gradle.kts` | minSdk 23、包名 `com.xinji.payslip`、签名配置、关闭混淆 |
| `android/app/src/main/AndroidManifest.xml` | 应用名「薪迹」、生物识别权限、**故意不声明网络权限** |
| `android/app/src/main/kotlin/com/xinji/payslip/MainActivity.kt` | 继承 `FlutterFragmentActivity`，指纹解锁不崩的前提 |
| `android/key.properties` | 签名密码与别名 |
| `android/app/keystore/xinji.jks` | 签名文件本体，有效期 30 年 |

两个容易踩的坑，配置里都已经处理好了，列出来免得你以后「优化」时踩回去：

1. **`MainActivity` 必须是 `FlutterFragmentActivity`**，写成默认的 `FlutterActivity` 会在调指纹时直接崩。
2. **Flutter 版本必须写死**（现在是 3.29.3）。Flutter 每个版本生成的 Android 模板（AGP/Gradle/Kotlin 版本）都不同，跟仓库里的 `build.gradle.kts` 对不上就会编译失败。想升级 Flutter，要连 `build.gradle.kts` 一起验。
