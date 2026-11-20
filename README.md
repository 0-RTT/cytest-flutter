# cytest · Flutter 版

手机上完成「候选代理筛选 → 端到端验证 → 订阅生成 → 推送」的工具。

```
Censys 抓候选 IP → 三阶段漏斗（指纹/延迟/测速）→ VLESS 链路测速（真起 Xray）
                → 勾选可用节点 → base64 订阅 / mihomo YAML → 推 GitHub
```

详细实现见 **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**（分层、数据流、各口径为什么这么定）。

## 功能

| 模块 | 说明 |
|---|---|
| 获取数据 | 系统 WebView 过 CDN 挑战，页面内 fetch Censys `/api/search`；有线路时经 Xray 出站 |
| 线路与代理 | VLESS（ws / xhttp / tcp）、proxyip 回源、启停、批量探活 |
| 本地测试 | 三阶段漏斗，调用打包的 Go 引擎，流式日志 |
| 结果 | 排序表、统计卡；CSV / 订阅 / mihomo 导出（复制到剪贴板）、推送 GitHub |
| 记录 | 三组：**Censys 测速结果** / **Censys 抓取存档** / **VLESS 测速结果**；多选删除；点击分别进结果页 / 载入重跑 / 进 VLESS 页推送 |
| 远程执行 | SSH 到服务器跑 Linux 版引擎，拉回结果 |
| 设置 | 并发 / 超时 / 延迟与速度地址 / GitHub（仓库、Token、推送文件名）/ 远程主机 |

## 两种「延迟」口径

| 场景 | 口径 |
|---|---|
| 三阶段本地测试 | 纯 TCP 握手（有代理则 CONNECT + 读 1 字节） |
| VLESS 链路测速 | 预热建隧道后，同一条 keep-alive 连接上的一跳往返 |

链路测速的第一次请求（建隧道 + 到目标 TLS，约 4~5 个 RTT）不计入读数，只用于判定线路通不通，
耗时记在日志 `预热=`。端点默认 `generate_204`，不跟随跳转；不可达时按候选链自动切换。

## 构建

```bash
# 1. 准备原生二进制（不入库）
PIPELINE_SRC=/path/to/pipeline.go ./scripts/fetch-assets.sh

# 2. 依赖与构建
flutter pub get
flutter build apk --release --target-platform android-arm64
```

`minSdk = 29`（WebView 代理覆盖需要 API 29+）。
原生二进制放 `jniLibs/arm64-v8a/lib*.so` + `useLegacyPackaging=true`（`assets/` 里的二进制在 Android 上没有执行权限）。

## 发版

```bash
git tag -a v1.0.NN -m "..." && git push origin v1.0.NN
```

CI 只监听 `v*` tag：analyze → test → 构建 APK → 发布 Release。

## 已知限制

- 导出为复制到剪贴板，不写外部存储
- mihomo 只含 proxies / groups / rules，不含 rule-providers / DNS / TUN
- 结果页不支持导出文件、历史合并、备份导入导出
- 包体积 28.6 MB：Xray 12 MB、Flutter 引擎 8 MB、pipeline 5 MB

## 目录

```
lib/
├── core/       路径、设置持久化、二进制释放、信号量
├── data/       VLESS / Xray / Pipeline / 链路探测 / 订阅 / mihomo / GitHub / SSH
├── state/      AppState（Provider）
└── ui/         首页 + 各功能页
docs/           ARCHITECTURE.md（实现说明）+ design/（流程图、类图）
```
