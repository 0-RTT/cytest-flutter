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
重命名为 cytest-flutter.apk 后发正式版。
**2026-11-17 起 workflow 只监听 tag**（`on.push.tags: ['v*']`），已去掉 `branches: [main]`。
原因：发版要先 `push main` 再 `push tag`，两个触发条件会让同一 commit 被完整构建两遍
（历史 #20/#21、#22/#23、#24/#25 全是成对的）。现在日常验证走本地 `flutter analyze` + `flutter test`，
或开 PR（`pull_request` 触发保留）。改完配置后 push main 不会再产生 run，可用 actions 页面确认。

**必须在 workflow 顶层声明 `permissions: contents: write`**，否则 softprops 发 release 报 403
（generate_release_notes 也依赖这个权限）。

注意：CI 里 `Download pipeline binaries` 步骤实际是用 engine/pipeline.go 现场编译（Go 1.27.1），
不是从 cytest-app 的 release 拉——engine/pipeline.go 必须与 tools/pipeline/pipeline.go 保持同步。

## WebView 必须真实可见（v1.0.3 定稿）
`InAppWebView` 放在 `SizedBox(height: 1)`、`Positioned(left: -3000)`、`Opacity(0.01)` 三种写法下
原生 View 都不 attach，`onWebViewCreated` 永不触发，`_web` 保持 null → 报「WebView 初始化失败」。
**正确做法（v1.0.3 起）**：`Column` + `Expanded(ListView)` + 底部固定高度预览区，
高度 `min(180, 屏高×30%)` 且下限 60，键盘弹出（`viewInsets.bottom > 0`）时压到 60。
**铁律：高度绝不能压到 0 或移出屏外**，那会销毁 PlatformView、`_web` 置空、正在跑的 loadUrl 丢失。
注意 `viewInsets` 必须在 `build(context)` 这层读（Scaffold 之上），Scaffold 在
`resizeToAvoidBottomInset: true` 时会把 body 内的底部 inset 抹成 0。
抓取前等 controller 就绪的上限已放宽到 15 秒（低端机首次建 PlatformView 常超 3 秒），
状态卡显示已等秒数与 WebView 阶段，便于远程排障。

## release 包必须声明 INTERNET（v1.0.3 修）
`INTERNET` 原本只写在 `android/app/src/debug|profile/AndroidManifest.xml`，**main 里没有**，
release 只合并 main → 正式包彻底无网络能力。症状极具误导性：
- xray 子进程无法创建 AF_INET socket → `freePort()` 全部抛异常被 catch 吞掉 → 回落 20000
  → 仍绑不上 → `waitPort` 8 秒超时 → 报「xray 未能在 8 秒内监听」
- WebView 加载任何网页都被系统拦截
排查铁律：**怀疑权限/打包问题时，从 APK 本体取证据**，别只看源码或中间产物：
`aapt2 dump permissions app-release.apk`，或解包读二进制 manifest。
（`build/app/intermediates/packaged_manifests/.../AndroidManifest.xml` 是合并后明文，也可直接 grep。）
AGP 会 strip `jniLibs` 里的 ELF，但只影响节头表区，不影响执行；APK 内与本地差 306 字节属正常。


## 二进制执行权限：必须走 jniLibs（v1.0.2 起）
把 xray/pipeline 解压到 `filesDir` 再 `chmod 755` **在 Android 上行不通**——SELinux 拒绝
`app_data_file` 执行，报 `ProcessException: Permission denied`（而 `Process.run('chmod')` 的失败
被 catch 吞掉，表面看是 chmod 成功）。
正确做法：二进制以 `libpipeline.so` / `libxray.so` 放进 `android/app/src/main/jniLibs/arm64-v8a/`，
配 `packaging.jniLibs.useLegacyPackaging = true` 让系统解压到 nativeLibraryDir（自带 x 权限）。
运行时路径通过 MethodChannel `cytest/native` 的 `nativeLibraryDir` 拿（见 MainActivity.kt）。
附带收益：APK 从 37.6MB 降到 27.3MB（.so 压缩存储）。

