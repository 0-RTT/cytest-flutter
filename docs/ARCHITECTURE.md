# cytest 架构与实现说明

面向维护者的实现文档：这个 App 由哪些部分组成、数据怎么流动、关键口径为什么这么定。
（只描述当前实现，不涉及历史版本对照。）

---

## 1. 这是什么

一个「候选代理筛选 + 端到端验证 + 订阅生成」的工具，全部在手机上完成：

```
Censys 抓候选 IP  →  三阶段漏斗筛掉不可用  →  VLESS 链路测速（真起 Xray）
                  →  勾选可用节点  →  生成 base64 订阅 / mihomo YAML  →  推 GitHub
```

不依赖电脑端，也不依赖外部测速服务。

## 2. 进程与目录

```
App 进程
├── Flutter UI / AppState
├── xray 子进程（按需启动：单线路代理 或 批量多入站）
└── pipeline 子进程（Go 引擎，三阶段本地测试；从 jniLibs 取，见 §12）

cytest/
├── runs/<时间戳>/       三阶段结果：input.txt、config.json、result.csv
├── archives/            Censys 抓取快照（JSON）
├── linktest/<ts>.json   链路测速结果，保留最近 20 条
└── xray/proxyip.csv     回源 IP 列表（+ proxyip-state.json 记录成功/失败）
```

## 3. 分层

```
ui/        页面与组件（只依赖 state 与 data 的公开 API）
state/     AppState（ChangeNotifier，相当于 ViewModel：状态 + 编排）
data/      Xray 进程管理、Go 引擎调用、链路探测、订阅生成、GitHub、SSH、持久化
core/      路径、设置模型、二进制释放、信号量、IDN
```

约定：`data/` 不 import Flutter（除少数需要 `rootBundle` 的），所以能被纯 Dart 单测覆盖；
`ui/` 不直接起进程。

## 4. 模块职责

| 文件 | 职责 |
|---|---|
| `core/paths.dart` | 所有目录的一次性创建与访问（`runs/` `archives/` `linktest/` `xray/`） |
| `core/settings.dart` | `AppSettings` 模型 + `SharedPreferences` 读写 + 一次性迁移 + 默认值 |
| `core/bin.dart` | 释放 `libpipeline.so` / `libxray.so` 的路径；远程执行用的 Linux 引擎 |
| `core/semaphore.dart` | 并发闸门（`acquire`/`release`/`drain`/`reopen`），支撑「取消即停」 |
| `data/vless.dart` | vless 链接解析与展开（含 IDN、`#remark`、查询表） |
| `data/xray.dart` | Xray 配置生成、单线路/批量启动、端口就绪等待、停止（SIGTERM→SIGKILL） |
| `data/pipeline.dart` | 三阶段本地测试：写 `input.txt`/`config.json`、起引擎、流式日志、读 `result.csv` |
| `data/link_probe.dart` | 单节点探测：延迟（预热+计时两段）、吞吐（3s/64MiB 窗口）、失败分类 |
| `data/link_test.dart` | 链路测速编排：端口池、批量 xray、延迟波、AUTO 过滤、速度波、落盘、取消 |
| `data/link_test_store.dart` | 链路测速历史：`save/list/prune/delete/deleteMany` |
| `data/history.dart` | 三阶段结果与抓取存档的枚举、读取、删除 |
| `data/node_template.dart` | 订阅模板展开（`host:port` 槽位替换、base64） |
| `data/mihomo.dart` | mihomo YAML 生成（手写 emitter，字段与主流生成器对齐） |
| `data/publish.dart` | 订阅/YAML 组装、推送前的产物准备 |
| `data/github.dart` | GitHub Contents API 上传（可走本机代理） |
| `data/remote.dart` | SSH 执行：上传 Linux 引擎、跑三阶段、拉回结果 |
| `data/censys_*.dart` | 抓取编排、Cookie 快路径、原生 WebView 通道、失败诊断 |
| `state/app_state.dart` | 全局状态：设置、抓取、三阶段运行、链路测速、推送、日志 |

