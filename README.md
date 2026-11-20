# cytest · Flutter 版

候选代理筛选工具：抓取候选 IP → 三阶段漏斗筛出可用节点 → 起 Xray 做端到端链路测速 → 生成订阅并推送。

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

## 数据流

```
UI 页面 → AppState(Provider) → data/*（Xray 进程、Go 引擎、链路探测）→ 本地文件
```

| 目录 | 内容 | 记录页分组 |
|---|---|---|
| `cytest/runs/` | 三阶段结果（每轮目录 + CSV） | Censys 测速结果 |
| `cytest/archives/` | Censys 抓取快照（JSON） | Censys 抓取存档 |
| `cytest/linktest/` | 链路测速 `<createdAt>.json`（保留 20 条） | VLESS 测速结果 |

## 两种「延迟」口径（别混）

| 场景 | 口径 | 位置 |
|---|---|---|
| 三阶段本地测试 | 纯 TCP 握手（有代理则 CONNECT + 读 1 字节） | `pipeline.dart` → Go 引擎 |
| VLESS 链路测速 | **预热建隧道后，同一条 keep-alive 连接上的一跳往返** | `link_probe.dart` |

链路测速的第一次请求（建隧道 + CONNECT + 到目标 TLS，通常 4~5 个 RTT）**不计入读数**，只用于判定「线路通不通」；耗时记在日志 `预热=` 字段。延迟端点默认 `https://cp.cloudflare.com/generate_204`，不跟随跳转；不可达时按候选链自动切换（cf → gstatic → 速度地址），首轮死线 8s、重试轮 5s。

## 构建

```bash
# 1. 准备原生二进制（不入库）
PIPELINE_SRC=/path/to/tools/pipeline/pipeline.go ./scripts/fetch-assets.sh

# 2. 依赖与构建
flutter pub get
flutter build apk --release --target-platform android-arm64
```

`minSdk = 29`（WebView 代理覆盖需要 API 29+）。
原生二进制走 `jniLibs/arm64-v8a/lib*.so` + `useLegacyPackaging=true`（`assets/` 里的二进制在 Android 上没有执行权限）。

## 发版

```bash
git tag -a v1.0.NN -m "..." && git push origin v1.0.NN
```

CI 只监听 `v*` tag：analyze → test → 构建 APK → 发布 Release（`BUILD_NAME` 取 tag 去掉 `v`）。

## 已知限制

- **导出方式**：复制到剪贴板（不写外部存储，避免申请存储权限）
- **mihomo 输出**：只含 proxies / groups / rules 核心段，不含 rule-providers 与假 IP 过滤
- **包体积**：CI 产物 28.6 MB（27.31 MiB），其中 Xray 12 MiB、Flutter 引擎 8 MiB
- **未实现**：结果页导出文件、历史合并、备份导入导出 UI、last run 恢复

## 目录

```
lib/
├── core/       路径、设置持久化、二进制释放、信号量
├── data/       VLESS / Xray / Pipeline / 链路探测 / 订阅 / mihomo / GitHub / SSH
├── state/      AppState（Provider）
└── ui/         首页 + 各功能页（含 widgets/）
```
