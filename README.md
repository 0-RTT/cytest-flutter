# cytest · Flutter 版

候选代理筛选工具。与 Kotlin 版（`0-RTT/cytest-app`）共用同一套网络引擎与 Xray 核心，Dart 侧只负责调度与展示。

## 功能

| 模块 | 说明 |
|---|---|
| 获取数据 | 系统 WebView 过 CDN 挑战，页面内 fetch Censys `/api/search`；有线路时经 Xray 出站 |
| 线路与代理 | VLESS 链接（ws / xhttp / tcp）、proxyip 回源、启停、批量探活 |
| 本地测试 | 三阶段漏斗（指纹 → 延迟 → 测速），调用打包的 Go 引擎，流式日志 |
| 结果 | 排序表、统计卡；导出 CSV / 订阅 / mihomo（复制到剪贴板）、推送 GitHub |
| 记录 | 三个分组：**Censys 测速结果** / **Censys 抓取存档** / **VLESS 测速结果**；支持多选删除；点击分别进入结果页 / 载入重跑 / 进 VLESS 页推送 |
| 远程执行 | SSH 到服务器跑 Linux 版 pipeline，拉回结果 |
| 设置 | 并发 / 超时 / 延迟与速度地址 / GitHub（仓库、Token、**推送文件名**）/ 远程主机 |

## 与原版的对应关系

```
lib/data/vless.dart         ← Android VlessParser / 桌面端 xray.go
lib/data/xray.dart          ← Android XrayController（进程管理 + 配置生成）
lib/data/pipeline.dart      ← Android LocalSpeedRunner（三阶段调用 + CSV）
lib/data/link_probe.dart    ← Android LinkProbe（延迟 / 吞吐探测）
lib/data/link_test.dart     ← 链路测速编排（端口池 + 批量 xray + 两波）
lib/data/link_test_store.dart ← 链路测速历史（<createdAt>.json，保留 20）
lib/data/node_template.dart ← Android NodeTemplate（订阅展开 + base64）
lib/data/history.dart       ← 桌面端 history.go
lib/data/remote.dart        ← 桌面端 remote.go（SSH）
lib/state/app_state.dart    ← Android TestViewModel（状态与编排）
```

## 两种「延迟」口径（别混）

| 场景 | 口径 | 位置 |
|---|---|---|
| 三阶段本地测试 | 纯 TCP 握手（有代理则 CONNECT + 读 1 字节） | `pipeline.dart` → Go 引擎 |
| VLESS 链路测速 | **预热建隧道后，同一条 keep-alive 连接上的一跳往返**（与 v2rayN「真连接延迟」可比） | `link_probe.dart` |

链路测速的第一次请求（建隧道 + CONNECT + 到目标 TLS，通常 4~5 个 RTT）**不计入读数**，只用于判定「线路通不通」；它的耗时记在日志 `预热=` 字段里。端点默认 `https://cp.cloudflare.com/generate_204`，不跟随跳转；不可达时按候选链自动切换（cf → gstatic → 速度地址），首轮死线 8s、重试轮 5s。

## 构建

```bash
# 1. 准备原生二进制（不入库）
PIPELINE_SRC=/path/to/tools/pipeline/pipeline.go ./scripts/fetch-assets.sh

# 2. 依赖与构建
flutter pub get
flutter build apk --release --target-platform android-arm64
```

`minSdk = 29`（与 Kotlin 版一致，WebView 代理覆盖需要 API 29+）。
原生二进制走 `jniLibs/arm64-v8a/lib*.so` + `useLegacyPackaging=true`（`assets/` 里的二进制在 Android 上没有执行权限）。

## 发版

```bash
git tag -a v1.0.NN -m "..." && git push origin v1.0.NN
```

CI **只监听 `v*` tag**，构建 analyze → test → APK → 发布 Release（`BUILD_NAME` 取 tag 去掉 `v`）。

## 已知差异

- **导出方式**：Kotlin 版写文件到外部存储；这里改为复制到剪贴板（避免存储权限）
- **mihomo 输出**：核心字段（proxies / groups / rules）一致，未包含原版的 rule-providers 与假 IP 过滤
- **包体积**：Flutter CI 包 28.6 MB（27.31 MiB），Kotlin CI 包 38.5 MB（36.75 MiB）；两者 xray 都是 12 MiB（压缩后），差在代码本体（Kotlin 的 Compose + BouncyCastle dex 更大，Flutter 多了 8 MiB 引擎）

## 目录

```
lib/
├── core/       路径、设置持久化、二进制释放、信号量
├── data/       VLESS / Xray / Pipeline / 链路探测 / 订阅 / mihomo / GitHub / SSH
├── state/      AppState（Provider，相当于 ViewModel）
└── ui/         首页 + 各功能页（含 widgets/）
```
