# cytest-flutter · 作业记忆

> 只记「怎么干活」与「踩过的坑」。**实现细节、口径、数据流看 `docs/ARCHITECTURE.md`**，两处不要重复写。

仓库 `D:\cytest-flutter`。`engine/pipeline.go` 是 Go 引擎源码副本，改动需与上游同步。

---

## 1. 发布（每次都用）

```bash
source D:/cytest-app/.workbuddy/tmp/env/activate.sh
cd /d/cytest-flutter && git add -A && git commit -m "..."
git -c http.proxy=socks5h://127.0.0.1:10808 push origin main
git tag -a v1.0.NN -m "..." && git -c http.proxy=socks5h://127.0.0.1:10808 push origin v1.0.NN
```

- **CI 只监听 `v*` tag**：push main 不出包，要出包必须打 tag。
- 本机 v2rayN 只有 **SOCKS 10808**（无 HTTP 入站）→ git 必须 `socks5h://`（`h` 让代理解析域名）。
- 查 CI/GitHub API：`curl --ssl-no-revoke --socks5-hostname 127.0.0.1:10808`（schannel 吊销检查离线会报 `CRYPT_E_REVOCATION_OFFLINE`）。
- 现在基线 **v1.0.48**；APK 28.6 MB（27.31 MiB）。

## 2. 工作方式（用户明确要求）

- **小 bug：直接改 → 只对改动文件 `dart analyze` → 提交 → 推 CI。** 不建团队、不跑本地全量、不冻结 md5、不写变异测试。
- 只有「数据会丢 / 并发 / 持久化 / 删除」才额外加独立验证。
- **用户原话里没有的需求不加**；想加先问一句。
- 禁止两个 agent 并行改同一批文件（撞过一次，版本叠加 + 证据污染）。
- 「冻结」= 运行前后各取一次 md5 且一致，不是抽样一次。
- 验收准则：无命令不算通过；断言机器可判；成功与失败路径都留证；拿不到环境标「未验收」。

## 3. 环境与构建铁律

- Flutter 3.50 / Dart 3.14，SDK 原在 `D:\cytest-app\.workbuddy	mp\envlutter`；
  **2026-11-20 晚该临时目录被清理（cytest-app 整个不见了），本机已无 flutter/dart 可执行**，
  下次要先重新准备 SDK 与 `activate.sh` 才能本地跑 analyze/test。
- `FLUTTER_STORAGE_BASE_URL` 必须 flutter-io.cn（否则引擎包下载中断）。
- 版本组合（降版本行不通）：**AGP 9.1.1 + Gradle 9.3.1 + Kotlin 2.4.20 + compileSdk 37**。
- 原生二进制走 `jniLibs/arm64-v8a/lib*.so` + `useLegacyPackaging=true`；解压到 filesDir 再 chmod 会被 SELinux 拒。
- CI 里 xray 必须 `unzip -d /tmp` 再 `mv` 到 jniLibs（落 `assets/` 被静默忽略）。
- **`INTERNET` 必须写在 `src/main/AndroidManifest.xml`**；缺了症状极误导（xray 建 socket 失败 → freePort 抛错被吞 → 回落 20000 → 8s 超时 → 报「xray 未能在 8 秒内监听」）。排查从 APK 本体取证（`aapt2 dump permissions`）。
- `flutter_inappwebview 6.1.5` 不兼容 AGP 9 → vendor 到 `packages/flutter_inappwebview_android` 改 `proguard-android-optimize.txt` + `dependency_overrides`。
- 本机 `sdk/ndk/28.2.*` 空目录会让本地 Gradle 预检查报错（CI 不阻塞），已隔离。
- CI：`permissions: contents: write`；缓存 `~/.gradle/caches`+wrapper；`-Xmx3G -XX:MaxMetaspaceSize=1G`；Maven 429 会让 Gradle 配置阶段静默失败（别写成 OOM）。

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

## 7. 已知遗留

1. 设置「切走就丢」依赖 `AppLifecycleListener(onHide/onPause)`；`SettingsPage` 在 IndexedStack 常驻几乎不 dispose → **必须真机验**（改一项 → 杀进程 → 冷启动看还在不在）。
2. 链路测速真实读数本地无法验证（无外网）；真机跑一轮看日志 `预热=` 与 `建连=`。
3. 慢节点（首字节 > 8s）会被判失败并多试一轮。
4. 设置页逐键全页 `setState`（16 次比较），低端机性能未量化。
5. `_formKey` 未用于 validate；归一化规则在 `_readForm` / `_backfillNormalized` 各写一遍。