## 5. 数据流

### 5.1 抓取
```
fetch_page → AppState.fetch
  ├─ 有 Cookie：先走纯 HTTP 快路径（censys_http/MainActivity.fetchSearch）
  │    失败分流：JSON 直接用 / 挑战页·401·403 清 Cookie 回退 WebView
  │                / 无状态码（握手失败）→ 本会话禁用快路径（maxHttpFailures=2）
  └─ 回退：原生 WebView（页面内 fetch），成功后落 Cookie
结果写入 archives/ 并进入结果页
```

### 5.2 三阶段本地测试
```
test_page → AppState.runLocal(mode) → Pipeline.run
  写 input.txt + config.json → 起 pipeline → 流式读日志 → 读 result.csv → 回填 rows
```

### 5.3 链路测速
```
vless_test_page 或 记录页点历史 → AppState.runLinkTest(mode)
  → LinkTestRunner.run → _runOnce
      端口池 pick(n) → buildBatchConfig → xray.startBatch
      → 延迟波(6 路) → AUTO: 只留可达 → 速度波(2 路) → 每 8 条刷新 UI
      → 落盘 linktest/<ts>.json → 停进程
```

### 5.4 推送
```
勾选节点 → PublishPage（模板 + targets）
  → 生成 base64 订阅 / mihomo YAML（文件名取自设置）
  → GitHub Contents API 上传（可临时起代理）
```

## 6. 三阶段本地测试的口径

| 阶段 | 做什么 | 参数 |
|---|---|---|
| ① 指纹 | `GET http://ip:port` 读前 ≤50MiB 算 SHA1，命中即认为是目标节点 | 5s、重试 1、并发 30、不按端口预筛 |
| ② 延迟 | **纯 TCP 握手**（有代理则 CONNECT + 读 1 字节） | 并发 100，`maxLatency>0` 才淘汰（默认 0 = 不限） |
| ③ 速度 | 每条候选绑自己的 `ip:port` 拨号，SNI/Host 用测速地址的域名 | 预热 256KiB，窗口 3s / 上限 64MiB，并发 2 |

- 默认指纹 `108b6115…` 是「Cloudflare 400 错误页（253 字节）」的 SHA1，所以它对任何 CF 边缘节点都命中 —— 这是**刻意**设计：它回答的是「这台是不是 CF 节点」，不是「这台好不好用」。
- 延迟只能用 TCP 口径：曾改成「TCP + TLS + HEAD 首字节」并判 HTTP≥400 失败，同一个 IP 的读数从 154ms 变成 2023ms。
- 引擎退出码：`0` 有结果 / `1` 零可用（**仍会先写 result.csv**）/ `2` 参数或环境错误。
- `config.json` 由 Dart 生成，**不写 `httpProxy`**（测速始终直连，走隧道会把整批判成「代理隧道失败」）。

## 7. 链路测速

### 7.1 为什么不用「逐条起进程」
每条线路单独起一个 Xray 进程太慢（进程启动 + 端口等待 ≈ 数百 ms × N）。
这里用**单进程多入站**：一个 Xray 进程里生成 N 个 inbound（每个绑自己的 `127.0.0.1:port`），
Dart 侧对每个端口发探测，等于每条线路有自己的独立出口。

### 7.2 端口池
从 20000 起最多 500 个候选，逐个 `ServerSocket.bind` 验证空闲。
不足时**返回实际可用数**并提示「只剩 m 个」，绝不兜底伪造一个端口（那会让第二个进程 bind 失败、整批报错）。

### 7.3 并发与闸门
- 延迟波并发 6、速度波并发 2（`Semaphore`）。
- 闸门是 runner 的**实例字段**，跨轮复用；`drain()` 是永久的（取消后禁止再派发），
  只能 `reopen()` 恢复 —— 这就是「取消后再测必须先 reopen」的由来。
- `reopen()` 必须在「上一轮完全收尾」之后：否则旧一轮的 socket 还没关，新一轮就开跑，实际并发翻倍。

