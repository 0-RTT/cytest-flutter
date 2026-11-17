#!/usr/bin/env bash
# 准备 Flutter 端需要的原生二进制（不入库，由本脚本或 CI 生成）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ROOT/assets"
XRAY_VER="${XRAY_VERSION:-v26.11.9}"
PIPELINE_SRC="${PIPELINE_SRC:-}"

mkdir -p "$ASSETS"

echo "== 1/3 构建 arm64 pipeline =="
if [ -n "$PIPELINE_SRC" ] && [ -f "$PIPELINE_SRC" ]; then
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -trimpath -ldflags="-s -w" -o "$ASSETS/pipeline" "$PIPELINE_SRC"
  echo "   -> $ASSETS/pipeline ($(stat -c%s "$ASSETS/pipeline" 2>/dev/null || stat -f%z "$ASSETS/pipeline") 字节)"
else
  echo "   跳过：未设置 PIPELINE_SRC（指向 tools/pipeline/pipeline.go）"
  echo "   用法：PIPELINE_SRC=../cytest-app/tools/pipeline/pipeline.go ./scripts/fetch-assets.sh"
fi

echo "== 2/3 下载 xray (android arm64) =="
if [ -f "$ASSETS/xray" ]; then
  echo "   已存在，跳过"
else
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-android-arm64-v8a.zip"
  unzip -j -o -q "$TMP/xray.zip" xray -d "$ASSETS"
  rm -rf "$TMP"
  echo "   -> $ASSETS/xray"
fi

echo "== 3/3 构建 Linux 版 pipeline（远程执行用）=="
if [ -n "$PIPELINE_SRC" ] && [ -f "$PIPELINE_SRC" ]; then
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o "$ASSETS/pipeline-linux" "$PIPELINE_SRC"
  echo "   -> $ASSETS/pipeline-linux"
else
  echo "   跳过：未设置 PIPELINE_SRC"
fi

echo "完成。"
