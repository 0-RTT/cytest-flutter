# cytest-flutter · 项目记忆（唯一权威，2026-11-20 重整）

Kotlin 版（`0-RTT/cytest-app`）的 Flutter 重写，独立仓库 `D:\cytest-flutter`。
`engine/pipeline.go` 是 cytest-app `tools/pipeline` 的副本，改动需两边同步。**本记忆只写 Flutter 侧。**

---

## 1. 发布流程（每天都要用）

```bash
source D:/cytest-app/.workbuddy/tmp/env/activate.sh   # 注入 PATH / FLUTTER_STORAGE_BASE_URL 等
cd /d/cytest-flutter && git add -A && git commit -m "..."
git -c http.proxy=socks5h://127.0.0.1:10808 push origin main
git tag -a v1.0.NN -m "..." && git -c http.proxy=socks5h://127.0.0.1:10808 push origin v1.0.NN
```

- **CI 只监听 tag `v*`**，push main 不出包。日常验证靠 CI（用户要求：本地不要跑全量测试）。
- 本机代理：v2rayN 只有 **SOCKS 10808**（无 HTTP 入站）→ git 必须 `socks5h://`（`h` 让代理解析域名）。
- 查 CI / GitHub API 必须加 `--ssl-no-revoke --socks5-hostname 127.0.0.1:10808`（schannel 吊销列表离线会报 `CRYPT_E_REVOCATION_OFFLINE`）。
- 版本号是占位，`--build-name/--build-number` 由 CI 从 tag 注入（`BUILD_NAME = tag 去掉 v`）。
- 当前基线：**v1.0.48**，APK 28,632,000 字节（27.31 MiB / 28.6 MB 十进制）。

## 2. 体积认知（踩过的错）

| 包 | 十进制 | MiB | 压缩后构成 |
|---|---|---|---|
| Kotlin CI | 38.5 MB | 36.75 | dex 15.15 · xray 12.01 · pipeline-linux 6.50 · pipeline 2.47 |
| Flutter CI | 28.6 MB | 27.31 | **引擎 7.92** · xray 12.01 · pipeline-linux 2.77 · pipeline 2.49 · dex 1.65 |

- 差约 9 MiB：Kotlin dex 多 13.5（Compose + BouncyCastle + 看起来未开 R8），被 Flutter 引擎 7.9 抵掉一部分。
- **别拿本地 18MB 的包比**：没跑「拉取原生二进制」步骤时包里没有 xray/pipeline，是错口径。
- 「pipeline-linux 改 gzip 省 4~5MB」**已证伪**：它在 APK 里已被 deflate 到 2.77 MiB，别再提。

## 3. 环境与构建铁律

- Flutter 3.50 / Dart 3.14，SDK 在 `D:\cytest-app\.workbuddy\tmp\env\flutter`；`FLUTTER_STORAGE_BASE_URL` 必须 flutter-io.cn。
- 版本组合（降版本行不通）：**AGP 9.1.1 + Gradle 9.3.1 + Kotlin 2.4.20 + compileSdk 37**。
- **二进制执行权限走 jniLibs**：`libpipeline.so`/`libxray.so` 放 `jniLibs/arm64-v8a/` + `useLegacyPackaging=true`，路径由 MethodChannel `cytest/native` 的 `nativeLibraryDir` 给。解压到 filesDir 再 chmod 会被 SELinux 拒。
- CI 里 xray 必须 `unzip -d /tmp` 再 `mv` 到 jniLibs（落 `assets/` 被静默忽略）。
- **INTERNET 必须写在 `src/main/AndroidManifest.xml`**；缺了症状极误导（xray 建 socket 失败 → freePort 抛错被吞 → 回落 20000 → 8s 超时 → 报「xray 未能在 8 秒内监听」）。排查从 APK 本体取证（`aapt2 dump permissions`）。
- AGP strip jniLibs 的 ELF 只影响节头表，APK 内与本地差 306 字节属正常。
- `flutter_inappwebview 6.1.5` 不兼容 AGP 9 → vendor 到 `packages/flutter_inappwebview_android` 改 `proguard-android-optimize.txt`，pubspec 用 `dependency_overrides`。
- 本机 `sdk/ndk/28.2.*` 是空目录，会让本地 Gradle 预检查报错（CI 不阻塞），已隔离。
- CI：`permissions: contents: write`；缓存 `~/.gradle/caches` + wrapper；`-Xmx3G -XX:MaxMetaspaceSize=1G`；Maven 429 会让 Gradle 配置阶段静默失败（别写成 OOM）。

## 4. 架构与数据流

```
UI 页面 → AppState(=TestViewModel) → data/*（xray 进程、pipeline Go 引擎、probe）→ 文件
```

| 目录 | 内容 | 记录页分组 |
|---|---|---|
| `cytest/runs/` | 三阶段结果（每轮目录 + CSV） | **Censys 测速结果** |
| `cytest/archives/` | Censys 抓取快照（JSON） | **Censys 抓取存档** |
| `cytest/linktest/` | 链路测速 `<createdAt>.json`，保留 20 | **VLESS 测速结果** |

