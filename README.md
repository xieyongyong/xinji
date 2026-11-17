# 薪迹 · 本地工资条记录与对比

拍/截图导入工资条 → 离线 OCR 自动填表 → 按月归档 → 年度总览 → 两月逐项对比。
**数据只存在手机里，不上传、不需要账号。**
（联网只有两处，都是可选：① 检查更新 / 应用内更新——读版本号、下载 APK；② 云盘备份——需你主动填 WebDAV 服务器并点上传，备份是 AES-256 加密后传到你自己的网盘。不开则完全离线。）

---

## 一、已实现的功能

| 模块 | 实现情况 |
|---|---|
| 多图导入 | 相册多选、拍照，支持一次导入多张 |
| **多图重叠合并** | 按行序列检测相邻图的重叠区，自动去重；无重叠会告警；去重项可展开撤回 |
| 离线 OCR | RapidOCR4j-Android + PP-OCRv6_small + OpenCV 预处理，ONNX Runtime 本地推理 |
| 识别预填 | 项目名 / 金额 / 合计行 / 系数行自动分拣，口径不对会标黄 |
| 合计校验 | 明细加总 ≠ 应发、应发−代扣 ≠ 实发 时提示，但不阻止保存 |
| 手动录入 | 不用图片也能记 |
| 动态明细项 | 收入 / 扣款两组，支持「金额型」和「系数型」（绩效系数） |
| 同月多笔 | 补发、绩效二次发放可分开记，统计时自动求和 |
| 奖金记录 | 年终奖、项目奖金独立类型，简化表单，不进月度对比 |
| 列表 / 详情 / 编辑 / 删除 | 每月卡片、多笔展开、原图可看 |
| 年度总览 | 工资 / 奖金 / 总收入三口径，12 月趋势图，项目年度榜 |
| 两月对比 | 逐项差额 + 变化率 + 新增/消失标注，变动大的自动加粗 |
| 备份恢复 | 加密备份 `.xbk`（AES-256）/ 明文 `.zip`（含 CSV），一键恢复；偏好设置随备份一起还原 |
| 云盘备份 | 可选功能，WebDAV（坚果云 / 群晖 / Nextcloud）上传/下载加密备份，默认关闭 |
| 应用锁 | 指纹/面容优先 + PIN 兜底 + 提示语找回，切后台 30 秒重新上锁 |
| 在线更新 | 应用内后台下载、断点续传，常驻进度条（百分比/速度/剩余时间），不打断使用 |
| 主题外观 | 5 套配色 + 浅色/深色/跟随系统，涨红跌绿保持不变 |

---

## 怎么变成能装到手机上的 App

**推荐：GitHub 云端打包，电脑不用装任何开发环境。**

```bash
# 1. 在 GitHub 建一个 Private 空仓库，名字随便（下面以 xinji 为例）
# 2. 推到仓库
git remote add origin https://github.com/你的用户名/xinji.git
git push -u origin main
# 3. 打开 https://github.com/你的用户名/xinji/actions → 左边「打包 APK」→ Run workflow
# 4. 等 10 分钟，手机浏览器打开下面这个固定链接直接下载安装
#    https://github.com/你的用户名/xinji/releases/latest/download/xinji.apk
```

完整步骤、报错对照表、签名与 Secrets 说明见 **[GITHUB打包指南.md](GITHUB打包指南.md)**。

也可以在自己电脑上编译（要装 JDK 17 + Flutter + Android SDK，约 10GB），步骤见 [打包指南.md](打包指南.md)——**不是必需**，除非你想离线改代码。

> 更新版本时**直接覆盖安装，不要卸载**。卸载会连本地数据库和原图一起删掉。

---

## 二、目录结构

