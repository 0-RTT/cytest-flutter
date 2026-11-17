# cytest · Flutter 版

候选代理筛选工具，与 Kotlin 版（`0-RTT/cytest-app`）功能与逻辑对齐，UI 用 Flutter 重写。

## 功能

| 模块 | 说明 |
|---|---|
| 获取数据 | 系统 WebView 过 CDN 挑战，页面内 fetch Censys `/api/search`；有线路时经 Xray 出站 |
| 线路与代理 | VLESS 链接（ws / xhttp / tcp）、proxyip 回源、启停、批量探活 |
| 本地测试 | 三阶段漏斗（指纹 → 延迟 → 测速），调用打包的 Go 引擎，流式日志 |
| 结果 | 排序表、统计卡；导出 CSV / 订阅 / mihomo（复制到剪贴板）、推送 GitHub |
| 记录 | 测试历史、Censys 存档、删除；点击可载入重跑 |
| 远程执行 | SSH 到服务器跑 Linux 版 pipeline，拉回结果 |
| 设置 | 并发 / 超时 / 测速 / 抓取代理 / GitHub / 远程主机 |

## 与原版的对应关系

两者共用同一套网络引擎（`tools/pipeline/pipeline.go`）与 Xray 核心，Dart 侧只负责调度与展示：

```
lib/data/vless.dart         ← Android VlessParser / 桌面端 xray.go
lib/data/xray.dart          ← Android XrayController（进程管理 + 配置生成）
lib/data/pipeline.dart      ← Android LocalSpeedRunner（三阶段调用 + CSV）
lib/data/node_template.dart ← Android NodeTemplate（订阅展开 + base64）
lib/data/history.dart       ← 桌面端 history.go
lib/data/remote.dart        ← 桌面端 remote.go（SSH）
lib/state/app_state.dart    ← Android TestViewModel（状态与编排）
```

## 构建

```bash
# 1. 准备原生二进制（不入库）
PIPELINE_SRC=/path/to/tools/pipeline/pipeline.go ./scripts/fetch-assets.sh

# 2. 依赖与构建
flutter pub get
flutter build apk --release --target-platform android-arm64
```

`minSdk = 29`（与 Kotlin 版一致，WebView 代理覆盖需要 API 29+）。

## 已知差异

- **导出方式**：Kotlin 版写文件到外部存储；这里改为复制到剪贴板（避免存储权限）
- **批量链路测速**：逐条串行启动 Xray 探活，未实现原版的多端口批量
- **mihomo 输出**：核心字段（proxies / groups / rules）一致，未包含原版的 rule-providers 与假 IP 过滤
- **包体积**：Flutter 引擎约 +4MB，二进制资源与 Kotlin 版相同（xray 33MB）

## 目录

```
lib/
├── core/       路径、设置持久化、二进制释放
├── data/       VLESS/Xray/Pipeline/订阅/mihomo/GitHub/SSH
├── state/      AppState（Provider）
└── ui/         首页（两列卡片）+ 各功能页 + 设置页
```