记录页三组都支持多选删除（AppBar 勾选图标 → 底部「删除 N 项」/全选）。点第一组进结果页；点抓取存档载入重跑；点 VLESS 记录 → `AppState.loadLinkRun` → 进 VLESS 页（结果已就绪、默认勾选、可直接推送）。

## 5. 三阶段本地测试（v1.0.23 定稿，口径未变）

**唯一权威参照 `D:\censys-speedtest\src\pipeline.go`（原版 729 行）。**

①指纹 GET `http://ip:port` 读 ≤50MiB 算 SHA1（5s/重试1/并发30/不按端口预筛）；
②延迟**纯 TCP 握手**（有代理则 CONNECT+GET 读1字节），并发100，`maxLatency>0` 才淘汰（默认 0）；
③测速每条绑自己 ip:port、SNI/Host 取 speedTestURL 域名，预热 256KiB、窗口 3s/64MiB、并发 2。

- 默认指纹 `108b6115…` = **CF 400 错误页(253B) 的 SHA1**，即「这台是 CF 节点」检测器。
- **延迟必须 TCP 口径**：曾改成 TCP+TLS+HEAD 首字节，同一 IP 从 154ms 变 2023ms。
- 退出码 `0` 有结果 / `1` 零可用（仍先写 result.csv）/ `2` 参数或环境错误。
- `config.json` 由 Dart 生成，**不含 httpProxy**。

## 6. 链路测速（VLESS 页）

编排：端口池（20000+500 bind 探测）→ 批量起 xray → 延迟波(6) → AUTO 过滤 → 速度波(2) → 落盘 → 停进程。
`LinkTestRunner` 在 AppState 里是**单例跨轮复用**。

- **闸门**：两个 `Semaphore` 是实例字段，`drain()` 永久生效 → 每轮 `_runOnce()` 开头必须 `reopen()`，且必须在「await 上一轮收尾」之后（真实理由是避免旧 socket 未关就放新轮进来、实际并发翻倍；**不是** permits 虚增，那条注释已订正）。
- **取消**：置位 + 关在途 HttpClient + 杀进程。已取消的上一轮：`run()` await 它收尾；真重入才抛「上一次测速还在进行」。`AppState` 用轮次令牌防止旧轮覆盖新轮的 stage/results/running。
- **延迟口径（v1.0.48 改）**：先**预热一次**（建隧道 + CONNECT + 目标 TLS，不计时，失败即红），再在同一条 keep-alive 连接上**计时第二次**往返 → 读数 ≈ 一跳 RTT，与 v2rayN「真连接延迟」可比。预热耗时记 `ProbeTimings.warmupMs`（日志字段 `预热=`）。`LinkProbe.warmUp` 默认 false（既有单测按一次请求计数），生产 runner 传 true。
- 延迟端点：`latencyUrl`（默认 `https://cp.cloudflare.com/generate_204`），**不跟随跳转**（跟随会把第二套 CONNECT+TLS 算进 TTFB）；3xx/204/205 记可达（TTFB 取响应头），4xx/5xx 与「200 零字节」仍失败。
- 候选端点链：`[设置首选, cf, gstatic, 速度地址]` 去重保序，最多 3 次尝试。**首轮死线 8s、重试 5s**（5s<8s 时看门狗先开枪，会把「不可达」记成超时 → 候选链永不触发，fallback 变空壳）。
- 切换判定读 `ProbeFailureKind`（**禁止比较 error 文案**）：有延迟就不切；超时且首轮→切一次；重试轮仍全超时→停（判为线路慢）；混合不切；清一色 connect/tlsHandshake→切满 3 次。切前只清延迟失败，**预检失败(host 为空)绝不清**。重跑复用同一 `_stage`/闸门。
- 速度：`speedUrl`（默认 `е.eu.org/300.zip`，`е` 是西里尔 U+0435），跟随跳转，3s/64MiB + 256KiB 预热。
- 语义：`speedMib == null` = 未测（≠0）；`cancelled` ≠ `failed`；AUTO 模式下速度阶段 TTFB 只在「本条还没延迟」时才兼作延迟。
- 阶段文案：首轮写「延迟探测」，第 2 次起才带「端点 n/m，约再 N 秒」；全部超时时收尾给「更换延迟测试地址」的可执行提示。

## 7. 设置（保存机制是踩过大坑的）

