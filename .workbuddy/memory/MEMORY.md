# cytest-flutter · 作业记忆

> 只记「怎么干活」与「踩过的坑」。**实现细节、口径、数据流看 `docs/ARCHITECTURE.md`**，两处不要重复写。

仓库 `D:\cytest-flutter`。`engine/pipeline.go` 是 Go 引擎源码副本，改动需与上游同步。

---

## 1. 发布（每次都用）

```bash
source toolchain.sh   # 仓库根目录的入口脚本，自动找到工具链
cd /d/cytest-flutter && git add -A && git commit -m "..."
git -c http.proxy=socks5h://127.0.0.1:10808 push origin main
git tag -a v1.0.NN -m "..." && git -c http.proxy=socks5h://127.0.0.1:10808 push origin v1.0.NN
```

- **CI 只监听 `v*` tag**：push main 不出包，要出包必须打 tag。
- 本机 v2rayN 只有 **SOCKS 10808**（无 HTTP 入站）→ git 必须 `socks5h://`（`h` 让代理解析域名）。
- 查 CI/GitHub API：`curl --ssl-no-revoke --socks5-hostname 127.0.0.1:10808`（schannel 吊销检查离线会报 `CRYPT_E_REVOCATION_OFFLINE`）。
- 现在基线 **v1.0.48**；APK 28.6 MB（27.31 MiB）。

## 2.1 推送前 / 推送后（2026-11-21 定）

- **推送前必须跑 `tool/precheck.sh`**（= CI 同口径 `flutter analyze --no-fatal-infos`，
  **warning 也是致命的** + `flutter test`）。只跑 `dart analyze lib` 会漏：
  v1.0.70 就因为 `lib/ui/home.dart` 一个 `unused_local_variable` 直接把 CI 打红。
- **打完 tag 必须等 CI 跑完并确认 success 才算结束回合**，不能推完就退。

## 2. 工作方式（用户明确要求）

- **小 bug：直接改 → 只对改动文件 `dart analyze` → 提交 → 推 CI。** 不建团队、不跑本地全量、不冻结 md5、不写变异测试。
- 只有「数据会丢 / 并发 / 持久化 / 删除」才额外加独立验证。
- **用户原话里没有的需求不加**；想加先问一句。
- 禁止两个 agent 并行改同一批文件（撞过一次，版本叠加 + 证据污染）。
- 「冻结」= 运行前后各取一次 md5 且一致，不是抽样一次。
- 验收准则：无命令不算通过；断言机器可判；成功与失败路径都留证；拿不到环境标「未验收」。

## 3. 环境与构建铁律

- **本地工具链在 `C:\cytest-toolchain`（6 G，不放仓库里：D 盘只剩 5 G）**：
  `source toolchain.sh`（仓库根目录的入口，自动回落 `.toolchain/env.sh`）后
  flutter / dart / adb / sdkmanager 全部可用。内容：Flutter 3.50.0 SDK、
  android-sdk（platforms;android-37 + build-tools;37.0.0 + platform-tools + cmdline-tools
  + ndk;28.2.13676358）、JAVA_HOME 复用 Android Studio 的 JBR 21（不装 JDK）。
  构建产物仍在仓库 `build/`（debug APK 126 M）。
- 旧的 `D:\cytest-app\.workbuddy	mp\env` 已在 2026-11-20 晚被清理（连同 cytest-app 仓库），
  不要再引用那条路径。