注意：CI 里 xray 必须 `unzip -d /tmp` 后 `mv` 到 jniLibs，落到 `assets/` 不会进包（会被静默忽略，
APK 小 12MB 且运行时报找不到 libxray.so）。

## UI 布局铁律（v1.0.6 定稿）
**`Scaffold` 的 body 不会自动避让系统手势条/三键导航**，必须在 body 包
`SafeArea(top: false, child: ...)`；`top: false` 是因为顶部已由 AppBar 处理。
全项目 8 个页面（home/fetch/test/lines/remote/settings/history/result）统一如此。
例外：带 `bottomNavigationBar` 的 Scaffold 会把 body 的 bottom padding 清零
（`scaffold.dart` 的 `removeBottomPadding`），那里 SafeArea 取 0，重复应用无害。

**M3 坑**：`IconButton` 的 `iconSize` / `padding` / `visualDensity` / `constraints`
四个构造参数在 M3 下会被 `_IconButtonM3` 丢弃，且 `tapTargetSize: padded` 会把按钮
撑到 40px。要压尺寸必须走 `style: ButtonStyle(...)`。

## 与 Kotlin 版的功能差距（2026-11-17 逐条对照）
Kotlin 版 111 个 .kt / 17,108 行；Flutter 版 21 个 .dart / 4,236 行。
69 个用户可见功能点：已对齐 8 / 缺失 37 / 退化 24，加权完成度约 **30%**。
- P0 核心流程 64%：抓取→三阶段→结果→推 GitHub 这条主干靠复用 Go pipeline 保住了
- **P1 日常效率仅 16%**：原版价值密度最高的那层几乎全空
- 三个「行为错」比「缺功能」更危险：
  1. 链路测速记的是 Xray **启动耗时**，不是 TTFB/吞吐（`lines_page.dart` 的 probe）
  2. 「取消测试」用 `pkill -f cytest/pipeline`，但进程名是 `libpipeline.so`，**杀不掉**
  3. 链路测速逐条 `xray.start()` 重启，40 条要串行重启 40 次（批量配置已写好未接线）
- 缺失大头：结果页排序/筛选/导出文件、历史合并、mihomo 的 rule-providers/dns/tun、
  备份 UI（`history.dart` 的 exportBackup/importBackup 已实现但零调用）、last run 恢复

## 版本号

`pubspec.yaml` 的 version 是占位，实际由 `--build-name` / `--build-number` 覆盖。
CI 在 tag 时注入 `BUILD_NAME=${GITHUB_REF#refs/tags/v}`，所以 v1.0.2 的包 versionName 就是 1.0.2。
本地构建记得手动传这两个参数，否则显示 1.0.0。

## 验收准则：先有能跑的二进制，再谈断言（2026-11-17 立）
1. **无命令 = 未验收**：每条「通过」必须附「可复现命令 + 关键输出 + 退出码」，缺一算未做。
2. **断言机器可判**：用 expect / 退出码 / grep 命中数落断言，禁用「已实现 / 符合设计 / 应该没问题」。
3. **成功与失败路径都留证**：死端口、空数据、截断输入必须证明「错误可读、不静默降级、退出码正确」，只测 happy path 不算数。
4. **基线数量不写死**：写「原 N 不回归 + 新增全绿 = 总数全绿」，随基线（34→90→110…）更新仍成立。
5. **三道关分开留证**：静态（`flutter analyze` + `dart analyze tool/`）/ 测试（全量）/ 构建产物（INTERNET、extractNativeLibs、.so 齐）各自独立过关，不互相顶替。
6. **拿不到环境就标「未验收」**：缺设备/缺出口时不得用「某侧跑通了」替代「真机跑通了」，降级为后续项并写明阻塞关系。

> 起因：2026-11-17 一轮里出现「110 测试全绿但 `grep '\.latency()' test/` 零命中」——
> 最核心的入口函数一条没测，全靠真机冒烟兜。测试数量不等于覆盖。