### 7.4 取消（三段缺一不可）
```
置位 _cancelled（拦新派发）
  → 关闭在途 HttpClient（让 await for 立刻结束）
  → kill xray（释放端口、停子进程）
```
只做第一段会「显示已取消但还在测」；只关客户端进程还在；只杀进程则探测端要等死线。

### 7.5 延迟口径（与「真连接延迟」可比）
一次测量里其实有两件事，必须分开：

```
第一次请求（预热，不计时）
  到节点 TCP → 与节点/出站 TLS → CONNECT 到目标 → 到目标 TLS → 请求/响应
  ≈ 4~5 个 RTT，这部分是「建连成本」
第二次请求（计时）
  同一条 keep-alive 连接上的一跳往返 ≈ 1 个 RTT  ← 这才是读数
```

- 端点默认 `https://cp.cloudflare.com/generate_204`：**不跟随跳转**（跟随会把第二套 CONNECT+TLS 算进 TTFB）。
- 判定：3xx / 204 / 205 记为可达（TTFB 取响应头时刻）；4xx/5xx、「200 但零字节」判失败（两种语义不同）。
- 预热失败 → 直接判失败（所以死节点照样变红，没有退化成「只测 IP」）。
- 预热耗时记在日志 `预热=` 字段，需要看建连成本时看它。

### 7.6 候选端点与切换
```
候选链 = [设置里的首选, cf 204, gstatic 204, 速度地址]   （按字符串去重、保序）
最多 3 次尝试
首轮死线 8s（kConnectTimeout），重试轮 5s（kLatencyTimeout）
```
为什么首轮必须 8s：5s 比建连超时还短，看门狗会先开枪，把「对方完全不可达」记成**超时**，
而规则是「超时不切」→ 候选链永远不触发，fallback 变成空壳。

切换判定读 `ProbeFailureKind`，**不比较错误文案**：

| 本次尝试的结果 | 动作 |
|---|---|
| 任意一条拿到延迟 | 不切（失败的是真死链） |
| 首轮清一色超时 | 切一次（端点坏 / 线路慢无法区分，付一次代价） |
| 重试轮仍清一色超时 | 停（判为线路慢） |
| 超时 + 建连类混合 | 不切 |
| 清一色 connect / tlsHandshake | 切，最多 3 次 |

切换前只清「延迟探测失败」，**预检失败（链接不可解析）绝不清** —— 那是不可恢复的。

### 7.7 状态与语义
```
ProbeState: pending → running → done / failed / cancelled
speedMib == null  → 未测（≠ 0，UI 显示「速度未测」）
cancelled ≠ failed（前者是用户中断，后者是探测出错）
AUTO 模式下速度阶段的 TTFB 只在「本条还没延迟」时才兼作延迟
```

## 8. 设置的读写

- 存储：`SharedPreferences`，key `cytest.settings.v1`（**不要改 key**）。
- **boot 是异步的**，UI 不等它。设置页如果在 boot 完成前绑定表单，拿到的是默认值；
  保存时若把整张表单写回，就会把磁盘上的配置抹成默认值。
- 因此保存只写**脏字段**（与快照比较），未编辑字段保持现值 —— 这条独立于时序生效，是真正的护栏。
- 自动保存：文本 600ms 去抖、关弹层 flush、退后台 flush、dispose 前同步取快照；
  所有保存走**同一条串行队列**（`setString` 是整份 JSON 覆盖写，并发会丢改动）。
- 保存后 `AppSettings.load()` 读回比对，不一致就报「已写入但对不上」；
  快照只在「写盘成功 **且** 自检通过」后推进，失败不推进 → 再点保存会真的重试。
- 空串语义：地址类与文件名类字段空串 = 回落默认（不是「关闭这一档」）。
- `speedUrl` 是双通道：三阶段的 `speedTestURL` 与链路测速的速度阶段都用它。

## 9. 记录页与存储格式