- `FLUTTER_STORAGE_BASE_URL` 必须 flutter-io.cn（否则引擎包下载中断），env.sh 里已设。
- 版本组合（降版本行不通）：**AGP 9.3.1 + Gradle 9.5.0 + Kotlin 2.4.20 + compileSdk 37**。
（原 9.1.1/9.3.1 会触发 Flutter 的「即将停止支持」警告，2026-11-20 已升级并本地验证。）
- 原生二进制走 `jniLibs/arm64-v8a/lib*.so` + `useLegacyPackaging=true`；解压到 filesDir 再 chmod 会被 SELinux 拒。
- CI 里 xray 必须 `unzip -d /tmp` 再 `mv` 到 jniLibs（落 `assets/` 被静默忽略）。
- **`INTERNET` 必须写在 `src/main/AndroidManifest.xml`**；缺了症状极误导（xray 建 socket 失败 → freePort 抛错被吞 → 回落 20000 → 8s 超时 → 报「xray 未能在 8 秒内监听」）。排查从 APK 本体取证（`aapt2 dump permissions`）。
- `flutter_inappwebview 6.1.5` 不兼容 AGP 9 → vendor 到 `packages/flutter_inappwebview_android` 改 `proguard-android-optimize.txt` + `dependency_overrides`。
- 本机 `sdk/ndk/28.2.*` 空目录会让本地 Gradle 预检查报错（CI 不阻塞），已隔离。
- CI：`permissions: contents: write`；缓存 `~/.gradle/caches`+wrapper；`-Xmx3G -XX:MaxMetaspaceSize=1G`；Maven 429 会让 Gradle 配置阶段静默失败（别写成 OOM）。


### .toolchain 的三处本地补丁（重装时照做，否则 Gradle 直接失败）

1. **`platforms/android-37`**：Google 只发 `platforms;android-37.0`，而 `compileSdk = 37`
   会让 AGP 去找 `platforms/android-37`，找不到就调 sdkmanager 自动装（该包不存在 → 失败）。
   做法：把 `android-37.0` 复制成 `android-37`，并把 `source.properties` 的
   `AndroidVersion.ApiLevel=37.0` 改成 `37`。
2. **`ndk/28.2.13676358`**：`ndkVersion = flutter.ndkVersion` 让 Flutter 插件强制下载这个版本，
   而 sdkmanager 下载会报 `Error on ZipFile unknown archive`（代理下断流）。
   做法：`curl --noproxy '*' -C -` 下 `android-ndk-r28c-windows.zip`（714MB），解压后把
   `android-ndk-r28c` 改名成 `28.2.13676358`。
3. **JDK 不单独装**：`JAVA_HOME` 指向 Android Studio 自带 JBR 21。

验证：`source .toolchain/env.sh && flutter build apk --debug` → 4 分钟出
`build/app/outputs/flutter-apk/app-debug.apk`。


### CI 构建耗时：什么有效、什么无效（2026-11-20 实测）

| 改动 | 效果 |
|---|---|
| pub 缓存 | pub get 30~60s → **0~1s** |
| Flutter SDK 缓存（钉死版本后） | setup 41s → **13~26s** |
| xray 二进制缓存 | 下载 ~8s → **0s** |
| NDK 28.2 缓存（解压目录） | Build APK −50s（原来每次都下 700MB） |
| **Gradle build-cache 持久化** | **0 命中，无效，已撤**（日志 `FROM-CACHE 数：0`） |

底线：`Build release APK` 189~261s 主要是 Dart AOT + R8/dex + 资源打包的 CPU 时间，
以及 runner 机型波动（同代码 189/210/258/308s 都出现过）。**别再拿单次时长归因**。

## 4. UI 铁律

- Scaffold body 包 `SafeArea(top: false, ...)`；有 bottomNavigationBar 时其 bottom padding 被清零。
- **M3**：`IconButton` 的 iconSize/padding/visualDensity/constraints 会被丢弃，压尺寸必须 `style: ButtonStyle(...)`。
- 长跑页日志统一 `LogPanel`（固定区 + Expanded），**绝不塞进整体滚动 ListView 末尾**。
- `Expanded` 外层 `Padding` 给 `bottom: 14`，列表内容区再 `bottom: 12`。
- 弹层的 `TextEditingController` 由弹层自己的 StatefulWidget 持有（`whenComplete()` 早于退出动画）。
- **WebView 必须真实可见**（高度不能为 0、不能移出屏外，否则 PlatformView 被销毁）。
- 选择态下列表底部留 88px，别让最后一行被操作条压住。