- 存储：`SharedPreferences` key `cytest.settings.v1`。**不要改 key**（等于清空所有老用户配置）。
- **boot 是异步的**（`AppState()..boot()`，UI 不等它）。设置页 `_bind` 若在 boot 前跑会拿到默认值；保存时若全量写回，就把磁盘配置抹成默认 —— 这就是用户报的「保存也丢失」。修法：boot 后只补「未被编辑」的字段 + **只写脏字段**（`_Field` 枚举 + 穷尽 switch 的 `_valueOf/_controllerOf/_labelOf/_applyField`）。
- 自动保存：文本 600ms 去抖、关弹层 flush、退后台 flush、dispose 前同步取快照；所有保存走**同一条串行队列**（`setString` 是整份 JSON 覆盖写，并发会丢改动）。
- 失败处理：日志 + 状态栏 + SnackBar 三处可见；`saveSettings()` 后 `AppSettings.load()` 读回比对 16 字段，不一致就报错；**快照只在「写盘成功且自检通过」后推进**，失败不推进 → 再点保存会真的重试。
- 空串语义：`speedUrl`/`latencyUrl`/`subPath`/`yamlPath` 空串 = 回落默认（不是关闭这一档）。
- `settings.speedUrl` **双通道**：既进三阶段 `speedTestURL`，也进链路测速速度阶段（默认值两边逐字一致，有单测钉住）。
- GitHub 分组含：仓库、Token、**订阅文件名(base64)**、**mihomo 文件名(YAML)**；推送页不再有文件名输入，只回显「写入 <文件名>」。

## 8. UI 铁律

- Scaffold body 要包 `SafeArea(top: false, ...)`（手势条）；有 bottomNavigationBar 时其 bottom padding 被清零。
- **M3**：`IconButton` 的 iconSize/padding/visualDensity/constraints 会被丢弃；压尺寸必须 `style: ButtonStyle(...)`。
- 长跑页日志统一 `LogPanel`（固定区 + Expanded），**绝不塞进整体滚动 ListView 末尾**。
- `Expanded` 外层 `Padding` 给 `bottom: 14`，列表内容区再 `bottom: 12`。
- 弹层的 `TextEditingController` 必须由弹层自己的 StatefulWidget 持有（`whenComplete()` 早于退出动画）。
- **WebView 必须真实可见**（高度不能为 0、不能移出屏外，否则 PlatformView 被销毁）；预览区高 `min(180, 屏高×30%)`，下限 60。
- 选择态下列表底部留 88px，避免最后一行被操作条压住。

## 9. 与 Kotlin 版差距

```
Kotlin  111 个 .kt  / 17,108 行
Flutter  39 个 .dart / 12,269 行
```

代码小主要因为 Kotlin 是 MVVM 分层（UiState/UiEvent/ViewModel/Repository/DI）+ res 资源；**不代表功能齐**。
功能点评估是 **v1.0.23 时点**：69 个用户可见点 对齐 8 / 缺失 37 / 退化 24（≈30%）。此后已补：记录页浏览与多选删除、推送文件名、延迟口径、设置保存。仍缺：结果页排序/导出文件、历史合并、mihomo 的 rule-providers/dns/tun、备份导入导出 UI、last run 恢复。

## 10. 已知遗留

1. 设置「切走就丢」依赖 `AppLifecycleListener(onHide/onPause)`，`SettingsPage` 在 IndexedStack 常驻几乎不 dispose → **必须真机验**（改一项 → 杀进程 → 冷启动看还在不在）。
2. 链路测速真实读数本地无法验证（无外网）；真机跑一轮看日志 `预热=` 与 `建连=`。
3. 慢节点（首字节 >8s）会被判失败并多试一轮；要「宁可慢也测出」得放宽首轮死线。
4. 设置页每次按键全页 `setState`（16 次比较），低端机性能未量化。
5. `_formKey` 未用于 validate；归一化规则在 `_readForm` / `_backfillNormalized` 各写一遍。

## 11. 工作方式（用户明确要求，2026-11-20）

- **小 bug：我直接改 → 只对改动文件 `dart analyze` → 提交 → 推 CI，让 CI 当守门人。不建 QA、不跑本地全量、不冻结 md5。**
- 只有「数据会丢 / 并发 / 持久化 / 删除」才额外加独立验证。
- **用户原话里没有的需求不加**；想加先问一句。
- 禁止两个 agent 并行改同一批文件（撞过一次，造成版本叠加与证据污染）。
- 「冻结」= 运行前后各取一次 md5 且一致，不是抽样一次。
- 验收准则：无命令不算通过；断言机器可判；成功与失败路径都留证；拿不到环境就标「未验收」。

## 12. 其他踩坑

- `Uri.fragment` 不解码（Kotlin 会），需 `Uri.decodeComponent`。
- golden 预览图：`flutter test --update-goldens` 可出 PNG，但必须 `FontLoader` 加载 `msyh.ttc`（中文）+ `materialicons-regular.otf`（图标），否则全是方块；golden 依赖平台字体，**不要提交到 CI**。
- 本机「无外网」时先看 v2rayN 核心是否在跑（10808 是否监听、有没有 xray.exe 子进程），别急着断言没网。
- 后台 `curl` 卡住会被自动转后台并留下 `flutter_tester.exe`，收尾时记得 `taskkill`。