```
xinji/
├── pubspec.yaml                      依赖清单
├── lib/
│   ├── main.dart                     入口、全局 Provider、后台超时上锁
│   ├── core/
│   │   └── money.dart                ★ 金额解析与格式化（全部按「分」存整数）
│   ├── data/
│   │   ├── models.dart               数据模型（PayRecord / PayItem / PayImage / ItemTemplate）
│   │   ├── db.dart                   SQLite 建表、迁移、预置模板
│   │   ├── record_dao.dart           记录读写
│   │   └── template_dao.dart         模板读写
│   ├── ocr/
│   │   ├── ocr_models.dart           三层中间结构：RawLine → VisualRow → ParsedRow
│   │   ├── line_builder.dart         按 y 坐标把碎片聚成「视觉行」
│   │   ├── field_parser.dart         ★ 从行里解析项目名/金额/合计/系数
│   │   ├── merge_engine.dart         ★★ 多图重叠合并（本项目最核心算法）
│   │   └── ocr_service.dart          OCR 门面 + 长截图压缩
│   ├── stats/
│   │   └── salary_stats.dart         月/年聚合、对比计算
│   ├── security/
│   │   └── lock_service.dart         PIN 哈希、生物识别、提示语找回
│   ├── backup/
│   │   └── backup_service.dart       ZIP / AES 加密备份与恢复
│   ├── state/
│   │   └── app_state.dart            全局状态、OCR 流程编排
│   └── ui/
│       ├── theme.dart                主题与配色（涨红跌绿）
│       ├── home_page.dart            首页：年份 + 月份卡片
│       ├── import_page.dart          导入入口
│       ├── review_page.dart          ★ 校对 / 新建 / 编辑（同一表单三用）
│       ├── detail_page.dart          单条详情
│       ├── yearly_page.dart          年度总览
│       ├── compare_page.dart         两月对比
│       ├── settings_page.dart        设置 + 项目模板管理
│       ├── lock_page.dart            解锁 / 设置锁 / 找回 PIN
│       └── widgets/image_viewer.dart 原图查看
├── android/                          Android 工程配置（云构建用）
│   ├── app/build.gradle.kts          minSdk 29、包名、签名、关混淆
│   ├── app/src/main/AndroidManifest.xml  应用名、生物识别权限、无网络权限
│   ├── app/src/main/kotlin/.../MainActivity.kt  FlutterFragmentActivity（指纹必需）
│   ├── app/keystore/xinji.jks        签名文件（改动会导致不能覆盖安装）
│   └── key.properties                签名密码
├── .github/workflows/build-apk.yml   ★ GitHub Actions 自动打包
├── analysis_options.yaml             静态检查规则
├── test/core_logic_test.dart         核心算法测试（合并 / 金额 / 系数）
├── GITHUB打包指南.md                 ★ 手机拿到 APK 的最快路径（推荐）
└── 打包指南.md                       本地装环境自己编译（备选）
```

---

## 三、几个关键设计（为什么这么写）

### 1. 金额一律按「分」存整数
`0.1 + 0.2 != 0.3`。工资条的核心功能是「明细加总 == 合计」的校验，
如果用 double，每次校验都会差 1 分钱，报警会响个不停。
所以 `amountCents` 是 int（12345.67 元 → 1234567 分），只在显示和导出时格式化。

### 2. 多图合并靠「行序列重叠」，不靠项目名去重
你的真实场景是：明细太长 → 分屏截图 → 相邻两张有重叠区。

如果按项目名去重，两笔同名的奖金会被误删。所以做法是：

```
图A 的末尾 k 行  ==  图B 的头部 k 行   →  判定重叠，去掉这 k 行
```

从最大的 k 开始往下试，第一个匹配上的就是最长重叠。
匹配不上时再分两种情况：弱重叠（首行出现过）→ 提示交界处可能被切断；
完全不重叠 → 提示中间可能漏截。**绝不静默吞数据。**

另外三处兜底：
- 合计行单独抽出来，不参与重叠匹配（否则每张图底部的「合计」会干扰比对）
- 拼接后相邻的同名同额行自动去重，但记入「已去除项」，可一键撤回
- 最后用「明细加总 vs 工资条合计」做终检，这是发现漏行最可靠的信号

### 3. 项目名不写死在代码里
明细项全部走 `pay_item` 表 + `item_template` 模板。
换公司、公司改项目名（「岗位津贴」→「岗位工资」）都不用改代码，
在设置里加个别名就能让对比重新对齐。

### 4. 主表只留通用字段
`periodYear / periodMonth / recordType / gross / deduction / net` 是任何公司都有的。
薪级、基薪、备注这些塞进 `extra`（JSON），不占表结构。

### 5. 奖金和工资分开口径
奖金塞进月度柱状图会让某个月突然高十倍，图就没法看了。
所以：柱状图只画月度工资，奖金单独一块；月度对比也只比月度工资。

---

## 四、已知限制（说清楚，别踩坑）

1. **OCR 不可能 100% 准**。绩效系数（1.20 这种小数）、带括号的负数、深色背景图最容易出错。
   所以流程设计成「识别 → 预填 → 你扫一眼改 → 保存」，不是全自动。
2. **首次使用识别率最低**。公司项目名和预置模板对不上时，需要你手动改一次名称；
   改完它会记住（你也可以去模板里加别名）。
3. **卸载 App 会连数据一起删**。本地存储的必然代价，请定期导出备份。
4. **忘记 PIN 只能靠提示语**。提示语也忘了，就只剩「清除数据重装」。
5. **APK 体积约 91MB**。PP-OCRv6 模型（25MB）、单套 arm64 的 ONNX Runtime + OpenCV native 库都在包里，这是完全离线的代价。只支持 64 位手机（现在的新机都是）。
6. **检查更新走应用内下载**。仓库已公开，联网只用于读版本号和下载 APK，不带走任何工资数据。
7. **v2.0.0 起 minSdk 升到 29**。Android 10 及以下装不了；从旧版覆盖安装如失败，先导出备份再卸载重装。

---

## 五、下一步可以加的（V2 方向）

- 导出 Excel / PDF（当前备份里的 CSV 已能直接喂给 Excel）
- 分类占比、绩效系数走势、税负率曲线
- 发薪日提醒
- 多雇主档案（跳槽后新旧工资条并存）
- iOS 适配（代码结构已按跨端写，主要补 iOS 权限声明和打包配置）