| 分组 | 目录 | 一行显示 | 点击 |
|---|---|---|---|
| Censys 测速结果 | `runs/` | 时间 + 可用/总数 + 最快速度 | 进结果页（可排序、导出、推送） |
| Censys 抓取存档 | `archives/` | 时间 + 命中数 / 大小 | 载入回三阶段测试页重跑 |
| VLESS 测速结果 | `linktest/` | 时间 + 模式 + 可用/总数 + 最快速度 | 进 VLESS 页（结果已就绪、默认勾选、可直接推送） |

多选删除：AppBar 勾选图标 → 每行出现 checkbox → 底部「删除 N 项 / 全选」；按种类分发删除，单条失败不影响其余。

`linktest/<ts>.json` 结构：
```json
{ "id": "1763612400000", "createdAt": 1763612400000, "mode": "auto",
  "results": [{ "link": "...", "name": "...", "host": "...", "port": 443,
                "latencyMs": 118, "speedMib": 18.62, "state": "done",
                "failureKind": "none", "error": null }] }
```

## 10. 生成与推送

- 订阅：模板 × 目标 → `vless://...` 列表 → 每行一条 → base64。
- mihomo：手写 emitter（不引 yaml 库），只输出 proxies / proxy-groups / rules 核心段。
- 推送：GitHub Contents API；可选「走代理」（临时起一条 Xray，推完立刻关）。
- 文件名（base64 / YAML）在**设置 → GitHub 推送**里配，推送页只回显。

## 11. 抓取通道

- 主通道是原生 WebView：站点按出口 IP 分级放行，纯 HTTP 在 TLS 指纹层就被拦。
- 纯 HTTP 只是「有 Cookie 时先问一句」的快路径。
- 失败处置不能一刀切：JSON 直接用；挑战页/401/403 → 清 Cookie 回退 WebView；
  无状态码（握手/连接/超时）→ 本会话禁用快路径；其它错误 JSON（多为 CQL 语法错）保持现状。

## 12. 打包与 CI

- 原生二进制走 `jniLibs/arm64-v8a/lib*.so` + `useLegacyPackaging=true`：
  `assets/` 里的二进制在 Android 上没有执行权限（filesDir 解压再 chmod 会被 SELinux 拒）。
- `INTERNET` 权限必须写在 `src/main/AndroidManifest.xml`（只写在 debug/profile 里不算）。
- CI 只监听 `v*` tag：analyze（`--no-fatal-infos`）→ test → 构建 APK → 发布 Release。
- 体积：28.6 MB（27.31 MiB），其中 Xray 12 MiB、Flutter 引擎 8 MiB、pipeline 5 MiB。

## 13. 关键决策速查

| 决策 | 理由 |
|---|---|
| 三阶段延迟用纯 TCP 握手 | 用 HTTP 首字节会把跨境抖动和 4xx 混进读数（实测 154ms → 2023ms） |
| 链路测速延迟先预热再计时 | 建连成本 4~5 个 RTT，算进读数就出现「别人 80ms、我们 1000ms」 |
| 首轮死线 8s、重试 5s | 5s 会让「不可达」被记成超时，候选链失效 |
| 切换判定读 `failureKind` | 文案一改，行为跟着变，测试也看不出来 |
| 设置只写脏字段 | boot 时序错了也不会把别人配置抹成默认 |
| 保存串行队列 | 整份 JSON 覆盖写，并发必丢改动 |
| 速度 `null` ≠ 0 | 「未测」与「测出来是零速」是两件事 |
| 取消要三段 | 少一段就出现「显示已取消但还在跑」或「端口不释放」 |

## 14. 已知限制

- 导出为复制到剪贴板，不写外部存储（避免存储权限）。
- mihomo 输出不含 rule-providers / DNS / TUN。
- 结果页不支持导出文件、历史合并、备份导入导出。
- 慢节点（首字节 > 首轮 8s）会被判失败；「宁可慢也要测出」需放宽首轮死线。
- 设置页逐键触发全页 `setState`，低端机性能未量化。