## 5. 只在这些地方容易改坏（改前先读 ARCHITECTURE）

| 位置 | 别碰坏的约束 |
|---|---|
| `link_test.dart` 闸门 | `reopen()` 必须在「await 上一轮收尾」之后；否则并发翻倍 |
| `link_probe.dart` 延迟 | 必须「预热 + 计时」两段；回退成一次请求，读数立刻回到 1000ms |
| 候选端点切换 | 首轮死线 8s、重试 5s；判定读 `failureKind`，**不许比较文案** |
| `settings_page.dart` 保存 | 只写脏字段；快照在写盘成功且自检通过后才推进 |
| `pipeline.dart` config | **不写 `httpProxy`**；否则整批判「代理隧道失败」 |
| 三阶段延迟 | 必须纯 TCP 握手；改成 HTTP 首字节读数会差一个数量级 |

## 6. 踩坑记录

- **抽样一次 md5 ≠ 终态**：工程师还在写时广播冻结，导致 QA 三次签名作废。
- **只信报告会翻车**：多次遇到「报告说改完了、代码里没有」，一律 `git show HEAD:` 或 grep 复核。
- **别拿本地 18MB 的 APK 比体积**：没跑「拉取原生二进制」时包里没有 xray/pipeline。
- **十进制 vs MiB**：手机显示 38.5 MB = 36.75 MiB，同一个包。
- **「gzip pipeline-linux 省 4~5MB」已证伪**：它在 APK 里已被 deflate 到 2.77 MiB。
- **本机「没网」先看 v2rayN**：核心没起来时 10808 不监听，看起来像断网。
- `Uri.fragment` 不解码，需要时 `Uri.decodeComponent`（`Uri.queryParameters` 才自动解码）。
- golden 预览图：`flutter test --update-goldens` 要 `FontLoader` 加载 `msyh.ttc` + `materialicons-regular.otf`，否则全是方块；**不要提交到 CI**（平台字体差异）。
- 后台 `curl` 卡住会被转后台并留下 `flutter_tester.exe`，收尾 `taskkill`。

## 8. Windows 桌面（2026-11-22 起）

- 工具链：VS **生成工具 2022**（`C:\BuildTools`，VCTools 工作负载）+ Win SDK + CMake，
  配合 `C:\cytest-toolchainin
uget.exe`（不装完整 VS IDE）。
- **build 前必须把 `C:\cytest-toolchainin` 加进 PATH**，否则
  `flutter_inappwebview_windows` 的 CMake 报 `NUGET-NOTFOUND`（exit 9009）。
- 装 VS 时若父进程环境同时有 `PATH` 和 `Path`，bootstrapper 会以
  `0x80070057` 直接失败 —— 用 `schtasks /RU SYSTEM` 起安装器可绕过。
- 构建：`flutter build windows --release` → `build\windowsdunner\Release\cytest.exe`（约 38MB）。
- 引擎二进制**不释放进 APPDATA 以外的奇怪位置**：程序目录 `bin\` 或
  `%APPDATA%\cytestin\`，由 `Bins._windowsPath` 查找；Windows 上没有 chmod。

## 7. 已知遗留

1. 设置「切走就丢」依赖 `AppLifecycleListener(onHide/onPause)`；`SettingsPage` 在 IndexedStack 常驻几乎不 dispose → **必须真机验**（改一项 → 杀进程 → 冷启动看还在不在）。
2. 链路测速真实读数本地无法验证（无外网）；真机跑一轮看日志 `预热=` 与 `建连=`。
3. 慢节点（首字节 > 8s）会被判失败并多试一轮。
4. 设置页逐键全页 `setState`（16 次比较），低端机性能未量化。
5. `_formKey` 未用于 validate；归一化规则在 `_readForm` / `_backfillNormalized` 各写一遍。
