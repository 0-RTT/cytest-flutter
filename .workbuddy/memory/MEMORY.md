# cytest-flutter 项目记忆

## 定位
Kotlin 版（0-RTT/cytest-app）的 Flutter 重写，独立仓库 0-RTT/cytest-flutter，独立目录 D:\cytest-flutter。
与 cytest-app 共用同一份网络引擎（engine/pipeline.go 是从 tools/pipeline 复制的副本，改动需两边同步）。
**本目录的记忆只写 Flutter 侧，不要再往 cytest-app 的 memory 里混。**

## 构建环境（2026-11-17 打通）
Flutter 3.50.0 / Dart 3.14.0，SDK 在 `D:\cytest-app\.workbuddy\tmp\env\flutter`（由 activate.sh 注入 PATH）。
`source D:\cytest-app\.workbuddy\tmp\env\activate.sh` 后：
- `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`（引擎包必须走这个，否则 Google 存储下载中断）
- `PUB_HOSTED_URL=https://pub.flutter-io.cn`
- `ANDROID_HOME` = `D:\cytest-app\.workbuddy\tmp\env\sdk`（platforms 34/35/36/37.0 已装齐）

版本组合（踩了一轮才定）：**AGP 9.1.1 + Gradle 9.3.1 + Kotlin 2.4.20 + compileSdk 37**。
- Flutter 3.50 强制 Gradle ≥ 9.3.1、AGP ≥ 9.1.1，降版本行不通
- AGP 9.3.1 要求 Gradle 9.5.0，本地没有，所以卡在 9.1.1

## 关键坑
1. **flutter_inappwebview 6.1.5 不兼容 AGP 9**：它用 `getDefaultProguardFile('proguard-android.txt')`，AGP 9 已移除。
   解法：把插件 vendor 到 `packages/flutter_inappwebview_android`，改成 `proguard-android-optimize.txt`，
   pubspec 用 `dependency_overrides` 指向本地路径（CI 同样生效）。升级插件后可去掉。
2. **各插件要求不同 compileSdk**：jni_flutter 要 35、inappwebview 要 34，本机原本只有 37。
   已用 sdkmanager 装齐 34/35/36；主项目与 vendor 插件都指向 37。
3. **网络下载极不稳定**：Flutter SDK（1.7G）和 Gradle 发行包多次下载损坏（zip 中央目录缺失）。
   可靠做法是用 `D:\cytest-app\.workbuddy\tmp\dl.py`（Python 分块 + Range + zip 校验）手动补到缓存。
4. **Dart 与 Kotlin 的行为差异**：`Uri.fragment` 不解码（Kotlin 会），需显式 `Uri.decodeComponent`。
   `Uri.queryParameters` 会自动解码，注意区分。

## 代码结构
`lib/data/` 逐项对齐原版：vless（解析/替换/配置）、xray（进程+批量）、pipeline（三阶段+CSV）、
node_template（订阅+mihomo）、history、remote（dartssh2）、github。
`lib/state/app_state.dart` 是 ChangeNotifier 门面，`lib/ui/home.dart` 是两列卡片 + 底部两 Tab。

## 与原版的已知差异
导出改复制到剪贴板（不写外部存储）；链路测速是串行起 Xray 探活（未做多端口批量）；
mihomo 只保留 proxies/groups/rules 核心段（无 rule-providers、假 IP 过滤）。

## 产物
APK 走 `flutter build apk --release --target-platform android-arm64`，
二进制（pipeline / pipeline-linux / xray）由 `scripts/fetch-assets.sh` 或 CI 生成，不入库。

## CI 与发布（2026-11-17 打通）
GitHub Actions：`subosito/flutter-action@v2` + runner 预装 Android SDK，`flutter analyze` →
`flutter test`（12 项）→ `flutter build apk --release --target-platform android-arm64` 全绿。
APK 37.5MB，包名 `com.cytest.cytest`，minSdk 29 / targetSdk 36，与 Kotlin 版（com.cytest.app）可共存。

发版：`git tag -a v1.x.x -m "..." && git push origin v1.x.x` → release job 下载 artifact、
重命名为 cytest-flutter.apk 后发正式版。日常 push main 只上传 artifact（不发 release）。
**必须在 workflow 顶层声明 `permissions: contents: write`**，否则 softprops 发 release 报 403
（generate_release_notes 也依赖这个权限）。

注意：CI 里 `Download pipeline binaries` 步骤实际是用 engine/pipeline.go 现场编译（Go 1.27.1），
不是从 cytest-app 的 release 拉——engine/pipeline.go 必须与 tools/pipeline/pipeline.go 保持同步。
