#!/usr/bin/env bash
# 取 Windows 版引擎二进制到 windows/bin/（不进 git，体积太大）。
#
#   xray.exe   —— 走代理 / 抓取 / 本地测试的代理内核（XTLS/Xray-core）
#   pipeline.exe —— 三阶段测试引擎（由 engine/pipeline.go 编译，需要 Go）
#
# 用法：bash tool/fetch_win_engine.sh [xray|pipeline|all]
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="windows/bin"
mkdir -p "$OUT"
PROXY="${CYTEST_HTTP_PROXY:-socks5h://127.0.0.1:10808}"
TARGET="${1:-all}"

fetch_xray() {
  if [[ -f "$OUT/xray.exe" ]]; then
    echo "xray.exe 已存在，跳过"
    return
  fi
  echo "== 下载 Xray-core (windows-64)"
  local url
  url=$(curl -sS --ssl-no-revoke --max-time 30 -x "$PROXY" \
    https://api.github.com/repos/XTLS/Xray-core/releases/latest |
    python -c "import json,sys;d=json.load(sys.stdin);print(next(a['browser_download_url'] for a in d['assets'] if a['name']=='Xray-windows-64.zip'))")
  local tmp
  tmp=$(mktemp -d)
  curl -sSL --ssl-no-revoke --max-time 600 -x "$PROXY" -o "$tmp/x.zip" "$url"
  unzip -o -q "$tmp/x.zip" xray.exe -d "$tmp"
  mv "$tmp/xray.exe" "$OUT/xray.exe"
  rm -rf "$tmp"
  "$OUT/xray.exe" version | head -1
}

fetch_pipeline() {
  if [[ -f "$OUT/pipeline.exe" ]]; then
    echo "pipeline.exe 已存在，跳过"
    return
  fi
  if ! command -v go >/dev/null 2>&1; then
    echo "缺少 Go，无法编译 pipeline.exe（装 Go 1.22+ 后重跑）" >&2
    return 1
  fi
  echo "== 编译 engine/pipeline.go → windows/amd64"
  ( cd engine && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
      go build -trimpath -ldflags "-s -w" -o "../$OUT/pipeline.exe" . )
  ls -l "$OUT/pipeline.exe"
}

case "$TARGET" in
  xray) fetch_xray ;;
  pipeline) fetch_pipeline ;;
  all) fetch_xray; fetch_pipeline ;;
  *) echo "用法: $0 [xray|pipeline|all]" >&2; exit 2 ;;
esac

echo "== $OUT"
ls -l "$OUT"
